#!/usr/bin/env bash
set -euo pipefail

IMAGE="${CI_AGENT_IMAGE:-docker.io/atakangul/lab-ci-agent:v1}"

echo "==> Building ${IMAGE}"
docker build -f delivery/jenkins/ci-agent.Dockerfile -t "${IMAGE}" .

echo "==> Pushing ${IMAGE}"
docker push "${IMAGE}"
