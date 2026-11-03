#!/usr/bin/env bash
# End-to-end proof of the whole platform: the host-side validations, then
# policies, Jenkins, the application in this cluster's environment, and its
# metrics and logs. One request with a unique ID is traced from HTTPS into
# Elasticsearch.
#
# Runs in two halves:
#   1. On the host: cluster, edge and observability validations.
#   2. With --cluster, through the SSH tunnel: everything in the cluster.
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT

# shellcheck source=../../infra/edge/config.env
source "${ROOT}/infra/edge/config.env"

readonly JENKINS_HOST="jenkins.${DNS_ZONE}"
readonly OBSERVABILITY_HOST="observability.${DNS_ZONE}"

# Set in the cluster half by read_application.
NAMESPACE=''
APPLICATION_HOST=''

fail() {
  printf 'FAIL | %s\n' "$1" >&2
  exit 1
}

phase() {
  printf 'WAIT | %s\n' "$1"
}

pass() {
  printf 'PASS | %s\n' "$1"
}

# ---- Host half ----

run_host_validations() {
  phase 'running the cluster, edge and observability validations'

  cd "${ROOT}"
  make cluster-validate
  make edge-validate
  make observability-smoke
}

# ---- Cluster half ----

check_policies() {
  "${ROOT}/policies/bin/smoke" --cluster
}

check_jenkins() {
  phase "checking https://${JENKINS_HOST}"

  if ! curl --noproxy '*' --silent --show-error --fail --max-time 15 \
    --output /dev/null "https://${JENKINS_HOST}/login"; then
    fail "https://${JENKINS_HOST}/login does not answer"
  fi
}

read_application() {
  local environment

  environment="$("${ROOT}/platform/bin/cluster-environment")"
  NAMESPACE="${environment#* }"
  APPLICATION_HOST="$(kubectl -n "${NAMESPACE}" get ingress sample-java-app -o jsonpath='{.spec.rules[0].host}')"

  phase "checking sample-java-app in ${NAMESPACE}"
  kubectl -n "${NAMESPACE}" rollout status deployment/sample-java-app --timeout=90s >/dev/null
}

# The app must run exactly the release that delivery recorded in Git.
check_application_release() {
  local recorded
  local running

  recorded="$("${ROOT}/platform/bin/state-image" sample-java-app)"
  running="$(kubectl -n "${NAMESPACE}" get deployment sample-java-app \
    -o jsonpath='{.spec.template.spec.containers[?(@.name=="app")].image}')"

  if [[ -z "${recorded}" || "${running}" != *"@${recorded}" ]]; then
    fail "sample-java-app runs ${running}, not the recorded release ${recorded:-none}"
  fi
}

# One request with a unique ID: it must come back over HTTPS, and then show up
# in Elasticsearch through the application log.
check_request_reaches_logs() {
  local request_id
  local response
  local search
  local hits

  request_id="e2e-$(date +%s)-$$"
  phase "sending request ${request_id} to https://${APPLICATION_HOST}"

  response="$(curl --noproxy '*' --silent --show-error --fail --connect-timeout 5 --max-time 15 --get \
    --data-urlencode "val=${request_id}" \
    "https://${APPLICATION_HOST}/api/foos")"
  if [[ "${response}" != "QueryStringValue: ${request_id}" ]]; then
    fail "sample-java-app answered: ${response}"
  fi

  for _ in {1..30}; do
    if search="$(kubectl get --raw \
      "/api/v1/namespaces/observability/services/http:logs-es-http:9200/proxy/app-logs/_search?q=log:${request_id}" \
      2>/dev/null)"; then
      hits="$(jq -r '.hits.total.value // 0' <<< "${search}")"
      if [[ "${hits}" -gt 0 ]]; then
        return
      fi
    fi
    sleep 2
  done

  fail "request ${request_id} did not reach Elasticsearch"
}

check_application_metrics() {
  local answer
  local up

  phase 'checking the application metrics in Prometheus'

  answer="$(curl --noproxy '*' --silent --show-error --fail --connect-timeout 5 --max-time 15 --get \
    --data-urlencode 'query=up{service="sample-java-app"}' \
    "https://${OBSERVABILITY_HOST}/prometheus/api/v1/query")"
  up="$(jq -r '.data.result[0].value[1] // "none"' <<< "${answer}")"

  if [[ "${up}" != 1 ]]; then
    fail "Prometheus does not see sample-java-app as up (up = ${up})"
  fi
}

main() {
  case "${1:-}" in
    '')
      [[ "$#" -eq 0 ]] || fail 'e2e validation does not accept arguments'
      run_host_validations
      exec "${ROOT}/infra/edge/lib/with-kubeconfig.sh" "$0" --cluster
      ;;
    --cluster)
      [[ "$#" -eq 1 ]] || fail 'e2e validation --cluster does not accept extra arguments'

      check_policies
      check_jenkins
      pass 'Jenkins answers over HTTPS'

      read_application
      check_application_release
      check_request_reaches_logs
      pass 'the application runs the recorded release, and a request reaches its logs'

      check_application_metrics
      pass 'Prometheus scrapes the application'

      pass 'the whole platform is validated end to end'
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
}

main "$@"
