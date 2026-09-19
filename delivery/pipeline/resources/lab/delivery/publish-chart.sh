#!/usr/bin/env bash
# Publishes a base chart version once. Released versions are immutable: if
# CHART_DIR's version is already published with different content, this fails.
set -euo pipefail

: "${CHART_DIR:?}" "${CHART_REF:?}"

work="$(mktemp -d)"
trap 'rm -rf -- "${work}"' EXIT
source "$(dirname -- "$0")/helm-registry-login.sh"

helm lint "${CHART_DIR}"
name="$(helm show chart "${CHART_DIR}" | sed -n 's/^name: //p')"
version="$(helm show chart "${CHART_DIR}" | sed -n 's/^version: //p')"

if helm pull "${CHART_REF}/${name}" --version "${version}" --untar --untardir "${work}/published" >/dev/null 2>&1; then
  # helm package rewrites Chart.yaml, so compare it by content, the rest byte for byte.
  if diff -r -x Chart.yaml "${CHART_DIR%/}" "${work}/published/${name}" >/dev/null &&
     diff <(helm show chart "${CHART_DIR}") <(helm show chart "${work}/published/${name}") >/dev/null; then
    echo "PASS | ${name} ${version} already published with identical content"
    exit 0
  fi
  echo "FAIL | ${name} ${version} is already published with different content; bump version in ${CHART_DIR%/}/Chart.yaml" >&2
  exit 1
fi

helm package "${CHART_DIR}" --destination "${work}" >/dev/null
helm push "${work}/${name}-${version}.tgz" "${CHART_REF}"
echo "PASS | published ${CHART_REF}/${name}:${version}"
