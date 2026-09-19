#!/usr/bin/env bash
# Server-side dry-run of a service chart in one environment's namespace, with
# that environment's values (values-<ENVIRONMENT>.yaml when the chart has one):
# schema validation plus the admission chain. CI dry-runs its local CHART before
# the image exists, so a placeholder digest stands in; the deploy job dry-runs
# the recorded release (APP_VERSION and IMAGE_DIGEST).
set -Eeuo pipefail

readonly PLACEHOLDER_IMAGE_DIGEST='sha256:0000000000000000000000000000000000000000000000000000000000000000'
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

render_release() {
  local values=()

  if [[ -f "${CHART}/values-${ENVIRONMENT}.yaml" ]]; then
    values=(--values "${CHART}/values-${ENVIRONMENT}.yaml")
  fi

  helm template "${RELEASE}" "${CHART}" \
    --namespace "${NAMESPACE}" \
    "${values[@]}" \
    --set-string image.digest="${IMAGE_DIGEST:-${PLACEHOLDER_IMAGE_DIGEST}}" \
    > "${WORK_DIRECTORY}/release.yaml"
}

validate_with_api_server() {
  kubectl apply \
    --dry-run=server \
    -f "${WORK_DIRECTORY}/release.yaml"
}

main() {
  prepare_chart
  render_release
  validate_with_api_server
}

main "$@"
