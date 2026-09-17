#!/usr/bin/env bash
set -euo pipefail

: "${IMAGE_REPOSITORY:?IMAGE_REPOSITORY is required}"
: "${DOCKER_USER:?DOCKER_USER is required}"
: "${DOCKER_PASS:?DOCKER_PASS is required}"
: "${COMMIT_SHA:?COMMIT_SHA is required}"

SHORT_SHA="${COMMIT_SHA:0:12}"
IMAGE_TAG="sha-${SHORT_SHA}"
TAGGED_REF="${IMAGE_REPOSITORY}:${IMAGE_TAG}"

step_start() {
  STEP_STARTED="$(date +%s%3N)"
}

step_done() {
  local label="$1"
  local now
  now="$(date +%s%3N)"
  echo "PUSH_TIMING|${label}|$((now - STEP_STARTED))"
}

echo "==> Authenticating to DockerHub"
step_start
printf '%s' "$DOCKER_PASS" | skopeo login --username "$DOCKER_USER" --password-stdin docker.io >/dev/null
step_done Login

echo "==> Publishing ${IMAGE_TAG}"
step_start
skopeo copy docker-archive:app-image.tar "docker://${TAGGED_REF}" >/dev/null
step_done Copy

echo "==> Resolving immutable digest"
step_start
DIGEST="$(skopeo inspect "docker://${TAGGED_REF}" --format '{{.Digest}}')"
step_done Inspect

printf 'IMAGE_REF=%s@%s\n' "$IMAGE_REPOSITORY" "$DIGEST" > image_ref.env
printf 'IMAGE_TAG=%s\n' "$IMAGE_TAG" > image_tag.env

echo "Published ${IMAGE_TAG}"
echo "Resolved immutable digest"
