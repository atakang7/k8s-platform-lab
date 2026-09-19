#!/usr/bin/env bash
# Releases one recorded release (app APP_VERSION, image IMAGE_DIGEST) into
# one environment, with that environment's values (values-<ENVIRONMENT>.yaml
# when the chart has one), then runs the chart's Helm tests (the base chart's
# smoke test plus the service's own). A failed test rolls the release back to
# its previous revision and fails. A release already running both is left alone.
# Kubernetes access is the Pod's own: the deploy job runs each environment
# under that environment's deploy identity, which can release only there.
set -Eeuo pipefail

SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIRECTORY
WORK_DIRECTORY="$(mktemp -d)"
readonly WORK_DIRECTORY
trap 'rm -rf -- "${WORK_DIRECTORY}"' EXIT

# shellcheck source=registry.sh
source "${SCRIPT_DIRECTORY}/registry.sh"

prepare_chart() {
  registry_login "${WORK_DIRECTORY}" "${CHART_REF}"
  release_chart "${WORK_DIRECTORY}"
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
  local values=()

  if [[ -f "${CHART}/values-${ENVIRONMENT}.yaml" ]]; then
    values=(--values "${CHART}/values-${ENVIRONMENT}.yaml")
  fi

  # The release owns its objects. --force-conflicts takes ownership back from
  # manual server-side-apply edits; --rollback-on-failure restores the last
  # successful release if readiness fails.
  helm upgrade --install "${RELEASE}" "${CHART}" \
    --namespace "${NAMESPACE}" \
    "${values[@]}" \
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
  helm test "${RELEASE}" --namespace "${NAMESPACE}" --timeout 5m --logs && return

  printf 'FAIL | %s %s failed its tests in %s; rolling back\n' \
    "${RELEASE}" "${APP_VERSION}" "${ENVIRONMENT}" >&2
  roll_back_release
  exit 1
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

  printf 'WAIT | releasing %s %s to %s\n' "${RELEASE}" "${APP_VERSION}" "${ENVIRONMENT}"
  deploy_release
  test_release
  printf 'PASS | %s %s released and tested in %s\n' "${RELEASE}" "${APP_VERSION}" "${ENVIRONMENT}"
}

main "$@"
