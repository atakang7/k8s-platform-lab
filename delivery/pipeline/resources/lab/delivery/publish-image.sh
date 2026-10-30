#!/usr/bin/env bash
# Pushes the exact OCI layout that was scanned as <IMAGE_REPOSITORY>:<APP_VERSION>
# and writes its registry digest to pushed.digest. A version is published once:
# when the tag exists and was published from this service source
# (SERVICE_REVISION, the last commit that changed the service), its digest is
# reused (a rebuild, or a later main commit that did not touch the service);
# otherwise publication fails and the version must be raised. Publication
# also fails if the registry digest differs from the scanned manifest digest.
# The published digest is then signed with the delivery signing key
# (COSIGN_PRIVATE_KEY, COSIGN_PASSWORD); the deploy job verifies it.
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

# Prints the digest APP_VERSION was published as from this service source,
# nothing if the version is unpublished, and fails if it was published from
# different source.
read_published_digest() {
  local published_revision

  skopeo list-tags --authfile "${REGISTRY_AUTH_FILE}" "docker://${IMAGE_REPOSITORY}" 2>/dev/null |
    jq -e --arg version "${APP_VERSION}" '.Tags | index($version)' >/dev/null ||
    return 0

  published_revision="$(skopeo inspect --config \
    --authfile "${REGISTRY_AUTH_FILE}" \
    "docker://${IMAGE_REPOSITORY}:${APP_VERSION}" |
    jq -r '.config.Labels["org.opencontainers.image.revision"] // ""')"
  [[ "${published_revision}" == "${SERVICE_REVISION}" ]] || {
    printf 'FAIL | %s %s was published from source %s, this is %s; raise the version\n' \
      "${IMAGE_REPOSITORY}" "${APP_VERSION}" "${published_revision:-<unknown>}" "${SERVICE_REVISION}" >&2
    return 1
  }

  skopeo inspect --authfile "${REGISTRY_AUTH_FILE}" \
    "docker://${IMAGE_REPOSITORY}:${APP_VERSION}" | jq -r '.Digest'
}

# Key-based signature stored beside the image. Nothing goes to the public
# transparency log, which would publish the image names; the deploy job
# verifies against the key instead (validate-release.sh).
sign_image() {
  local digest="$1"

  cosign sign --yes \
    --key env://COSIGN_PRIVATE_KEY \
    --tlog-upload=false \
    --use-signing-config=false \
    "${IMAGE_REPOSITORY}@${digest}" >/dev/null
  printf 'PASS | signed %s@%s\n' "${IMAGE_REPOSITORY}" "${digest}"
}

main() {
  local scanned_digest
  local published_digest
  local pushed_digest
  local image_tag

  registry_login "${WORK_DIRECTORY}" "${IMAGE_REPOSITORY}"
  image_tag="${IMAGE_REPOSITORY}:${APP_VERSION}"

  published_digest="$(read_published_digest)"
  if [[ -n "${published_digest}" ]]; then
    printf '%s\n' "${published_digest}" > "${DIGEST_FILE}"
    printf 'PASS | %s is already published from this source as %s\n' \
      "${image_tag}" "${published_digest}"
    sign_image "${published_digest}"
    return
  fi

  scanned_digest="$(read_scanned_digest)"
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
  sign_image "${pushed_digest}"
}

main "$@"
