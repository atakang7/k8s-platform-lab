# shellcheck shell=bash
# Sourced. The one way delivery reaches registries: Helm (charts), skopeo
# (images) and cosign (signatures) all read the Docker-format auth file
# registry_login writes, and release_chart is the one way a step gets the chart
# it releases.
#
#   registry_login <state directory> <reference>...
#
# Each reference is an image repository or an oci:// chart reference; its host
# gets REGISTRY_USERNAME/REGISTRY_PASSWORD. Exports REGISTRY_AUTH_FILE and
# DOCKER_CONFIG, and points Helm's registry config and cache into the state
# directory.

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
    host="${host%%/*}"
    hosts+=("${host}")
    # Docker Hub credentials are looked up under this key by Helm and cosign,
    # whichever Docker Hub host a reference names.
    case "${host}" in
      docker.io | registry-1.docker.io | index.docker.io) hosts+=("https://index.docker.io/v1/") ;;
    esac
  done
  encoded_auth="$(printf '%s:%s' "${REGISTRY_USERNAME}" "${REGISTRY_PASSWORD}" |
    base64 | tr -d '\n')"

  export DOCKER_CONFIG="${state_directory}"
  export REGISTRY_AUTH_FILE="${DOCKER_CONFIG}/config.json"
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

#   release_chart <state directory>
#
# Points CHART at the chart RELEASE is released with. A local CHART directory
# (CI, before anything is published) gets its dependencies built; otherwise the
# chart is pulled at APP_VERSION, the version CI published it and the image as.
# Call registry_login first.

release_chart() {
  local state_directory="$1"

  if [[ -n "${CHART:-}" ]]; then
    helm dependency build "${CHART}" >/dev/null
    return
  fi

  helm pull "${CHART_REF}/${RELEASE}" \
    --version "${APP_VERSION}" \
    --untar \
    --destination "${state_directory}/chart"
  CHART="${state_directory}/chart/${RELEASE}"
}
