#!/usr/bin/env bash
# Server-side dry-run of a service chart in one environment's namespace, with
# that environment's values (values-<ENVIRONMENT>.yaml when the chart has one):
# schema validation plus the admission chain. CI runs it before the image
# exists, so without IMAGE_DIGEST a placeholder digest stands in.
set -Eeuo pipefail

readonly PLACEHOLDER_IMAGE_DIGEST='sha256:0000000000000000000000000000000000000000000000000000000000000000'
SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIRECTORY
WORK_DIRECTORY="$(mktemp -d)"
readonly WORK_DIRECTORY
trap 'rm -rf -- "${WORK_DIRECTORY}"' EXIT

# shellcheck source=registry-login.sh
source "${SCRIPT_DIRECTORY}/registry-login.sh"

require_inputs() {
  : "${CHART:?CHART is required}"
  : "${RELEASE:?RELEASE is required}"
  : "${NAMESPACE:?NAMESPACE is required}"
  : "${ENVIRONMENT:?ENVIRONMENT is required}"
  : "${CHART_REF:?CHART_REF is required}"
  : "${REGISTRY_USERNAME:?REGISTRY_USERNAME is required}"
  : "${REGISTRY_PASSWORD:?REGISTRY_PASSWORD is required}"
}

prepare_chart() {
  registry_login "${WORK_DIRECTORY}" "${CHART_REF}"

  helm dependency build "${CHART}" >/dev/null
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
  require_inputs
  prepare_chart
  render_release
  validate_with_api_server
}

main "$@"
