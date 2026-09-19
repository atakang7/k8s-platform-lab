#!/usr/bin/env bash
# Prints the Git commit a published image was built from: its
# org.opencontainers.image.revision label, set by build-image.sh. The deploy
# job takes the chart from that commit. Fails when the image is missing from
# the registry or does not declare a full commit SHA.
set -Eeuo pipefail

SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIRECTORY
WORK_DIRECTORY="$(mktemp -d)"
readonly WORK_DIRECTORY
trap 'rm -rf -- "${WORK_DIRECTORY}"' EXIT

# shellcheck source=registry-login.sh
source "${SCRIPT_DIRECTORY}/registry-login.sh"

require_inputs() {
  : "${IMAGE_REPOSITORY:?IMAGE_REPOSITORY is required}"
  : "${IMAGE_DIGEST:?IMAGE_DIGEST is required}"
  : "${REGISTRY_USERNAME:?REGISTRY_USERNAME is required}"
  : "${REGISTRY_PASSWORD:?REGISTRY_PASSWORD is required}"

  [[ "${IMAGE_DIGEST}" =~ ^sha256:[0-9a-f]{64}$ ]] || {
    printf 'FAIL | IMAGE_DIGEST must be sha256:<64 hex>\n' >&2
    exit 1
  }
}

read_image_revision() {
  local image_reference
  local image_revision

  image_reference="${IMAGE_REPOSITORY}@${IMAGE_DIGEST}"
  image_revision="$(skopeo inspect \
    --authfile "${REGISTRY_AUTH_FILE}" \
    --config "docker://${image_reference}" |
    jq -r '.config.Labels["org.opencontainers.image.revision"] // ""')"

  [[ "${image_revision}" =~ ^[0-9a-f]{40}$ ]] || {
    printf 'FAIL | image %s declares revision %s, expected a full Git SHA\n' \
      "${image_reference}" "${image_revision:-<missing>}" >&2
    exit 1
  }

  printf '%s\n' "${image_revision}"
}

main() {
  require_inputs
  registry_login "${WORK_DIRECTORY}" "${IMAGE_REPOSITORY}"
  read_image_revision
}

main "$@"
