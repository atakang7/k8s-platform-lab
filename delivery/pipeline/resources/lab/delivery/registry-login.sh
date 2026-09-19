# shellcheck shell=bash
# Sourced. The one way delivery authenticates to registries: Helm (charts) and
# skopeo (images) both read the Docker-format auth file written here.
#
#   registry_login <state directory> <reference>...
#
# Each reference is an image repository or an oci:// chart reference; its host
# gets REGISTRY_USERNAME/REGISTRY_PASSWORD. Exports REGISTRY_AUTH_FILE and
# points Helm's registry config and cache into the state directory.

registry_login() {
  local state_directory="$1"
  shift
  local hosts=()
  local reference
  local host
  local encoded_auth

  : "${REGISTRY_USERNAME:?REGISTRY_USERNAME is required}"
  : "${REGISTRY_PASSWORD:?REGISTRY_PASSWORD is required}"

  for reference in "$@"; do
    host="${reference#oci://}"
    hosts+=("${host%%/*}")
  done
  encoded_auth="$(printf '%s:%s' "${REGISTRY_USERNAME}" "${REGISTRY_PASSWORD}" |
    base64 | tr -d '\n')"

  export REGISTRY_AUTH_FILE="${state_directory}/registry-auth.json"
  export HELM_REGISTRY_CONFIG="${REGISTRY_AUTH_FILE}"
  export HELM_REPOSITORY_CONFIG="${state_directory}/helm-repositories.yaml"
  export HELM_REPOSITORY_CACHE="${state_directory}/helm-cache"
  mkdir -p -- "${HELM_REPOSITORY_CACHE}"

  (
    umask 077
    jq -n --arg auth "${encoded_auth}" \
      '{auths: ($ARGS.positional | map({key: ., value: {auth: $auth}}) | from_entries)}' \
      --args "${hosts[@]}" > "${REGISTRY_AUTH_FILE}"
  )
}
