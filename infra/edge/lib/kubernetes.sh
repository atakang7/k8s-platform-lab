#!/usr/bin/env bash
set -Eeuo pipefail

readonly root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "${root}/infra/edge/versions.env"

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
  local name="$1" namespace="$2" chart="$3" version="$4" values="$5"

  phase "Reconciling ${name} ${version} in ${namespace}"
  helm upgrade --install "${name}" "${chart}" \
    --namespace "${namespace}" \
    --version "${version}" \
    --values "${root}/platform/edge/${values}/values.yaml" \
    --wait \
    --rollback-on-failure \
    --timeout 5m \
    --history-max 5 \
    --hide-notes
  pass "${name} is ready"
}

configure_helm_repositories() {
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

  for resource in \
    external-dns-connection.yaml \
    external-dns-secret.yaml \
    ingress-connection.yaml \
    ingress-secret.yaml; do
    kubectl apply -f "${root}/platform/edge/vault-secrets-operator/resources/${resource}" >/dev/null
  done
}

wait_for_vault_secrets() {
  phase 'Waiting for Vault-managed DNS and TLS Secrets'

  kubectl -n external-dns wait \
    --for=condition=Ready vaultstaticsecret/rfc2136-tsig \
    --timeout=2m >/dev/null
  kubectl -n ingress-nginx wait \
    --for=condition=Ready vaultstaticsecret/lab-wildcard \
    --timeout=2m >/dev/null
}

verify_dns_secret() (
  set -Eeuo pipefail

  local temporary
  temporary="$(mktemp -d)"
  trap 'rm -rf -- "${temporary}"' EXIT

  vault kv get -format=json secret/edge/dns/tsig > "${temporary}/vault.json"
  kubectl -n external-dns get secret rfc2136-tsig -o json > "${temporary}/kubernetes.json"

  jq -e --slurpfile installed "${temporary}/kubernetes.json" '
    .data.data as $wanted
    | ($installed[0].data.key_name | @base64d) == $wanted.key_name
      and ($installed[0].data.secret | @base64d) == $wanted.secret
  ' "${temporary}/vault.json" >/dev/null ||
    fail 'ExternalDNS TSIG Secret does not match Vault'
)

verify_tls_secret() (
  set -Eeuo pipefail

  local temporary
  temporary="$(mktemp -d)"
  trap 'rm -rf -- "${temporary}"' EXIT

  vault kv get -format=json secret/edge/tls/wildcard > "${temporary}/vault.json"
  kubectl -n ingress-nginx get secret lab-wildcard -o json > "${temporary}/kubernetes.json"

  jq -e --slurpfile installed "${temporary}/kubernetes.json" '
    .data.data as $wanted
    | ($installed[0].data["tls.crt"] | @base64d) == $wanted["tls.crt"]
      and ($installed[0].data["tls.key"] | @base64d) == $wanted["tls.key"]
  ' "${temporary}/vault.json" >/dev/null ||
    fail 'Ingress TLS Secret does not match Vault'
)

reconcile_vault_secrets() {
  apply_vault_secret_resources
  wait_for_vault_secrets
  verify_dns_secret
  verify_tls_secret
  pass 'Vault-managed DNS and TLS Secrets match Vault'
}

configure_worker_edge_labels() {
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
    -f "${root}/platform/edge/metallb/resources/ip-address-pool.yaml" >/dev/null
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
  kubectl apply -f "${root}/platform/edge/health/resources.yaml" >/dev/null
  kubectl -n stage3-validation rollout status deployment/backend --timeout=3m >/dev/null
  pass 'edge health endpoint is ready'
}

remove_edge() {
  local release name namespace

  for release in \
    "external-dns external-dns" \
    "ingress-nginx ingress-nginx" \
    "metallb metallb-system"; do
    read -r name namespace <<< "${release}"
    helm --namespace "${namespace}" uninstall "${name}" --ignore-not-found
  done

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

reconcile_edge() {
  configure_helm_repositories
  install_vault_secrets_operator

  if [[ "$1" == vso ]]; then
    return
  fi

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
    full|vso)
      reconcile_edge "${mode}"
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
