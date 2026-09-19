#!/bin/sh
# Builds the service image once, running its unit tests, into an OCI layout
# directory. That directory is what scan-image.sh scans and what
# publish-image.sh pushes; nothing is rebuilt after the scan.
set -eu

printf 'WAIT | building %s at %s into app-image/\n' "${BUILD_CONTEXT}" "${COMMIT_SHA}"

rm -rf app-image
buildctl build \
  --frontend dockerfile.v0 \
  --local context="${BUILD_CONTEXT}" \
  --local dockerfile="${BUILD_CONTEXT}" \
  --opt build-arg:SOURCE_REPOSITORY="${SOURCE_URL}" \
  --opt build-arg:SOURCE_REVISION="${SERVICE_REVISION}" \
  --output "type=oci,tar=false,dest=app-image"

printf 'PASS | image ready: app-image/\n'
