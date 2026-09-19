# shellcheck shell=bash
# Sourced utility. Defining this file has no side effects; callers invoke
# helm_registry_login explicitly with the state directory and registry inputs.

helm_registry_login() {
  local state_directory="$1"
  local chart_ref="$2"
  local registry_username="$3"
  local registry_password="$4"
  local registry_host

  [[ -n "${state_directory}" ]] || {
    printf 'FAIL | Helm state directory is required\n' >&2
    return 1
  }
  [[ "${chart_ref}" == oci://* ]] || {
    printf 'FAIL | chart registry must be an OCI reference: %s\n' "${chart_ref}" >&2
    return 1
  }
  [[ -n "${registry_username}" ]] || {
    printf 'FAIL | registry username is required\n' >&2
    return 1
  }
  [[ -n "${registry_password}" ]] || {
    printf 'FAIL | registry password is required\n' >&2
    return 1
  }

  export HELM_REGISTRY_CONFIG="${state_directory}/helm-registry.json"
  export HELM_REPOSITORY_CONFIG="${state_directory}/helm-repositories.yaml"
  export HELM_REPOSITORY_CACHE="${state_directory}/helm-cache"
  mkdir -p -- "${HELM_REPOSITORY_CACHE}"

  registry_host="${chart_ref#oci://}"
  registry_host="${registry_host%%/*}"

  printf '%s' "${registry_password}" |
    helm registry login "${registry_host}" \
      --username "${registry_username}" \
      --password-stdin >/dev/null
}
