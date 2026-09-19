#!/usr/bin/env bash
# Server-side dry-run of the service chart in this environment's namespace:
# schema validation plus the admission chain, before the image exists (the
# digest is a placeholder).
set -euo pipefail

: "${CHART:?}" "${RELEASE:?}" "${NAMESPACE:?}"

work="$(mktemp -d)"
trap 'rm -rf -- "${work}"' EXIT
# shellcheck source=helm-registry-login.sh
source "$(dirname -- "$0")/helm-registry-login.sh"

helm dependency build "${CHART}" >/dev/null
helm template "${RELEASE}" "${CHART}" --namespace "${NAMESPACE}" \
  --set-string image.digest="sha256:$(printf '0%.0s' {1..64})" > "${work}/release.yaml"
kubectl apply --dry-run=server -f "${work}/release.yaml"
