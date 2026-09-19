#!/usr/bin/env bash
set -euo pipefail

[ -f app-image/index.json ] || { echo "app-image/ OCI layout missing" >&2; exit 1; }

echo "==> Scanning the image before publish and generating CycloneDX SBOM..."

trivy image --input app-image \
    --scanners vuln \
    --severity HIGH,CRITICAL \
    --exit-code "${TRIVY_EXIT_CODE:-0}" \
    --format cyclonedx \
    --output sbom.json \
    --no-progress

echo "Pre-publish security scan complete; SBOM written to sbom.json"
