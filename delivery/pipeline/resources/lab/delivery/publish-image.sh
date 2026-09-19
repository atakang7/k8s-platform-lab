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

# shellcheck source=registry-login.sh
source "${SCRIPT_DIRECTORY}/registry-login.sh"

require_inputs() {
  : "${IMAGE_REPOSITORY:?IMAGE_REPOSITORY is required}"
  : "${COMMIT_SHA:?COMMIT_SHA is required}"
  : "${REGISTRY_USERNAME:?REGISTRY_USERNAME is required}"
  : "${REGISTRY_PASSWORD:?REGISTRY_PASSWORD is required}"

  [[ "${COMMIT_SHA}" =~ ^[0-9a-f]{40}$ ]] || {
    printf 'FAIL | COMMIT_SHA must be a full lowercase Git SHA\n' >&2
    exit 1
  }
  [[ -f "${IMAGE_INDEX}" ]] || {
    printf 'FAIL | OCI image index is missing: %s\n' "${IMAGE_INDEX}" >&2
    exit 1
  }
}

read_scanned_digest() {
  local manifest_count
  local digest

  manifest_count="$(jq -r '.manifests | length' "${IMAGE_INDEX}")"
  [[ "${manifest_count}" == 1 ]] || {
    printf 'FAIL | %s must contain exactly one image manifest\n' "${IMAGE_LAYOUT}" >&2
    return 1
  }

  digest="$(jq -er '.manifests[0].digest' "${IMAGE_INDEX}")"
  [[ "${digest}" =~ ^sha256:[0-9a-f]{64}$ ]] || {
    printf 'FAIL | invalid scanned manifest digest: %s\n' "${digest}" >&2
    return 1
  }

  printf '%s\n' "${digest}"
}

main() {
  local scanned_digest
  local pushed_digest
  local image_tag

  require_inputs
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
