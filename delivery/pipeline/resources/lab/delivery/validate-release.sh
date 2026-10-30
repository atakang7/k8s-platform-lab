#!/usr/bin/env bash
# Server-side dry-run of a service chart in one environment's namespace, with
# that environment's values (values-<ENVIRONMENT>.yaml when the chart has one):
# schema validation plus the admission chain. CI dry-runs its local CHART before
# the image exists, so a placeholder digest stands in; the deploy job dry-runs
# the recorded release (APP_VERSION and IMAGE_DIGEST), and first verifies that
# every image the release runs at that digest carries the delivery signature
# (cosign.pub, installed by the deploy job from the delivery library).
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

  # --skip-tests: Helm replaces its test Pod itself (before-hook-creation);
  # applying it would try to mutate the last run's immutable Pod.
  helm template "${RELEASE}" "${CHART}" \
    --namespace "${NAMESPACE}" \
    --skip-tests \
    "${values[@]}" \
    --set-string image.digest="${IMAGE_DIGEST:-${PLACEHOLDER_IMAGE_DIGEST}}" \
    > "${WORK_DIRECTORY}/release.yaml"
}

verify_signatures() {
  local images=()
  local image

  mapfile -t images < <(grep -oE "[^\"' ]+@${IMAGE_DIGEST}" "${WORK_DIRECTORY}/release.yaml" | sort -u)
  [[ "${#images[@]}" -gt 0 ]] || {
    printf 'FAIL | %s does not run %s\n' "${RELEASE}" "${IMAGE_DIGEST}" >&2
    exit 1
  }

  registry_login "${WORK_DIRECTORY}" "${CHART_REF}" "${images[@]}"
  for image in "${images[@]}"; do
    cosign verify \
      --key "${SCRIPT_DIRECTORY}/cosign.pub" \
      --insecure-ignore-tlog=true \
      "${image}" >/dev/null
    printf 'PASS | %s is signed by delivery\n' "${image}"
  done
}

validate_with_api_server() {
  kubectl apply \
    --dry-run=server \
    -f "${WORK_DIRECTORY}/release.yaml"
}

main() {
  prepare_chart
  render_release
  # CI dry-runs before the image exists; only a recorded release has a digest.
  if [[ -n "${IMAGE_DIGEST:-}" ]]; then
    verify_signatures
  fi
  validate_with_api_server
}

main "$@"
