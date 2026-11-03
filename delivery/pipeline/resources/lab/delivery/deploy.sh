#!/usr/bin/env bash
# Releases one recorded release (app APP_VERSION, image IMAGE_DIGEST) into
# one environment, with that environment's values (values-<ENVIRONMENT>.yaml
# when the chart has one), then runs the chart's Helm tests (the base chart's
# smoke test plus the service's own). A failed test rolls the release back to
# its previous revision and fails. A release already running both is left alone.
#
# With CANARY_WEIGHT set (prod), an existing release is first joined by a
# one-replica <release>-canary behind CANARY_WEIGHT% of its host's traffic.
# Its 5xx rate at the ingress (Prometheus at METRICS_URL) is checked every
# minute for CANARY_MINUTES; above CANARY_MAX_ERROR_RATE the canary is removed
# and the stable release is left untouched. A healthy canary is removed once
# the stable release runs the new version.
# Kubernetes access is the Pod's own: the deploy job runs each environment
# under that environment's deploy identity, which can release only there.
set -Eeuo pipefail

SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIRECTORY
WORK_DIRECTORY="$(mktemp -d)"
readonly WORK_DIRECTORY
CANARY_RELEASE=''
ENVIRONMENT_VALUES=()

cleanup() {
  if [[ -n "${CANARY_RELEASE}" ]]; then
    helm uninstall "${CANARY_RELEASE}" --namespace "${NAMESPACE}" --wait --ignore-not-found >/dev/null
  fi
  rm -rf -- "${WORK_DIRECTORY}"
}
trap cleanup EXIT

# shellcheck source=registry.sh
source "${SCRIPT_DIRECTORY}/registry.sh"

prepare_chart() {
  registry_login "${WORK_DIRECTORY}" "${CHART_REF}"
  release_chart "${WORK_DIRECTORY}"
  if [[ -f "${CHART}/values-${ENVIRONMENT}.yaml" ]]; then
    ENVIRONMENT_VALUES=(--values "${CHART}/values-${ENVIRONMENT}.yaml")
  fi
}

release_is_current() {
  local deployed_chart
  local deployed_digest

  deployed_chart="$(helm list --namespace "${NAMESPACE}" --deployed --filter "^${RELEASE}\$" --output json |
    jq -r '.[0].chart // ""')"
  [[ "${deployed_chart}" == "${RELEASE}-${APP_VERSION}" ]] || return 1
  deployed_digest="$(helm get values "${RELEASE}" --namespace "${NAMESPACE}" --output json |
    jq -r '.image.digest // ""')"
  [[ "${deployed_digest}" == "${IMAGE_DIGEST}" ]]
}

deploy_release() {
  # The release owns its objects. --force-conflicts takes ownership back from
  # manual server-side-apply edits; --rollback-on-failure restores the last
  # successful release if readiness fails.
  helm upgrade --install "${RELEASE}" "${CHART}" \
    --namespace "${NAMESPACE}" \
    "${ENVIRONMENT_VALUES[@]}" \
    --set-string image.digest="${IMAGE_DIGEST}" \
    --force-conflicts \
    --rollback-on-failure \
    --wait \
    --timeout 5m \
    --history-max 5
}

# Returns the release to its last good state: the previous revision, or
# nothing when this was its first install.
roll_back_release() {
  if [[ "$(helm history "${RELEASE}" --namespace "${NAMESPACE}" --output json | jq length)" -gt 1 ]]; then
    helm rollback "${RELEASE}" --namespace "${NAMESPACE}" --wait --timeout 5m
  else
    helm uninstall "${RELEASE}" --namespace "${NAMESPACE}" --wait --timeout 5m
  fi
}

test_release() {
  # Test only a fully rolled-out release; a rollout that never finishes is
  # rolled back like a failed test.
  kubectl --namespace "${NAMESPACE}" rollout status "deployment/${RELEASE}" --timeout 5m &&
    helm test "${RELEASE}" --namespace "${NAMESPACE}" --timeout 5m --logs && return

  printf 'FAIL | %s %s failed its tests in %s; rolling back\n' \
    "${RELEASE}" "${APP_VERSION}" "${ENVIRONMENT}" >&2
  roll_back_release
  exit 1
}

