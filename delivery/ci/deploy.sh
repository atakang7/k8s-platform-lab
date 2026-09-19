#!/usr/bin/env bash
# Releases IMAGE_REF with the application chart. Image validation lives in the
# chart (app/chart/templates/deployment.yaml).
set -euo pipefail

: "${IMAGE_REF:?IMAGE_REF is required}"

release=sample-java-app
namespace=default
# Release history lives in ConfigMaps: the chart holds no secrets, and CD's
# Role deliberately has no access to Secrets in default.
export HELM_DRIVER=configmap

release_options=(--rollback-on-failure --wait --timeout 3m)
if ! helm status "${release}" --namespace "${namespace}" >/dev/null 2>&1; then
  # First Helm release over objects created before the chart existed: adopt
  # them. Without --rollback-on-failure, because rolling back a failed first
  # install uninstalls it, which would delete the adopted live objects.
  echo "==> No ${release} release yet; adopting existing objects"
  release_options=(--take-ownership --wait --timeout 3m)
fi

# --force-conflicts: Helm owns these objects. Server-side apply would otherwise
# refuse to change fields last written by another manager (the pre-Helm
# kubectl deploys, or a manual kubectl edit).
helm upgrade --install "${release}" app/chart \
  --namespace "${namespace}" \
  --force-conflicts \
  --set-string image.reference="${IMAGE_REF}" \
  "${release_options[@]}"
