#!/usr/bin/env bash
set -Eeuo pipefail

readonly image_layout=app-image
readonly sbom=sbom.json
readonly exit_code="${TRIVY_EXIT_CODE:-1}"
readonly severity="${TRIVY_SEVERITY:-CRITICAL}"

[[ -f "${image_layout}/index.json" ]] || {
  printf 'FAIL | %s OCI layout is missing\n' "${image_layout}" >&2
  exit 1
}

[[ "${exit_code}" =~ ^[0-9]+$ ]] || {
  printf 'FAIL | TRIVY_EXIT_CODE must be an integer\n' >&2
  exit 1
}
[[ "${severity}" =~ ^(UNKNOWN|LOW|MEDIUM|HIGH|CRITICAL)(,(UNKNOWN|LOW|MEDIUM|HIGH|CRITICAL))*$ ]] || {
  printf 'FAIL | TRIVY_SEVERITY is invalid: %s\n' "${severity}" >&2
  exit 1
}

printf '==> Scanning image for %s vulnerabilities\n' "${severity}"
trivy image \
  --input "${image_layout}" \
  --scanners vuln \
  --severity "${severity}" \
  --exit-code "${exit_code}" \
  --format cyclonedx \
  --output "${sbom}" \
  --no-progress

printf 'PASS | pre-publish scan completed; SBOM: %s\n' "${sbom}"
