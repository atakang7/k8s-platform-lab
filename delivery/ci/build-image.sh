#!/bin/sh
set -eu

: "${IMAGE_REPOSITORY:?IMAGE_REPOSITORY is required}"
: "${COMMIT_SHA:?COMMIT_SHA is required}"

build_image() {
  buildctl build \
    --frontend dockerfile.v0 \
    --local context=app \
    --local dockerfile=app \
    --opt build-arg:SOURCE_REPOSITORY=https://github.com/atakang7/k8s-platform-lab \
    --opt build-arg:SOURCE_REVISION="${COMMIT_SHA}" \
    --output type=docker,dest=app-image.tar \
    "$@"
}

echo "==> Building image with BuildKit"

if [ "${ENABLE_REGISTRY_CACHE:-false}" = "true" ]; then
  : "${CACHE_REF:?CACHE_REF is required when registry cache is enabled}"
  build_image \
    --export-cache "type=registry,ref=${CACHE_REF},mode=min" \
    --import-cache "type=registry,ref=${CACHE_REF}"
else
  echo "==> Registry cache disabled for fast local CI"
  build_image
fi
