#!/usr/bin/env bash
set -euo pipefail

[ -f app-image.tar ] || { echo "app-image.tar missing" >&2; exit 1; }

echo "==> Scanning local image before publish and generating CycloneDX SBOM..."

trivy image --input app-image.tar \
    --scanners vuln \
    --severity HIGH,CRITICAL \
    --exit-code "${TRIVY_EXIT_CODE:-0}" \
    --format cyclonedx \
    --output sbom.json \
    --no-progress

echo "Pre-publish security scan complete; SBOM written to sbom.json"
