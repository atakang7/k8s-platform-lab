#!/usr/bin/env bash
set -Eeuo pipefail

readonly root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${root}/infra/edge/config.env"

fail() {
  printf 'FAIL | %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'PASS | %s\n' "$1"
}

environment_namespace() {
  python3 - "${root}/environment.yaml" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as source:
    print(yaml.safe_load(source)["namespace"])
PY
}

run_host_validations() {
  (
    cd "${root}"
    PYTHONNOUSERSITE=1 make cluster-validate
    make edge-validate
    make observability-smoke
  )
}

validate_policies() {
  "${root}/policies/bin/smoke" --cluster resource-requests-webhook
}

validate_jenkins() {
  local secret controller_pod
  local -r namespace=jenkins
  local -r host="jenkins.${DNS_ZONE}"

  for secret in jenkins-admin github-creds dockerhub-creds; do
    kubectl -n "${namespace}" get secret "${secret}" >/dev/null ||
      fail "Jenkins prerequisite ${secret} is missing"
  done

  kubectl -n "${namespace}" rollout status deployment/jenkins --timeout=90s >/dev/null

  controller_pod="$(kubectl -n "${namespace}" get pod \
    -l app.kubernetes.io/component=jenkins-controller -o json)"
  jq -e '.items | length == 1 and .[0].spec.nodeName == "node-3"' \
    <<<"${controller_pod}" >/dev/null ||
    fail 'Jenkins controller is not running on node-3'

  kubectl -n "${namespace}" get pvc -o json |
    jq -e '.items | any(.status.phase == "Bound")' >/dev/null ||
    fail 'Jenkins persistence is not Bound'

  [[ "$(kubectl -n "${namespace}" get ingress jenkins \
    -o jsonpath='{.spec.ingressClassName}')" == nginx ]] ||
    fail 'Jenkins ingress is missing'

  [[ "$(dig +short "@${EDGE_HOST_IP}" "${host}" A | tail -1)" == "${INGRESS_VIP}" ]] ||
    fail 'Jenkins hostname does not use the ingress LoadBalancer'

  curl --noproxy '*' --silent --show-error --fail --location --max-time 15 \
    "https://${host}/login" -o /dev/null ||
    fail 'Jenkins HTTPS endpoint failed'

  if ! python3 - "https://${host}/api/json?tree=numExecutors" <<'PY'
import base64
import json
import subprocess
import sys
import urllib.request

secret = json.loads(
    subprocess.check_output(
        ["kubectl", "-n", "jenkins", "get", "secret", "jenkins-admin", "-o", "json"]
    )
)
username = base64.b64decode(secret["data"]["jenkins-admin-user"]).decode()
password = base64.b64decode(secret["data"]["jenkins-admin-password"]).decode()
credentials = base64.b64encode(f"{username}:{password}".encode()).decode()
request = urllib.request.Request(
    sys.argv[1], headers={"Authorization": f"Basic {credentials}"}
)
with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(
    request, timeout=15
) as response:
    assert json.load(response)["numExecutors"] == 0
PY
  then
    fail 'Jenkins controller executor count is not zero'
  fi

  pass 'Jenkins credentials, placement, persistence, HTTPS, and executor policy'
}

