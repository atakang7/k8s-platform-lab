#!/usr/bin/env bash
set -Eeuo pipefail

readonly IMAGE_LAYOUT=app-image
readonly SBOM_FILE=sbom.json
readonly TRIVY_POLICY_EXIT_CODE="${TRIVY_EXIT_CODE:-1}"
readonly TRIVY_POLICY_SEVERITY="${TRIVY_SEVERITY:-CRITICAL}"

validate_inputs() {
  [[ -f "${IMAGE_LAYOUT}/index.json" ]] || {
    printf 'FAIL | %s OCI layout is missing\n' "${IMAGE_LAYOUT}" >&2
    exit 1
  }

  [[ "${TRIVY_POLICY_EXIT_CODE}" =~ ^[0-9]+$ ]] || {
    printf 'FAIL | TRIVY_EXIT_CODE must be an integer\n' >&2
    exit 1
  }

  [[ "${TRIVY_POLICY_SEVERITY}" =~ ^(UNKNOWN|LOW|MEDIUM|HIGH|CRITICAL)(,(UNKNOWN|LOW|MEDIUM|HIGH|CRITICAL))*$ ]] || {
    printf 'FAIL | TRIVY_SEVERITY is invalid: %s\n' "${TRIVY_POLICY_SEVERITY}" >&2
    exit 1
  }
}

scan_image() {
  printf 'WAIT | scanning image for %s vulnerabilities\n' "${TRIVY_POLICY_SEVERITY}"

  trivy image \
    --input "${IMAGE_LAYOUT}" \
    --scanners vuln \
    --severity "${TRIVY_POLICY_SEVERITY}" \
    --exit-code "${TRIVY_POLICY_EXIT_CODE}" \
    --format cyclonedx \
    --output "${SBOM_FILE}" \
    --no-progress

  printf 'PASS | pre-publish scan completed; SBOM: %s\n' "${SBOM_FILE}"
}

main() {
  validate_inputs
  scan_image
}

main "$@"
