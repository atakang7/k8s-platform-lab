#!/usr/bin/env bash
# Publishes a base chart version if the registry does not have it yet.
# Version bumps are enforced on pull requests by chart-testing
# (ct lint --check-version-increment).
set -euo pipefail

: "${CHART_DIR:?}" "${CHART_REF:?}"

work="$(mktemp -d)"
trap 'rm -rf -- "${work}"' EXIT
# shellcheck source=helm-registry-login.sh
source "$(dirname -- "$0")/helm-registry-login.sh"

name="$(helm show chart "${CHART_DIR}" | sed -n 's/^name: //p')"
version="$(helm show chart "${CHART_DIR}" | sed -n 's/^version: //p')"
if helm show chart "${CHART_REF}/${name}" --version "${version}" >/dev/null 2>&1; then
  echo "PASS | ${name} ${version} is already published"
  exit 0
fi
helm package "${CHART_DIR}" --destination "${work}" >/dev/null
helm push "${work}/${name}-${version}.tgz" "${CHART_REF}"
echo "PASS | published ${CHART_REF}/${name}:${version}"
