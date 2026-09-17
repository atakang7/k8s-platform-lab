#!/usr/bin/env bash
set -eo pipefail

echo "==> Scanning image with Trivy (report-only for the legacy sample app)..."
trivy image --input app-image.tar \
    --severity HIGH,CRITICAL \
    --exit-code 0 \
    --no-progress

echo "==> Generating SBOM..."
trivy image --input app-image.tar \
    --format cyclonedx \
    --output sbom.json
