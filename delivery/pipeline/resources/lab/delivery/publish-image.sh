#!/usr/bin/env bash
# Pushes the exact OCI layout that was scanned and writes its registry digest
# to pushed.digest. Publication fails if the registry digest differs
# from the scanned manifest digest.
set -Eeuo pipefail

readonly IMAGE_LAYOUT=app-image
readonly IMAGE_INDEX="${IMAGE_LAYOUT}/index.json"
readonly DIGEST_FILE=pushed.digest
SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIRECTORY
WORK_DIRECTORY="$(mktemp -d)"
readonly WORK_DIRECTORY
trap 'rm -rf -- "${WORK_DIRECTORY}"' EXIT

# shellcheck source=registry.sh
source "${SCRIPT_DIRECTORY}/registry.sh"

read_scanned_digest() {
  local manifest_count

  manifest_count="$(jq -r '.manifests | length' "${IMAGE_INDEX}")"
  [[ "${manifest_count}" == 1 ]] || {
    printf 'FAIL | %s must contain exactly one image manifest\n' "${IMAGE_LAYOUT}" >&2
    return 1
  }

  jq -er '.manifests[0].digest' "${IMAGE_INDEX}"
}

main() {
  local scanned_digest
  local pushed_digest
  local image_tag

  registry_login "${WORK_DIRECTORY}" "${IMAGE_REPOSITORY}"
  scanned_digest="$(read_scanned_digest)"
  image_tag="${IMAGE_REPOSITORY}:sha-${COMMIT_SHA:0:12}"

  printf 'WAIT | publishing scanned image %s as %s\n' \
    "${scanned_digest}" "${image_tag}"

  skopeo copy \
    --authfile "${REGISTRY_AUTH_FILE}" \
    --digestfile "${DIGEST_FILE}" \
    "oci:${IMAGE_LAYOUT}" \
    "docker://${image_tag}"

  pushed_digest="$(<"${DIGEST_FILE}")"
  [[ "${pushed_digest}" == "${scanned_digest}" ]] || {
    printf 'FAIL | registry digest %s differs from scanned %s\n' \
      "${pushed_digest}" "${scanned_digest}" >&2
    exit 1
  }

  printf 'PASS | published %s@%s\n' "${IMAGE_REPOSITORY}" "${pushed_digest}"
}

main "$@"
