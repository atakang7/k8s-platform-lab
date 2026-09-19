#!/bin/sh
# Builds the service image once, running its unit tests, into an OCI layout
# directory. That directory is what scan-image.sh scans and what
# publish-image.sh pushes; nothing is rebuilt after the scan.
set -eu

: "${BUILD_CONTEXT:?BUILD_CONTEXT is required}"
: "${COMMIT_SHA:?COMMIT_SHA is required}"
: "${SOURCE_URL:?SOURCE_URL is required}"

echo "==> Building ${BUILD_CONTEXT} at ${COMMIT_SHA} into OCI layout app-image/"

rm -rf app-image
buildctl build \
  --frontend dockerfile.v0 \
  --local context="${BUILD_CONTEXT}" \
  --local dockerfile="${BUILD_CONTEXT}" \
  --opt build-arg:SOURCE_REPOSITORY="${SOURCE_URL}" \
  --opt build-arg:SOURCE_REVISION="${COMMIT_SHA}" \
  --output "type=oci,tar=false,dest=app-image"

echo "Image ready: app-image/"