# The canary's share of 5xx answers over the last $1 minutes; NaN or empty
# while it has had no traffic. ingress-nginx counts canary requests under the
# stable Ingress, labelled canary="<namespace>-<canary Service>-<port>"; the
# scrape target lives in ingress-nginx, so the app namespace arrives as
# exported_namespace. With no 5xx answers at all there is no 5xx series, so
# "or vector(0)" counts them as zero; without it a healthy canary with traffic
# read as "no traffic yet" and was never judged.
canary_error_rate() {
  local selector="exported_namespace=\"${NAMESPACE}\",canary=~\"${NAMESPACE}-${CANARY_RELEASE}-.+\""
  local requests="nginx_ingress_controller_requests"

  curl --fail --silent --show-error --connect-timeout 5 --max-time 15 --get "${METRICS_URL}/api/v1/query" \
    --data-urlencode "query=(sum(increase(${requests}{${selector},status=~\"5..\"}[${1}m])) or vector(0)) / sum(increase(${requests}{${selector}}[${1}m]))" |
    jq -er 'if .status == "success" then (.data.result[0].value[1] // "") else error(.error // "Prometheus query failed") end'
}

run_canary() {
  local minute
  local rate
  local judged=false

  CANARY_RELEASE="${RELEASE}-canary"
  printf 'WAIT | canary %s %s takes %s%% of %s traffic for %s minutes\n' \
    "${RELEASE}" "${APP_VERSION}" "${CANARY_WEIGHT}" "${ENVIRONMENT}" "${CANARY_MINUTES}"
  helm upgrade --install "${CANARY_RELEASE}" "${CHART}" \
    --namespace "${NAMESPACE}" \
    "${ENVIRONMENT_VALUES[@]}" \
    --set-string image.digest="${IMAGE_DIGEST}" \
    --set replicas=1 \
    --set podDisruptionBudget.enabled=false \
    --set ingress.canaryWeight="${CANARY_WEIGHT}" \
    --wait \
    --timeout 5m
  # helm --wait returned while the canary's JVM was still starting, and its
  # smoke test found no ready Pod. Wait for the rollout itself before testing.
  kubectl --namespace "${NAMESPACE}" rollout status "deployment/${CANARY_RELEASE}" --timeout 5m
  helm test "${CANARY_RELEASE}" --namespace "${NAMESPACE}" --timeout 5m --logs

  for minute in $(seq 1 "${CANARY_MINUTES}"); do
    sleep 60
    rate="$(canary_error_rate "${minute}")"
    if [[ -z "${rate}" || "${rate}" == NaN ]]; then
      printf 'WAIT | canary minute %s: no traffic yet\n' "${minute}"
      continue
    fi
    judged=true
    if awk -v rate="${rate}" -v max="${CANARY_MAX_ERROR_RATE}" 'BEGIN { exit !(rate > max) }'; then
      printf 'FAIL | canary 5xx rate %s is above %s; %s keeps its current version\n' \
        "${rate}" "${CANARY_MAX_ERROR_RATE}" "${RELEASE}" >&2
      exit 1
    fi
    printf 'WAIT | canary minute %s: 5xx rate %s\n' "${minute}" "${rate}"
  done

  if [[ "${judged}" == false ]]; then
    printf 'WARN | canary received no traffic; nothing to judge it by\n'
  fi
  printf 'PASS | canary %s %s is healthy\n' "${RELEASE}" "${APP_VERSION}"
}

main() {
  prepare_chart

  # Helm release history is kept in ConfigMaps because the deploy identity
  # intentionally has no Secrets access.
  export HELM_DRIVER=configmap

  if release_is_current; then
    printf 'PASS | %s already runs %s in %s\n' "${RELEASE}" "${APP_VERSION}" "${ENVIRONMENT}"
    return
  fi

  # A first install has no stable release to compare a canary against.
  if [[ -n "${CANARY_WEIGHT:-}" ]] && helm status "${RELEASE}" --namespace "${NAMESPACE}" >/dev/null 2>&1; then
    run_canary
  fi

  printf 'WAIT | releasing %s %s to %s\n' "${RELEASE}" "${APP_VERSION}" "${ENVIRONMENT}"
  deploy_release
  test_release
  printf 'PASS | %s %s released and tested in %s\n' "${RELEASE}" "${APP_VERSION}" "${ENVIRONMENT}"
}

main "$@"
