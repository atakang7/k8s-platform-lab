#!/usr/bin/env bash
set -eo pipefail

echo "==> Benchmarking Build Cache..."

# A - Cold Build
echo "==> Running cold build..."
START_COLD=$(date +%s)
buildctl build \
    --frontend dockerfile.v0 \
    --local context=app \
    --local dockerfile=app \
    --output type=docker,dest=cold-image.tar \
    --no-cache
END_COLD=$(date +%s)
ELAPSED_COLD=$((END_COLD - START_COLD))
SIZE_COLD=$(stat -c%s cold-image.tar)

# B - Cached Build
echo "==> Running cached build..."
START_CACHED=$(date +%s)
buildctl build \
    --frontend dockerfile.v0 \
    --local context=app \
    --local dockerfile=app \
    --output type=docker,dest=cached-image.tar \
    --export-cache type=registry,ref=${DOCKER_REGISTRY}/app-buildcache \
    --import-cache type=registry,ref=${DOCKER_REGISTRY}/app-buildcache
END_CACHED=$(date +%s)
ELAPSED_CACHED=$((END_CACHED - START_CACHED))
SIZE_CACHED=$(stat -c%s cached-image.tar)

echo "COLD BUILD vs CACHED BUILD" > build-benchmark.txt
echo "--------------------------" >> build-benchmark.txt
echo "Cold Build Time   : ${ELAPSED_COLD}s" >> build-benchmark.txt
echo "Cold Image Size   : ${SIZE_COLD} bytes" >> build-benchmark.txt
echo "Cached Build Time : ${ELAPSED_CACHED}s" >> build-benchmark.txt
echo "Cached Image Size : ${SIZE_CACHED} bytes" >> build-benchmark.txt

cat build-benchmark.txt
