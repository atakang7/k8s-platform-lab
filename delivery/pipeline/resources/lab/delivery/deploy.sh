#!/usr/bin/env bash
# Releases the service chart with the given digest. The CD Pod's identity can
# only mint tokens for the namespace's `deployer`; the release runs with a
# 15-minute token for it. --rollback-on-failure returns every chart object to
# the last successful release when the new one does not become ready.
set -euo pipefail

: "${CHART:?}" "${RELEASE:?}" "${NAMESPACE:?}" "${IMAGE_DIGEST:?}"

work="$(mktemp -d)"
trap 'rm -rf -- "${work}"' EXIT
umask 077
# shellcheck source=helm-registry-login.sh
source "$(dirname -- "$0")/helm-registry-login.sh"
helm dependency build "${CHART}" >/dev/null

token="$(kubectl create token deployer --namespace "${NAMESPACE}" --duration=15m)"
cat > "${work}/kubeconfig" <<KUBECONFIG
apiVersion: v1
kind: Config
clusters: [{name: cluster, cluster: {server: "https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT}", certificate-authority: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt}}]
users: [{name: deployer, user: {token: "${token}"}}]
contexts: [{name: deployer, context: {cluster: cluster, user: deployer, namespace: "${NAMESPACE}"}}]
current-context: deployer
KUBECONFIG
unset token
export KUBECONFIG="${work}/kubeconfig"
export HELM_DRIVER=configmap   # release history in ConfigMaps: the deployer has no Secrets access

# --force-conflicts: the release owns its objects; manual kubectl edits are taken back.
helm upgrade --install "${RELEASE}" "${CHART}" --namespace "${NAMESPACE}" \
  --set-string image.digest="${IMAGE_DIGEST}" \
  --force-conflicts --rollback-on-failure --wait --timeout 5m --history-max 5
