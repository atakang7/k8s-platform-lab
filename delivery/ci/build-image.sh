#!/bin/sh
# Builds the application image once, running its unit tests, into an OCI
# layout directory. That directory is what scan-image.sh scans and what
# publish-image.sh pushes; nothing is rebuilt after the scan.
set -eu

: "${COMMIT_SHA:?COMMIT_SHA is required}"

echo "==> Building ${COMMIT_SHA} into OCI layout app-image/"

rm -rf app-image
buildctl build \
  --frontend dockerfile.v0 \
  --local context=app \
  --local dockerfile=app \
  --opt build-arg:SOURCE_REPOSITORY=https://github.com/atakang7/k8s-platform-lab \
  --opt build-arg:SOURCE_REVISION="${COMMIT_SHA}" \
  --output "type=oci,tar=false,dest=app-image"

echo "Image ready: app-image/"
