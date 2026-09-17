#!/usr/bin/env bash
set -euo pipefail

: "${IMAGE_REPOSITORY:?IMAGE_REPOSITORY is required}"
: "${CACHE_REF:?CACHE_REF is required}"

echo "==> Building image with BuildKit"
buildctl build \
  --frontend dockerfile.v0 \
  --local context=app \
  --local dockerfile=app \
  --opt build-arg:SOURCE_REPOSITORY=https://github.com/atakang7/k8s-platform-lab \
  --opt build-arg:SOURCE_REVISION="$(git rev-parse HEAD)" \
  --output type=docker,dest=app-image.tar \
  --export-cache type=registry,ref="${CACHE_REF}",mode=max \
  --import-cache type=registry,ref="${CACHE_REF}"
