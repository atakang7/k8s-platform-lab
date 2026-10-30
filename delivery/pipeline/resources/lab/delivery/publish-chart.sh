#!/usr/bin/env bash
# Publishes the chart in CHART_DIR at its Chart.yaml version, only when that
# version is absent from the registry. Base chart pull requests enforce version
# bumps with chart-testing; a service chart's version is its app version, which
# service CI checks, and publish-image.sh has already refused a reused one.
set -Eeuo pipefail

SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIRECTORY
WORK_DIRECTORY="$(mktemp -d)"
readonly WORK_DIRECTORY
trap 'rm -rf -- "${WORK_DIRECTORY}"' EXIT

# shellcheck source=registry.sh
source "${SCRIPT_DIRECTORY}/registry.sh"

read_chart_identity() {
  local metadata="$1"
  local field="$2"
  local value

  # First match only. Not `| head -n1`: under pipefail, head exiting early can
  # kill sed and fail the line.
  value="$(sed -n "s/^${field}: //p" <<< "${metadata}")"
  printf '%s\n' "${value%%$'\n'*}"
}

main() {
  local chart_metadata
  local chart_name
  local chart_version

  registry_login "${WORK_DIRECTORY}" "${CHART_REF}"

  chart_metadata="$(helm show chart "${CHART_DIR}")"
  chart_name="$(read_chart_identity "${chart_metadata}" name)"
  chart_version="$(read_chart_identity "${chart_metadata}" version)"

  if helm show chart \
    "${CHART_REF}/${chart_name}" \
    --version "${chart_version}" >/dev/null 2>&1; then
    printf 'PASS | %s %s is already published\n' "${chart_name}" "${chart_version}"
    return
  fi

  helm dependency build "${CHART_DIR}" >/dev/null
  helm package "${CHART_DIR}" --destination "${WORK_DIRECTORY}" >/dev/null
  helm push "${WORK_DIRECTORY}/${chart_name}-${chart_version}.tgz" "${CHART_REF}"
  printf 'PASS | published %s/%s:%s\n' \
    "${CHART_REF}" "${chart_name}" "${chart_version}"
}

main "$@"
