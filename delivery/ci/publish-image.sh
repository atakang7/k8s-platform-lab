#!/usr/bin/env bash
set -euo pipefail

: "${IMAGE_REPOSITORY:?IMAGE_REPOSITORY is required}"
: "${DOCKER_USER:?DOCKER_USER is required}"
: "${DOCKER_PASS:?DOCKER_PASS is required}"

COMMIT_SHA="$(git rev-parse --short=12 HEAD)"
IMAGE_TAG="sha-${COMMIT_SHA}"
TAGGED_REF="${IMAGE_REPOSITORY}:${IMAGE_TAG}"

echo "==> Authenticating to DockerHub"
printf '%s' "$DOCKER_PASS" | skopeo login --username "$DOCKER_USER" --password-stdin docker.io >/dev/null

echo "==> Publishing ${IMAGE_TAG}"
skopeo copy docker-archive:app-image.tar "docker://${TAGGED_REF}" >/dev/null

echo "==> Resolving immutable digest"
DIGEST="$(skopeo inspect "docker://${TAGGED_REF}" --format '{{.Digest}}')"
printf 'IMAGE_REF=%s@%s\n' "$IMAGE_REPOSITORY" "$DIGEST" > image_ref.env
printf 'IMAGE_TAG=%s\n' "$IMAGE_TAG" > image_tag.env

echo "Published ${IMAGE_TAG}"
echo "Resolved immutable digest"
