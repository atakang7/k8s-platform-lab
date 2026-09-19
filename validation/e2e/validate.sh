#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT
source "${ROOT}/infra/edge/config.env"

fail() {
  printf 'FAIL | %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'PASS | %s\n' "$1"
}

require_command() {
  local command_name="$1"

  command -v "${command_name}" >/dev/null 2>&1 ||
    fail "required command is unavailable: ${command_name}"
}

environment_namespace() {
  python3 - "${ROOT}/environment.yaml" <<'PY'
import sys
import yaml

path = sys.argv[1]
with open(path, encoding="utf-8") as source:
    config = yaml.safe_load(source)

if not isinstance(config, dict):
    raise SystemExit(f"{path}: expected a YAML mapping")

namespace = config.get("namespace")
if not isinstance(namespace, str) or not namespace:
    raise SystemExit(f"{path}: namespace must be a non-empty string")

print(namespace)
PY
}

run_host_validations() {
  (
    cd "${ROOT}"
    PYTHONNOUSERSITE=1 make cluster-validate
    make edge-validate
    make observability-smoke
  )
}

validate_policies() {
  "${ROOT}/policies/bin/smoke" --cluster resource-requests-webhook
}

validate_jenkins_executor_policy() {
  local host="$1"

  python3 - "https://${host}/api/json?tree=numExecutors" <<'PY'
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
    sys.argv[1],
    headers={"Authorization": f"Basic {credentials}"},
)

opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
with opener.open(request, timeout=15) as response:
    payload = json.load(response)

if payload.get("numExecutors") != 0:
    raise SystemExit("Jenkins controller numExecutors is not zero")
PY
}

validate_jenkins() {
  local secret
  local controller_pod
  local -r namespace=jenkins
  local -r host="jenkins.${DNS_ZONE}"

  for secret in jenkins-admin github-creds dockerhub-creds; do
    kubectl -n "${namespace}" get secret "${secret}" >/dev/null ||
      fail "Jenkins prerequisite ${secret} is missing"
  done

  kubectl -n "${namespace}" rollout status deployment/jenkins \
    --timeout=90s >/dev/null

  controller_pod="$(
    kubectl -n "${namespace}" get pod \
      -l app.kubernetes.io/component=jenkins-controller \
      -o json
  )"

  jq -e '
    .items
    | length == 1
      and .[0].spec.nodeName == "node-3"
  ' <<< "${controller_pod}" >/dev/null ||
    fail 'Jenkins controller is not running on node-3'

  kubectl -n "${namespace}" get pvc -o json |
    jq -e '.items | any(.status.phase == "Bound")' >/dev/null ||
    fail 'Jenkins persistence is not Bound'

  [[ "$(kubectl -n "${namespace}" get ingress jenkins \
    -o jsonpath='{.spec.ingressClassName}')" == nginx ]] ||
    fail 'Jenkins ingress is missing'

  [[ "$(dig +short "@${EDGE_HOST_IP}" "${host}" A | tail -1)" \
    == "${INGRESS_VIP}" ]] ||
    fail 'Jenkins hostname does not use the ingress LoadBalancer'

  curl \
    --noproxy '*' \
    --silent \
    --show-error \
    --fail \
    --location \
    --max-time 15 \
    "https://${host}/login" \
    --output /dev/null ||
    fail 'Jenkins HTTPS endpoint failed'

  validate_jenkins_executor_policy "${host}" ||
    fail 'Jenkins controller executor count is not zero'

  pass 'Jenkins credentials, placement, persistence, HTTPS, and executor policy'
}

