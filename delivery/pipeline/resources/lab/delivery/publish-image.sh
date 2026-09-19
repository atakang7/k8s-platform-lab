#!/usr/bin/env bash
# Pushes the scanned OCI layout unchanged and records its immutable reference.
# Fails if the registry digest differs from the scanned manifest digest, so
# the published image is provably the scanned image.
set -euo pipefail

: "${IMAGE_REPOSITORY:?IMAGE_REPOSITORY is required}"
: "${COMMIT_SHA:?COMMIT_SHA is required}"
: "${REGISTRY_USERNAME:?}" "${REGISTRY_PASSWORD:?}"

work="$(mktemp -d)"
trap 'rm -rf -- "${work}"' EXIT
(umask 077; printf '{"auths":{"%s":{"auth":"%s"}}}' "${IMAGE_REPOSITORY%%/*}" \
  "$(printf '%s:%s' "${REGISTRY_USERNAME}" "${REGISTRY_PASSWORD}" | base64 | tr -d '\n')" > "${work}/auth.json")

[[ "$(jq '.manifests | length' app-image/index.json)" == 1 ]] ||
  { echo "FAIL | app-image/ must hold exactly one image manifest" >&2; exit 1; }
scanned="$(jq -r '.manifests[0].digest' app-image/index.json)"
tagged="${IMAGE_REPOSITORY}:sha-${COMMIT_SHA:0:12}"

echo "==> Publishing scanned image ${scanned} as ${tagged}"
skopeo copy --authfile "${work}/auth.json" --digestfile pushed.digest \
  oci:app-image "docker://${tagged}"
pushed="$(cat pushed.digest)"

[[ "${pushed}" == "${scanned}" ]] ||
  { echo "FAIL | registry digest ${pushed} differs from scanned ${scanned}" >&2; exit 1; }

printf 'IMAGE_REF=%s@%s\n' "${IMAGE_REPOSITORY}" "${pushed}" > image_ref.env
echo "Published ${IMAGE_REPOSITORY}@${pushed}"
