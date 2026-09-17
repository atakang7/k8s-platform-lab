#!/usr/bin/env bash
set -eo pipefail

echo "==> Running Quality Gates..."

echo "==> Validating Maven pom.xml..."
mvn -B validate -f app/pom.xml || { echo "Maven validate failed"; exit 1; }

echo "==> Linting Dockerfile with hadolint..."
docker run --rm -i hadolint/hadolint < app/Dockerfile || { echo "Hadolint failed"; exit 1; }

echo "==> Linting Kubernetes manifests..."
docker run --rm -v $(pwd):/workdir ghcr.io/yannh/kubeconform:latest -strict -summary /workdir/app/k8s/ || { echo "Kubeconform failed"; exit 1; }

echo "==> Quality Gates Passed."
