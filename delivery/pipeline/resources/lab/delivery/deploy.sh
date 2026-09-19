#!/usr/bin/env bash
# Releases one recorded release (chart CHART_VERSION, image IMAGE_DIGEST) into
# one environment, with that environment's values (values-<ENVIRONMENT>.yaml
# when the chart has one). A release already running both is left alone. The CD Pod itself has no deploy rights: it mints a
# 15-minute token for the namespace-scoped deployer identity, builds a
# temporary kubeconfig around that token, and discards it after the release.
set -Eeuo pipefail

SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIRECTORY
WORK_DIRECTORY="$(mktemp -d)"
readonly WORK_DIRECTORY
readonly DEPLOYER_SERVICE_ACCOUNT=deployer
readonly DEPLOYER_TOKEN_DURATION=15m
trap 'rm -rf -- "${WORK_DIRECTORY}"' EXIT
umask 077

# shellcheck source=registry.sh
source "${SCRIPT_DIRECTORY}/registry.sh"

prepare_chart() {
  registry_login "${WORK_DIRECTORY}" "${CHART_REF}"
  release_chart "${WORK_DIRECTORY}"
}

write_deployer_kubeconfig() {
  local deployer_token

  deployer_token="$(kubectl create token "${DEPLOYER_SERVICE_ACCOUNT}" \
    --namespace "${NAMESPACE}" \
    --duration="${DEPLOYER_TOKEN_DURATION}")"

  cat > "${WORK_DIRECTORY}/kubeconfig" <<KUBECONFIG
apiVersion: v1
kind: Config
clusters:
  - name: cluster
    cluster:
      server: "https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT}"
      certificate-authority: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
users:
  - name: deployer
    user:
      token: "${deployer_token}"
contexts:
  - name: deployer
    context:
      cluster: cluster
      user: deployer
      namespace: "${NAMESPACE}"
current-context: deployer
KUBECONFIG

  unset deployer_token
  export KUBECONFIG="${WORK_DIRECTORY}/kubeconfig"
}

release_is_current() {
  local deployed_chart
  local deployed_digest

  deployed_chart="$(helm list --deployed --filter "^${RELEASE}\$" --output json |
    jq -r '.[0].chart // ""')"
  [[ "${deployed_chart}" == "${RELEASE}-${CHART_VERSION}" ]] || return 1
  deployed_digest="$(helm get values "${RELEASE}" --output json |
    jq -r '.image.digest // ""')"
  [[ "${deployed_digest}" == "${IMAGE_DIGEST}" ]]
}

deploy_release() {
  local values=()

  if [[ -f "${CHART}/values-${ENVIRONMENT}.yaml" ]]; then
    values=(--values "${CHART}/values-${ENVIRONMENT}.yaml")
  fi

  # The release owns its objects. --force-conflicts takes ownership back from
  # manual server-side-apply edits; --rollback-on-failure restores the last
  # successful release if readiness fails.
  helm upgrade --install "${RELEASE}" "${CHART}" \
    --namespace "${NAMESPACE}" \
    "${values[@]}" \
    --set-string image.digest="${IMAGE_DIGEST}" \
    --force-conflicts \
    --rollback-on-failure \
    --wait \
    --timeout 5m \
    --history-max 5
}

main() {
  prepare_chart
  write_deployer_kubeconfig

  # Helm release history is kept in ConfigMaps because deployer intentionally
  # has no Secrets access.
  export HELM_DRIVER=configmap

  if release_is_current; then
    printf 'PASS | %s already runs %s in %s\n' "${RELEASE}" "${CHART_VERSION}" "${ENVIRONMENT}"
    return
  fi

  printf 'WAIT | releasing %s %s to %s\n' "${RELEASE}" "${CHART_VERSION}" "${ENVIRONMENT}"
  deploy_release
}

main "$@"
