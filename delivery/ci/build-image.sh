#!/usr/bin/env bash
set -eo pipefail

echo "==> Building Image with BuildKit..."
buildctl build \
    --frontend dockerfile.v0 \
    --local context=app \
    --local dockerfile=app \
    --output type=docker,dest=app-image.tar \
    --export-cache type=registry,ref=${DOCKER_REGISTRY}/app-buildcache \
    --import-cache type=registry,ref=${DOCKER_REGISTRY}/app-buildcache
