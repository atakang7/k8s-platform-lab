#!/usr/bin/env bash
# Installs, or removes, the Kubernetes side of the edge: Vault Secrets
# Operator, MetalLB, ingress-nginx, ExternalDNS and the edge health endpoint.
# Runs through the SSH tunnel (with-kubeconfig.sh).
#
#   kubernetes.sh full   everything (default)
#   kubernetes.sh vso    only Vault Secrets Operator, before Vault logins exist
#   kubernetes.sh down   remove everything
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
readonly ROOT
readonly EDGE_DIRECTORY="${ROOT}/platform/edge"

# shellcheck source=../versions.env
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

add_helm_repositories() {
  phase 'refreshing the edge Helm repositories'

  helm repo add metallb https://metallb.github.io/metallb --force-update >/dev/null
  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx --force-update >/dev/null
  helm repo add external-dns https://kubernetes-sigs.github.io/external-dns/ --force-update >/dev/null
  helm repo add hashicorp https://helm.releases.hashicorp.com --force-update >/dev/null
  helm repo update metallb ingress-nginx external-dns hashicorp >/dev/null
}

install_vault_secrets_operator() {
  phase "installing Vault Secrets Operator ${VSO_CHART_VERSION}"

  helm upgrade --install vault-secrets-operator hashicorp/vault-secrets-operator \
    --namespace vault-secrets-operator \
    --create-namespace \
    --version "${VSO_CHART_VERSION}" \
    --values "${EDGE_DIRECTORY}/vault-secrets-operator/values.yaml" \
    --wait \
    --rollback-on-failure \
    --timeout 5m \
    --history-max 5 \
    --hide-notes
}

sync_edge_secrets() {
  phase 'syncing the DNS and TLS Secrets from Vault'

  kubectl apply -f "${EDGE_DIRECTORY}/vault-secrets-operator/resources/external-dns-connection.yaml" >/dev/null
  kubectl apply -f "${EDGE_DIRECTORY}/vault-secrets-operator/resources/external-dns-secret.yaml" >/dev/null
  kubectl apply -f "${EDGE_DIRECTORY}/vault-secrets-operator/resources/ingress-connection.yaml" >/dev/null
  kubectl apply -f "${EDGE_DIRECTORY}/vault-secrets-operator/resources/ingress-secret.yaml" >/dev/null

  kubectl -n external-dns wait --for=condition=Ready --timeout=2m \
    vaultstaticsecret/rfc2136-tsig >/dev/null
  kubectl -n ingress-nginx wait --for=condition=Ready --timeout=2m \
    vaultstaticsecret/lab-wildcard >/dev/null
}

label_edge_workers() {
  phase 'labelling node-2 and node-3 as edge workers'

  kubectl label node node-2 node-3 edge.lab.test/worker=true --overwrite >/dev/null
}

install_metallb() {
  phase "installing MetalLB ${METALLB_CHART_VERSION}"

  # The MetalLB speaker needs host networking, which the privileged Pod
  # Security level allows.
  if ! kubectl get namespace metallb-system >/dev/null 2>&1; then
    kubectl create namespace metallb-system >/dev/null
  fi
  kubectl label namespace metallb-system \
    pod-security.kubernetes.io/enforce=privileged \
    pod-security.kubernetes.io/audit=privileged \
    pod-security.kubernetes.io/warn=privileged \
    --overwrite >/dev/null

  helm upgrade --install metallb metallb/metallb \
    --namespace metallb-system \
    --version "${METALLB_CHART_VERSION}" \
    --values "${EDGE_DIRECTORY}/metallb/values.yaml" \
    --wait \
    --rollback-on-failure \
    --timeout 5m \
    --history-max 5 \
    --hide-notes

  kubectl apply -f "${EDGE_DIRECTORY}/metallb/resources/ip-address-pool.yaml" >/dev/null
}

install_ingress() {
  phase "installing ingress-nginx ${INGRESS_NGINX_CHART_VERSION}"

  helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
    --namespace ingress-nginx \
    --version "${INGRESS_NGINX_CHART_VERSION}" \
    --values "${EDGE_DIRECTORY}/ingress-nginx/values.yaml" \
    --wait \
    --rollback-on-failure \
    --timeout 5m \
    --history-max 5 \
    --hide-notes
}

install_external_dns() {
  phase "installing ExternalDNS ${EXTERNAL_DNS_CHART_VERSION}"

  helm upgrade --install external-dns external-dns/external-dns \
    --namespace external-dns \
    --version "${EXTERNAL_DNS_CHART_VERSION}" \
    --values "${EDGE_DIRECTORY}/external-dns/values.yaml" \
    --wait \
    --rollback-on-failure \
    --timeout 5m \
    --history-max 5 \
    --hide-notes
}

install_health_endpoint() {
  phase 'installing the edge health endpoint'

  kubectl apply -f "${EDGE_DIRECTORY}/health/resources.yaml" >/dev/null
  kubectl -n stage3-validation rollout status deployment/backend --timeout=3m >/dev/null
}

remove_edge() {
  phase 'removing the Kubernetes edge'

  helm --namespace external-dns uninstall external-dns --ignore-not-found
  helm --namespace ingress-nginx uninstall ingress-nginx --ignore-not-found
  helm --namespace metallb-system uninstall metallb --ignore-not-found

  # Remove the synced Secrets while the operator still runs to clean them up.
  kubectl -n external-dns delete vaultstaticsecret rfc2136-tsig --ignore-not-found --wait=true
  kubectl -n ingress-nginx delete vaultstaticsecret lab-wildcard --ignore-not-found --wait=true

  helm --namespace vault-secrets-operator uninstall vault-secrets-operator --ignore-not-found

  kubectl delete namespace \
    external-dns \
    ingress-nginx \
    metallb-system \
    vault-secrets-operator \
    stage3-validation \
    --ignore-not-found --wait=true
}

main() {
  case "${1:-full}" in
    full)
      add_helm_repositories
      install_vault_secrets_operator
      sync_edge_secrets
      label_edge_workers
      install_metallb
      install_ingress
      install_external_dns
      install_health_endpoint
      pass 'the Kubernetes edge is installed'
      ;;
    vso)
      add_helm_repositories
      install_vault_secrets_operator
      pass 'Vault Secrets Operator is installed'
      ;;
    down)
      remove_edge
      pass 'the Kubernetes edge is removed'
      ;;
    *)
      fail "unknown mode: $1; expected full, vso or down"
      ;;
  esac
}

main "$@"
