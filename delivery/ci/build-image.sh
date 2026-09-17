#!/bin/sh
set -eu

: "${IMAGE_REPOSITORY:?IMAGE_REPOSITORY is required}"
: "${COMMIT_SHA:?COMMIT_SHA is required}"

SHORT_SHA="$(printf '%s' "$COMMIT_SHA" | cut -c1-12)"
IMAGE_TAG="sha-${SHORT_SHA}"
TAGGED_REF="${IMAGE_REPOSITORY}:${IMAGE_TAG}"

echo "==> Building local scan candidate ${TAGGED_REF}"

buildctl build \
  --frontend dockerfile.v0 \
  --local context=app \
  --local dockerfile=app \
  --opt build-arg:SOURCE_REPOSITORY=https://github.com/atakang7/k8s-platform-lab \
  --opt build-arg:SOURCE_REVISION="${COMMIT_SHA}" \
  --output "type=docker,name=${TAGGED_REF},dest=app-image.tar"

printf 'IMAGE_TAG=%s\n' "$IMAGE_TAG" > image_tag.env

echo "Local scan candidate ready: app-image.tar"
