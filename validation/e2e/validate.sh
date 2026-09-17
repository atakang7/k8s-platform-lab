#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root}"
fail() { printf 'FAIL | %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS | %s\n' "$1"; }

if [[ "${1:-}" != --cluster ]]; then
  PYTHONNOUSERSITE=1 make cluster-validate
  make edge-validate
  make observability-smoke
  "${root}/infra/edge/lib/with-kubeconfig.sh" "${root}/validation/e2e/validate.sh" --cluster
  exit
fi

[[ "$(kubectl -n policy-system get validatingwebhookconfiguration resource-requests-webhook -o name)" != '' ]] || fail 'admission webhook is absent'
for secret in jenkins-admin github-creds dockerhub-creds jenkins-kubeconfig; do
  kubectl -n jenkins get secret "${secret}" >/dev/null || fail "Jenkins prerequisite ${secret} is missing"
done
kubectl -n jenkins rollout status deployment/jenkins --timeout=90s >/dev/null
[[ "$(kubectl -n jenkins get pod -l app.kubernetes.io/component=jenkins-controller -o json | jq -r '.items[0].spec.nodeName')" == node-3 ]] || fail 'Jenkins controller is not on node-3'
kubectl -n jenkins get pvc -o json | jq -e '.items | any(.status.phase == "Bound")' >/dev/null || fail 'Jenkins persistence is not Bound'
[[ "$(kubectl -n jenkins get ingress jenkins -o jsonpath='{.spec.ingressClassName}')" == nginx ]] || fail 'Jenkins ingress is missing'
[[ "$(dig +short @192.168.56.1 jenkins.lab.test A | tail -1)" == 192.168.56.200 ]] || fail 'Jenkins hostname does not use the ingress LoadBalancer'
curl --silent --show-error --fail --location --max-time 15 https://jenkins.lab.test/login -o /dev/null || fail 'Jenkins HTTPS endpoint failed'
python3 - <<'PY' || fail 'Jenkins controller executor count is not zero'
import base64, json, subprocess, urllib.request
secret = json.loads(subprocess.check_output(['kubectl', '-n', 'jenkins', 'get', 'secret', 'jenkins-admin', '-o', 'json']))
username = base64.b64decode(secret['data']['jenkins-admin-user']).decode()
password = base64.b64decode(secret['data']['jenkins-admin-password']).decode()
credentials = base64.b64encode(f'{username}:{password}'.encode()).decode()
request = urllib.request.Request('https://jenkins.lab.test/api/json?tree=numExecutors', headers={'Authorization': f'Basic {credentials}'})
with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(request, timeout=15) as response:
    assert json.load(response)['numExecutors'] == 0
PY
pass 'Jenkins Secrets, placement, persistence, and LoadBalancer HTTPS path'

kubectl -n default rollout status deployment/sample-java-app --timeout=90s >/dev/null
app="$(kubectl -n default get deployment sample-java-app -o json)"
jq -e '.status.readyReplicas == 4 and .spec.replicas == 4 and .spec.selector.matchLabels.track == "stable" and .spec.template.metadata.labels.track == "stable"' <<<"${app}" >/dev/null || fail 'stable application replicas or labels are wrong'
jq -e '.spec.template.spec.containers[] | select(.name == "app") | .image | test("@sha256:[0-9a-f]{64}$")' <<<"${app}" >/dev/null || fail 'application image is not immutable'
[[ "$(kubectl -n default get service sample-java-app -o jsonpath='{.spec.selector.track}')" == stable ]] || fail 'stable Service can select canary Pods'
pods="$(kubectl -n default get pods -l app=sample-java-app,track=stable -o json)"
jq -e '[.items[] | select(.status.phase == "Running") | .spec.nodeName] | sort == ["node-2","node-2","node-3","node-3"]' <<<"${pods}" >/dev/null || fail 'application is not spread 2/2 across workers'
[[ "$(dig +short @192.168.56.1 app.lab.test A | tail -1)" == 192.168.56.200 ]] || fail 'application DNS is wrong'
unique="e2e-$(date +%s)-$$"
[[ "$(curl --silent --show-error --fail --get --data-urlencode "val=${unique}" https://app.lab.test/api/foos)" == "QueryStringValue: ${unique}" ]] || fail 'application HTTPS response is wrong'
logged=false
for _ in {1..15}; do
  for pod in $(kubectl -n default get pods -l app=sample-java-app,track=stable -o name); do
    if kubectl -n default exec "${pod}" -c app -- grep -Fq "${unique}" /var/log/app/app.log; then logged=true; break; fi
  done
  [[ "${logged}" == true ]] && break
  sleep 1
