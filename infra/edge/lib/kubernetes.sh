#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
readonly ROOT
readonly EDGE_PLATFORM_DIRECTORY="${ROOT}/platform/edge"

source "${ROOT}/infra/edge/versions.env"

fail() {
  printf 'FAIL | %s\n' "$1" >&2
  exit 1
}

phase() {
  printf 'WAIT | %s\n' "$1"
}

pass() {
  printf 'PASS | %s\n' "$1"
}

install_release() {
  local release_name="$1"
  local namespace="$2"
  local chart_reference="$3"
  local chart_version="$4"
  local values_directory="$5"
  local values_file="${EDGE_PLATFORM_DIRECTORY}/${values_directory}/values.yaml"

  phase "reconciling ${release_name} ${chart_version} in ${namespace}"

  helm upgrade --install "${release_name}" "${chart_reference}" \
    --namespace "${namespace}" \
    --version "${chart_version}" \
    --values "${values_file}" \
    --wait \
    --rollback-on-failure \
    --timeout 5m \
    --history-max 5 \
    --hide-notes

  pass "${release_name} is ready"
}

configure_helm_repositories() {
  phase 'refreshing edge Helm repositories'

  helm repo add metallb https://metallb.github.io/metallb --force-update >/dev/null
  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx --force-update >/dev/null
  helm repo add external-dns https://kubernetes-sigs.github.io/external-dns/ --force-update >/dev/null
  helm repo add hashicorp https://helm.releases.hashicorp.com --force-update >/dev/null
  helm repo update metallb ingress-nginx external-dns hashicorp >/dev/null
}

install_vault_secrets_operator() {
  kubectl create namespace vault-secrets-operator --dry-run=client -o yaml |
    kubectl apply -f - >/dev/null

  install_release \
    vault-secrets-operator \
    vault-secrets-operator \
    hashicorp/vault-secrets-operator \
    "${VSO_CHART_VERSION}" \
    vault-secrets-operator
}

apply_vault_secret_resources() {
  local resource
  local resources_directory="${EDGE_PLATFORM_DIRECTORY}/vault-secrets-operator/resources"

  for resource in \
    external-dns-connection.yaml \
    external-dns-secret.yaml \
    ingress-connection.yaml \
    ingress-secret.yaml; do
    kubectl apply -f "${resources_directory}/${resource}" >/dev/null
  done
}

wait_for_vault_secrets() {
  phase 'waiting for Vault-managed DNS and TLS Secrets'

  kubectl -n external-dns wait \
    --for=condition=Ready vaultstaticsecret/rfc2136-tsig \
    --timeout=2m >/dev/null

  kubectl -n ingress-nginx wait \
    --for=condition=Ready vaultstaticsecret/lab-wildcard \
    --timeout=2m >/dev/null
}

reconcile_vault_secrets() {
  apply_vault_secret_resources
  wait_for_vault_secrets
  pass 'Vault-managed DNS and TLS Secrets are synced'
}

configure_worker_edge_labels() {
  phase 'reconciling worker edge labels'
  kubectl label node node-2 node-3 edge.lab.test/worker=true --overwrite >/dev/null
}

install_metallb() {
  kubectl create namespace metallb-system --dry-run=client -o yaml |
    kubectl label -f - \
      pod-security.kubernetes.io/enforce=privileged \
      pod-security.kubernetes.io/audit=privileged \
      pod-security.kubernetes.io/warn=privileged \
      --local -o yaml |
    kubectl apply -f - >/dev/null

  install_release \
    metallb \
    metallb-system \
    metallb/metallb \
    "${METALLB_CHART_VERSION}" \
    metallb

  kubectl apply \
    -f "${EDGE_PLATFORM_DIRECTORY}/metallb/resources/ip-address-pool.yaml" >/dev/null
}

install_ingress() {
  install_release \
    ingress-nginx \
    ingress-nginx \
    ingress-nginx/ingress-nginx \
    "${INGRESS_NGINX_CHART_VERSION}" \
    ingress-nginx
}

install_external_dns() {
  install_release \
    external-dns \
    external-dns \
    external-dns/external-dns \
    "${EXTERNAL_DNS_CHART_VERSION}" \
    external-dns
}

install_health_endpoint() {
  phase 'reconciling edge health endpoint'

  kubectl apply -f "${EDGE_PLATFORM_DIRECTORY}/health/resources.yaml" >/dev/null
  kubectl -n stage3-validation rollout status deployment/backend --timeout=3m >/dev/null

  pass 'edge health endpoint is ready'
}

remove_edge() {
  phase 'removing Kubernetes edge resources'

  helm --namespace external-dns uninstall external-dns --ignore-not-found
  helm --namespace ingress-nginx uninstall ingress-nginx --ignore-not-found
  helm --namespace metallb-system uninstall metallb --ignore-not-found

  kubectl -n external-dns delete vaultstaticsecret rfc2136-tsig \
    --ignore-not-found --wait=true
  kubectl -n ingress-nginx delete vaultstaticsecret lab-wildcard \
    --ignore-not-found --wait=true

  helm --namespace vault-secrets-operator uninstall vault-secrets-operator --ignore-not-found

  kubectl delete namespace \
    external-dns \
    ingress-nginx \
    metallb-system \
    vault-secrets-operator \
    stage3-validation \
    --ignore-not-found --wait=true
}

reconcile_vso_foundation() {
  configure_helm_repositories
  install_vault_secrets_operator
}

reconcile_full_edge() {
  reconcile_vso_foundation
  reconcile_vault_secrets
  configure_worker_edge_labels
  install_metallb
  install_ingress
  install_external_dns
  install_health_endpoint

  pass 'edge controllers are reconciled'
}

main() {
  local mode="${1:-full}"

  case "${mode}" in
    full)
      reconcile_full_edge
      ;;
    vso)
      reconcile_vso_foundation
      ;;
    down)
      remove_edge
      ;;
    *)
      fail "unknown mode: ${mode}; expected full, vso, or down"
      ;;
  esac
}

main "$@"