validate_application() {
  local namespace="$1"
  local deployment pods unique logged pod
  local -r host="app.${DNS_ZONE}"

  kubectl -n "${namespace}" rollout status deployment/sample-java-app --timeout=90s >/dev/null

  deployment="$(kubectl -n "${namespace}" get deployment sample-java-app -o json)"
  jq -e '.status.readyReplicas == 4 and .spec.replicas == 4' \
    <<<"${deployment}" >/dev/null ||
    fail 'application replica count is not 4'

  jq -e '.spec.template.spec.containers[]
    | select(.name == "app")
    | .image
    | test("@sha256:[0-9a-f]{64}$")' <<<"${deployment}" >/dev/null ||
    fail 'application image is not immutable'

  pods="$(kubectl -n "${namespace}" get pods \
    -l app.kubernetes.io/name=sample-java-app -o json)"
  jq -e '[.items[] | select(.status.phase == "Running") | .spec.nodeName]
    | sort == ["node-2","node-2","node-3","node-3"]' \
    <<<"${pods}" >/dev/null ||
    fail 'application is not spread 2/2 across workers'

  [[ "$(dig +short "@${EDGE_HOST_IP}" "${host}" A | tail -1)" == "${INGRESS_VIP}" ]] ||
    fail 'application DNS is wrong'

  unique="e2e-$(date +%s)-$$"
  [[ "$(curl --noproxy '*' --silent --show-error --fail \
    --get --data-urlencode "val=${unique}" "https://${host}/api/foos")" \
    == "QueryStringValue: ${unique}" ]] ||
    fail 'application HTTPS response is wrong'

  logged=false
  for _ in {1..15}; do
    while IFS= read -r pod; do
      if kubectl -n "${namespace}" exec "${pod}" -c app -- \
        grep -Fq "${unique}" /var/log/app/app.log; then
        logged=true
        break
      fi
    done < <(kubectl -n "${namespace}" get pods \
      -l app.kubernetes.io/name=sample-java-app -o name)

    [[ "${logged}" == true ]] && break
    sleep 1
  done

  [[ "${logged}" == true ]] ||
    fail 'request did not reach the asynchronous application file log'

  printf '%s\n' "${unique}"
}

validate_observability() {
  local namespace="$1" unique="$2"
  local metrics found
  local -r host="observability.${DNS_ZONE}"

  kubectl -n "${namespace}" get servicemonitor sample-java-app >/dev/null ||
    fail 'application ServiceMonitor is absent'

  metrics="$(curl --noproxy '*' --silent --show-error --fail \
    --get --data-urlencode 'query=up{service="sample-java-app"}' \
    "https://${host}/prometheus/api/v1/query")"
  jq -e '.status == "success" and (.data.result | any(.value[1] == "1"))' \
    <<<"${metrics}" >/dev/null ||
    fail 'application Prometheus target is not UP'

  metrics="$(curl --noproxy '*' --silent --show-error --fail \
    --get --data-urlencode 'query=jvm_memory_used_bytes{area="heap"}' \
    "https://${host}/prometheus/api/v1/query")"
  jq -e '.status == "success" and (.data.result | length > 0)' \
    <<<"${metrics}" >/dev/null ||
    fail 'application JVM metric is absent'

  kubectl -n observability get configmap \
    lab-cluster-dashboard lab-logs-dashboard >/dev/null ||
    fail 'Grafana dashboards are not provisioned'

  helm -n observability get values observability -o json |
    jq -e '.grafana.additionalDataSources
      | any(.uid == "application-logs" and .database == "app-logs")' >/dev/null ||
    fail 'Grafana application log datasource is absent'

  found=0
  for _ in {1..30}; do
    found="$(
      kubectl get --raw \
        "/api/v1/namespaces/observability/services/http:logs-es-http:9200/proxy/app-logs/_search?q=log:${unique}" \
        2>/dev/null |
        jq -r '.hits.total.value' || true
    )"
    [[ "${found:-0}" -gt 0 ]] && break
    sleep 2
  done

  [[ "${found:-0}" -gt 0 ]] ||
    fail 'application request log did not reach Elasticsearch'

  pass 'application metrics, dashboards, and log delivery'
}

main() {
  local namespace unique

  if [[ "${1:-}" != --cluster ]]; then
    run_host_validations
    "${root}/infra/edge/lib/with-kubeconfig.sh" "$0" --cluster
    return
  fi

  validate_policies
  validate_jenkins

  namespace="$(environment_namespace)"
  unique="$(validate_application "${namespace}")"
  pass 'application replicas, image identity, placement, DNS, HTTPS, and file logging'

  validate_observability "${namespace}" "${unique}"
  pass 'complete platform validation'
}

main "$@"
