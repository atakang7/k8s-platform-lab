# shellcheck shell=bash
# Sourced by delivery scripts: logs Helm into the chart registry (CHART_REF)
# with a config file in the caller's temporary directory ($work).
: "${work:?}" "${CHART_REF:?}" "${REGISTRY_USERNAME:?}" "${REGISTRY_PASSWORD:?}"

# Isolated Helm state: nothing from the agent's home leaks into a release.
export HELM_REGISTRY_CONFIG="${work}/helm-registry.json"
export HELM_REPOSITORY_CONFIG="${work}/helm-repositories.yaml"
export HELM_REPOSITORY_CACHE="${work}/helm-cache"
registry_host="${CHART_REF#oci://}"
printf '%s' "${REGISTRY_PASSWORD}" |
  helm registry login "${registry_host%%/*}" --username "${REGISTRY_USERNAME}" --password-stdin >/dev/null
