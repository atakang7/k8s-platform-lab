#!/usr/bin/env bash
# Scans the OCI layout build-image.sh produced, prints every CRITICAL
# vulnerability in the build log, and writes the image's CycloneDX SBOM. Any
# CRITICAL vulnerability fails the build, so nothing critical is published.
set -Eeuo pipefail

readonly IMAGE_LAYOUT=app-image
readonly REPORT_FILE=trivy-report.json
readonly SBOM_FILE=sbom.json

[[ -f "${IMAGE_LAYOUT}/index.json" ]] || {
  printf 'FAIL | %s OCI layout is missing\n' "${IMAGE_LAYOUT}" >&2
  exit 1
}

printf 'WAIT | scanning image for CRITICAL vulnerabilities\n'

# One scan: the report lists every package (for the SBOM) and the findings.
status=0
trivy image \
  --input "${IMAGE_LAYOUT}" \
  --scanners vuln \
  --severity CRITICAL \
  --list-all-pkgs \
  --exit-code 1 \
  --format json \
  --output "${REPORT_FILE}" \
  --no-progress || status=$?

trivy convert --format table "${REPORT_FILE}"
trivy convert --format cyclonedx --output "${SBOM_FILE}" "${REPORT_FILE}"

if [[ "${status}" -ne 0 ]]; then
  printf 'FAIL | CRITICAL vulnerabilities found (listed above); SBOM: %s\n' "${SBOM_FILE}" >&2
  exit "${status}"
fi
printf 'PASS | no CRITICAL vulnerabilities; SBOM: %s\n' "${SBOM_FILE}"
