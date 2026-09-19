#!/usr/bin/env bash
# Scans the OCI layout build-image.sh produced and writes its CycloneDX SBOM.
# Any CRITICAL vulnerability fails the build, so nothing critical is published.
set -Eeuo pipefail

readonly IMAGE_LAYOUT=app-image
readonly SBOM_FILE=sbom.json

[[ -f "${IMAGE_LAYOUT}/index.json" ]] || {
  printf 'FAIL | %s OCI layout is missing\n' "${IMAGE_LAYOUT}" >&2
  exit 1
}

printf 'WAIT | scanning image for CRITICAL vulnerabilities\n'

trivy image \
  --input "${IMAGE_LAYOUT}" \
  --scanners vuln \
  --severity CRITICAL \
  --exit-code 1 \
  --format cyclonedx \
  --output "${SBOM_FILE}" \
  --no-progress

printf 'PASS | pre-publish scan completed; SBOM: %s\n' "${SBOM_FILE}"
