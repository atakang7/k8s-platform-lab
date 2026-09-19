#!/usr/bin/env bash
# Publishes a base chart version only when that exact version is absent from the
# registry. Pull requests enforce version bumps with chart-testing.
set -Eeuo pipefail

SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIRECTORY
WORK_DIRECTORY="$(mktemp -d)"
readonly WORK_DIRECTORY
trap 'rm -rf -- "${WORK_DIRECTORY}"' EXIT

# shellcheck source=registry-login.sh
source "${SCRIPT_DIRECTORY}/registry-login.sh"

require_inputs() {
  : "${CHART_DIR:?CHART_DIR is required}"
  : "${CHART_REF:?CHART_REF is required}"
  : "${REGISTRY_USERNAME:?REGISTRY_USERNAME is required}"
  : "${REGISTRY_PASSWORD:?REGISTRY_PASSWORD is required}"
}

read_chart_identity() {
  local metadata="$1"
  local field="$2"

  sed -n "s/^${field}: //p" <<< "${metadata}" | head -n1
}

main() {
  local chart_metadata
  local chart_name
  local chart_version
  local package_path

  require_inputs
  registry_login "${WORK_DIRECTORY}" "${CHART_REF}"

  chart_metadata="$(helm show chart "${CHART_DIR}")"
  chart_name="$(read_chart_identity "${chart_metadata}" name)"
  chart_version="$(read_chart_identity "${chart_metadata}" version)"

  [[ -n "${chart_name}" ]] || {
    printf 'FAIL | %s does not declare a chart name\n' "${CHART_DIR}" >&2
    exit 1
  }
  [[ -n "${chart_version}" ]] || {
    printf 'FAIL | %s does not declare a chart version\n' "${CHART_DIR}" >&2
    exit 1
  }

  if helm show chart \
    "${CHART_REF}/${chart_name}" \
    --version "${chart_version}" >/dev/null 2>&1; then
    printf 'PASS | %s %s is already published\n' "${chart_name}" "${chart_version}"
    return
  fi

  helm package "${CHART_DIR}" --destination "${WORK_DIRECTORY}" >/dev/null
  package_path="${WORK_DIRECTORY}/${chart_name}-${chart_version}.tgz"
  [[ -f "${package_path}" ]] || {
    printf 'FAIL | Helm did not produce expected package: %s\n' "${package_path}" >&2
    exit 1
  }

  helm push "${package_path}" "${CHART_REF}"
  printf 'PASS | published %s/%s:%s\n' \
    "${CHART_REF}" "${chart_name}" "${chart_version}"
}

main "$@"
