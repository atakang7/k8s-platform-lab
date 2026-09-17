#!/usr/bin/env bash
set -euo pipefail

: "${DOCKER_USER:?DOCKER_USER is required}"
: "${DOCKER_PASS:?DOCKER_PASS is required}"

IMAGE_REF="$(sed -n 's/^IMAGE_REF=//p' image_ref.env | head -n1)"
[ -n "$IMAGE_REF" ] || { echo "IMAGE_REF missing from image_ref.env" >&2; exit 1; }

echo "==> Scanning published image and generating CycloneDX SBOM..."

export TRIVY_USERNAME="$DOCKER_USER"
export TRIVY_PASSWORD="$DOCKER_PASS"
trivy image "$IMAGE_REF" \
    --scanners vuln \
    --severity HIGH,CRITICAL \
    --exit-code 0 \
    --format cyclonedx \
    --output sbom.json \
    --no-progress
unset TRIVY_USERNAME TRIVY_PASSWORD

echo "Security scan complete; SBOM written to sbom.json"