done
[[ "${logged}" == true ]] || fail 'request did not reach the asynchronous application file log'
pass 'four stable replicas, immutable image, placement, DNS, and HTTPS'

kubectl -n default get servicemonitor sample-java-app >/dev/null || fail 'application ServiceMonitor is absent'
metrics="$(curl --silent --show-error --fail --get --data-urlencode 'query=up{service="sample-java-app"}' https://observability.lab.test/prometheus/api/v1/query)"
jq -e '.status == "success" and (.data.result | any(.value[1] == "1"))' <<<"${metrics}" >/dev/null || fail 'application Prometheus target is not UP'
metrics="$(curl --silent --show-error --fail --get --data-urlencode 'query=jvm_memory_used_bytes{area="heap"}' https://observability.lab.test/prometheus/api/v1/query)"
jq -e '.status == "success" and (.data.result | length > 0)' <<<"${metrics}" >/dev/null || fail 'application JVM metric is absent'
kubectl -n observability get configmap lab-cluster-dashboard lab-logs-dashboard >/dev/null || fail 'Grafana dashboards are not provisioned'
helm -n observability get values observability -o json | jq -e '.grafana.additionalDataSources | any(.uid == "application-logs" and .database == "app-logs")' >/dev/null || fail 'Grafana application log datasource is absent'
for _ in {1..30}; do
  found="$(curl --silent --show-error --fail -H 'Content-Type: application/json' -d "{\"query\":{\"match_phrase\":{\"log\":\"${unique}\"}}}" https://observability.lab.test/elasticsearch/app-logs/_search | jq -r '.hits.total.value')" || true
  [[ "${found:-0}" -gt 0 ]] && break
  sleep 2
done
[[ "${found:-0}" -gt 0 ]] || fail 'application request log did not reach Elasticsearch'
pass 'application metrics, Grafana configuration, and log delivery'

policy_check() {
  local expectation="$1" requests="$2" output
  output="$(kubectl apply --dry-run=server -f - 2>&1 <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: e2e-policy-check
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels: {app: e2e-policy-check}
  template:
    metadata:
      labels: {app: e2e-policy-check}
    spec:
      containers:
        - name: pause
          image: registry.k8s.io/pause:3.10.1
          resources:
            requests: ${requests}
EOF
)" && [[ "${expectation}" == allow ]] && return
  [[ "${expectation}" == deny && "${output}" == *denied* ]] || fail "admission ${expectation} check failed: ${output}"
}
policy_check allow '{cpu: 10m, memory: 16Mi}'
policy_check deny '{memory: 16Mi}'
policy_check deny '{cpu: 10m}'
pass 'admission accepts complete requests and rejects missing CPU or memory'
python3 - <<'PY' || fail 'reference canary selector can overlap stable traffic'
import yaml
from pathlib import Path
resources = list(yaml.safe_load_all(Path('docs/06-governance-resilience/canary-release.yaml').read_text()))
service = next(item for item in resources if item['kind'] == 'Service')
assert service['spec']['selector']['track'] == 'canary'
assert service['spec']['selector']['app'] == 'sample-java-app'
PY
pass 'complete platform validation'
