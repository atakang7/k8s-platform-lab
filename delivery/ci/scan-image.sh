#!/usr/bin/env bash
set -eo pipefail

echo "==> Scanning Image with Trivy..."
# Fail on HIGH, CRITICAL
trivy image --input app-image.tar \
    --severity HIGH,CRITICAL \
    --exit-code 1 \
    --no-progress

echo "==> Generating SBOM..."
trivy image --input app-image.tar \
    --format cyclonedx \
    --output sbom.json
