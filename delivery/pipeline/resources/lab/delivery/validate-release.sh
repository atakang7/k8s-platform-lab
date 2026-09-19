#!/usr/bin/env bash
# Server-side dry-run of the service chart in this environment's namespace:
# schema validation plus the admission chain, before the image exists.
set -Eeuo pipefail

readonly PLACEHOLDER_IMAGE_DIGEST='sha256:0000000000000000000000000000000000000000000000000000000000000000'
SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIRECTORY
WORK_DIRECTORY="$(mktemp -d)"
readonly WORK_DIRECTORY
trap 'rm -rf -- "${WORK_DIRECTORY}"' EXIT

# shellcheck source=helm-registry-login.sh
source "${SCRIPT_DIRECTORY}/helm-registry-login.sh"

require_inputs() {
  : "${CHART:?CHART is required}"
  : "${RELEASE:?RELEASE is required}"
  : "${NAMESPACE:?NAMESPACE is required}"
  : "${CHART_REF:?CHART_REF is required}"
  : "${REGISTRY_USERNAME:?REGISTRY_USERNAME is required}"
  : "${REGISTRY_PASSWORD:?REGISTRY_PASSWORD is required}"
}

prepare_chart() {
  helm_registry_login \
    "${WORK_DIRECTORY}" \
    "${CHART_REF}" \
    "${REGISTRY_USERNAME}" \
    "${REGISTRY_PASSWORD}"

  helm dependency build "${CHART}" >/dev/null
}

render_release() {
  helm template "${RELEASE}" "${CHART}" \
    --namespace "${NAMESPACE}" \
    --set-string image.digest="${PLACEHOLDER_IMAGE_DIGEST}" \
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
