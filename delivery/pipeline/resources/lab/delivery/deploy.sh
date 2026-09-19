#!/usr/bin/env bash
# Releases one immutable service image. The CD Pod itself has no deploy rights:
# it mints a 15-minute token for the namespace-scoped deployer identity, builds
# a temporary kubeconfig around that token, and discards it after the release.
set -Eeuo pipefail

SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIRECTORY
WORK_DIRECTORY="$(mktemp -d)"
readonly WORK_DIRECTORY
readonly DEPLOYER_SERVICE_ACCOUNT=deployer
readonly DEPLOYER_TOKEN_DURATION=15m
trap 'rm -rf -- "${WORK_DIRECTORY}"' EXIT
umask 077

# shellcheck source=helm-registry-login.sh
source "${SCRIPT_DIRECTORY}/helm-registry-login.sh"

require_inputs() {
  : "${CHART:?CHART is required}"
  : "${RELEASE:?RELEASE is required}"
  : "${NAMESPACE:?NAMESPACE is required}"
  : "${IMAGE_REPOSITORY:?IMAGE_REPOSITORY is required}"
  : "${IMAGE_DIGEST:?IMAGE_DIGEST is required}"
  : "${COMMIT_SHA:?COMMIT_SHA is required}"
  : "${CHART_REF:?CHART_REF is required}"
  : "${REGISTRY_USERNAME:?REGISTRY_USERNAME is required}"
  : "${REGISTRY_PASSWORD:?REGISTRY_PASSWORD is required}"
  : "${KUBERNETES_SERVICE_HOST:?KUBERNETES_SERVICE_HOST is required}"
  : "${KUBERNETES_SERVICE_PORT:?KUBERNETES_SERVICE_PORT is required}"

  [[ "${IMAGE_DIGEST}" =~ ^sha256:[0-9a-f]{64}$ ]] || {
    printf 'FAIL | IMAGE_DIGEST must be sha256:<64 hex>\n' >&2
    exit 1
  }
  [[ "${COMMIT_SHA}" =~ ^[0-9a-f]{40}$ ]] || {
    printf 'FAIL | COMMIT_SHA must be a full lowercase Git SHA\n' >&2
    exit 1
  }
}

write_image_registry_auth() {
  local registry_host
  local encoded_auth

  registry_host="${IMAGE_REPOSITORY%%/*}"
  encoded_auth="$(printf '%s:%s' "${REGISTRY_USERNAME}" "${REGISTRY_PASSWORD}" |
    base64 | tr -d '\n')"

  jq -n \
    --arg host "${registry_host}" \
    --arg auth "${encoded_auth}" \
    '{auths: {($host): {auth: $auth}}}' \
    > "${WORK_DIRECTORY}/image-registry-auth.json"
}

verify_image_provenance() {
  local image_reference
  local image_revision

  image_reference="${IMAGE_REPOSITORY}@${IMAGE_DIGEST}"
  image_revision="$(skopeo inspect \
    --authfile "${WORK_DIRECTORY}/image-registry-auth.json" \
    --config "docker://${image_reference}" |
    jq -r '.config.Labels["org.opencontainers.image.revision"] // ""')"

  [[ "${image_revision}" == "${COMMIT_SHA}" ]] || {
    printf 'FAIL | image %s declares revision %s, expected %s\n' \
      "${image_reference}" "${image_revision:-<missing>}" "${COMMIT_SHA}" >&2
    exit 1
  }

  printf 'PASS | image provenance matches commit %s\n' "${COMMIT_SHA}"
}

prepare_chart() {
  helm_registry_login \
    "${WORK_DIRECTORY}" \
    "${CHART_REF}" \
    "${REGISTRY_USERNAME}" \
    "${REGISTRY_PASSWORD}"

  helm dependency build "${CHART}" >/dev/null
}

write_deployer_kubeconfig() {
  local deployer_token

  deployer_token="$(kubectl create token "${DEPLOYER_SERVICE_ACCOUNT}" \
    --namespace "${NAMESPACE}" \
    --duration="${DEPLOYER_TOKEN_DURATION}")"
  [[ -n "${deployer_token}" ]] || {
    printf 'FAIL | Kubernetes returned an empty deployer token\n' >&2
    return 1
  }

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

deploy_release() {
  # Helm release history is kept in ConfigMaps because deployer intentionally
  # has no Secrets access.
  export HELM_DRIVER=configmap

  # The release owns its objects. --force-conflicts takes ownership back from
  # manual server-side-apply edits; --rollback-on-failure restores the last
  # successful release if readiness fails.
  helm upgrade --install "${RELEASE}" "${CHART}" \
    --namespace "${NAMESPACE}" \
    --set-string image.digest="${IMAGE_DIGEST}" \
    --force-conflicts \
    --rollback-on-failure \
    --wait \
    --timeout 5m \
    --history-max 5
}

main() {
  require_inputs
  write_image_registry_auth
  verify_image_provenance
  prepare_chart
  write_deployer_kubeconfig
  deploy_release
}

main "$@"
