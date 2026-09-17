#!/usr/bin/env bash
set -eo pipefail

COMMIT_SHA=$(git rev-parse --short HEAD)
IMAGE_TAG="sha-${COMMIT_SHA}"
IMAGE_REF="${DOCKER_REGISTRY}/lab-app:${IMAGE_TAG}"

echo "==> Publishing Image..."
skopeo copy docker-archive:app-image.tar docker://${IMAGE_REF}

# Publish SemVer tag if it's a tag build
if [[ "$GIT_BRANCH" == refs/tags/v* ]]; then
    SEMVER_TAG="${GIT_BRANCH#refs/tags/}"
    SEMVER_REF="${DOCKER_REGISTRY}/lab-app:${SEMVER_TAG}"
    echo "==> Publishing SemVer tag: ${SEMVER_TAG}"
    skopeo copy docker-archive:app-image.tar docker://${SEMVER_REF}
fi

echo "==> Resolving Immutable Digest..."
DIGEST=$(skopeo inspect docker://${IMAGE_REF} --format '{{.Digest}}')
echo "IMAGE_REF=${DOCKER_REGISTRY}/lab-app@${DIGEST}" > image_ref.env

echo "Resolved Digest: ${DIGEST}"