validate_application() {
  local namespace="$1"
  local request_id="$2"
  local deployment
  local pods
  local response
  local logged=false
  local pod
  local attempt
  local -r host="app.${DNS_ZONE}"

  kubectl -n "${namespace}" rollout status deployment/sample-java-app \
    --timeout=90s >/dev/null

  deployment="$(
    kubectl -n "${namespace}" get deployment sample-java-app -o json
  )"

  jq -e '.status.readyReplicas == 4 and .spec.replicas == 4' \
    <<< "${deployment}" >/dev/null ||
    fail 'application replica count is not 4'

  jq -e '
    .spec.template.spec.containers[]
    | select(.name == "app")
    | .image
    | test("@sha256:[0-9a-f]{64}$")
  ' <<< "${deployment}" >/dev/null ||
    fail 'application image is not immutable'

  pods="$(
    kubectl -n "${namespace}" get pods \
      -l app.kubernetes.io/name=sample-java-app \
      -o json
  )"

  jq -e '
    [.items[] | select(.status.phase == "Running") | .spec.nodeName]
    | sort == ["node-2", "node-2", "node-3", "node-3"]
  ' <<< "${pods}" >/dev/null ||
    fail 'application is not spread 2/2 across workers'

  [[ "$(dig +short "@${EDGE_HOST_IP}" "${host}" A | tail -1)" \
    == "${INGRESS_VIP}" ]] ||
    fail 'application DNS is wrong'

  response="$(
    curl \
      --noproxy '*' \
      --silent \
      --show-error \
      --fail \
      --get \
      --data-urlencode "val=${request_id}" \
      "https://${host}/api/foos"
  )"

  [[ "${response}" == "QueryStringValue: ${request_id}" ]] ||
    fail 'application HTTPS response is wrong'

  for attempt in {1..15}; do
    while IFS= read -r pod; do
      if kubectl -n "${namespace}" exec "${pod}" -c app -- \
        grep -Fq "${request_id}" /var/log/app/app.log; then
        logged=true
        break
      fi
    done < <(
      kubectl -n "${namespace}" get pods \
        -l app.kubernetes.io/name=sample-java-app \
        -o name
    )

    [[ "${logged}" == true ]] && break
    sleep 1
  done

  [[ "${logged}" == true ]] ||
    fail 'request did not reach the asynchronous application file log'

  pass 'application replicas, image identity, placement, DNS, HTTPS, and file logging'
}

validate_observability() {
  local namespace="$1"
  local request_id="$2"
  local metrics
  local found=0
  local attempt
  local -r host="observability.${DNS_ZONE}"

  kubectl -n "${namespace}" get servicemonitor sample-java-app >/dev/null ||
    fail 'application ServiceMonitor is absent'

  metrics="$(
    curl \
      --noproxy '*' \
      --silent \
      --show-error \
      --fail \
      --get \
      --data-urlencode 'query=up{service="sample-java-app"}' \
      "https://${host}/prometheus/api/v1/query"
  )"

  jq -e '
    .status == "success"
    and (.data.result | any(.value[1] == "1"))
  ' <<< "${metrics}" >/dev/null ||
    fail 'application Prometheus target is not UP'

  metrics="$(
    curl \
      --noproxy '*' \
      --silent \
      --show-error \
      --fail \
      --get \
      --data-urlencode 'query=jvm_memory_used_bytes{area="heap"}' \
      "https://${host}/prometheus/api/v1/query"
  )"

  jq -e '
    .status == "success"
    and (.data.result | length > 0)
  ' <<< "${metrics}" >/dev/null ||
    fail 'application JVM metric is absent'

  kubectl -n observability get configmap \
    lab-cluster-dashboard \
    lab-logs-dashboard >/dev/null ||
    fail 'Grafana dashboards are not provisioned'

  helm -n observability get values observability -o json |
    jq -e '
      .grafana.additionalDataSources
      | any(.uid == "application-logs" and .database == "app-logs")
    ' >/dev/null ||
    fail 'Grafana application log datasource is absent'

  for attempt in {1..30}; do
    found="$(
      kubectl get --raw \
        "/api/v1/namespaces/observability/services/http:logs-es-http:9200/proxy/app-logs/_search?q=log:${request_id}" \
        2>/dev/null |
        jq -r '.hits.total.value' || true
    )"

    if [[ "${found:-}" =~ ^[0-9]+$ && "${found}" -gt 0 ]]; then
      break
    fi
    sleep 2
  done

  [[ "${found:-}" =~ ^[0-9]+$ && "${found}" -gt 0 ]] ||
    fail 'application request log did not reach Elasticsearch'

  pass 'application metrics, dashboards, and log delivery'
}

run_cluster_validations() {
  local command_name
  local namespace
  local request_id

  for command_name in kubectl jq dig curl python3 helm; do
    require_command "${command_name}"
  done

  validate_policies
  validate_jenkins

  namespace="$(environment_namespace)"
  request_id="e2e-$(date +%s)-$$"

  validate_application "${namespace}" "${request_id}"
  validate_observability "${namespace}" "${request_id}"

  pass 'complete platform validation'
}

main() {
  case "${1:-}" in
    --cluster)
      [[ "$#" -eq 1 ]] || fail 'e2e cluster mode accepts only --cluster'
      run_cluster_validations
      ;;
    '')
      run_host_validations
      "${ROOT}/infra/edge/lib/with-kubeconfig.sh" "$0" --cluster
      ;;
    *)
      fail "unknown e2e validation argument: $1"
      ;;
  esac
}

main "$@"
