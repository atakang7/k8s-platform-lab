#!/bin/sh
set -eu

: "${IMAGE_REPOSITORY:?IMAGE_REPOSITORY is required}"
: "${COMMIT_SHA:?COMMIT_SHA is required}"

SHORT_SHA="$(printf '%s' "$COMMIT_SHA" | cut -c1-12)"
IMAGE_TAG="sha-${SHORT_SHA}"
TAGGED_REF="${IMAGE_REPOSITORY}:${IMAGE_TAG}"
META_FILE="image-metadata.json"

echo "==> Building and publishing ${TAGGED_REF} with BuildKit"

buildctl build \
  --frontend dockerfile.v0 \
  --local context=app \
  --local dockerfile=app \
  --opt build-arg:SOURCE_REPOSITORY=https://github.com/atakang7/k8s-platform-lab \
  --opt build-arg:SOURCE_REVISION="${COMMIT_SHA}" \
  --output "type=image,name=${TAGGED_REF},push=true" \
  --metadata-file "${META_FILE}"

DIGEST="$(sed -n 's/.*"containerimage.digest"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "${META_FILE}" | head -n1)"

if [ -z "${DIGEST}" ]; then
  echo "ERROR: BuildKit did not return containerimage.digest" >&2
  cat "${META_FILE}" >&2
  exit 1
fi

printf 'IMAGE_REF=%s@%s\n' "$IMAGE_REPOSITORY" "$DIGEST" > image_ref.env
printf 'IMAGE_TAG=%s\n' "$IMAGE_TAG" > image_tag.env

echo "Published ${IMAGE_TAG}"
echo "Resolved immutable digest ${DIGEST}"
