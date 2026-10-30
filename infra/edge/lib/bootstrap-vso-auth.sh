#!/usr/bin/env bash
# Gives the ExternalDNS and ingress namespaces what Vault Secrets Operator
# needs to log in to Vault: the Vault CA certificate and an AppRole secret ID.
# The VaultConnection and VaultAuth objects that use them are static files in
# platform/edge/vault-secrets-operator/resources/, applied by kubernetes.sh.
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
readonly ROOT

# shellcheck source=vault-approle.sh
source "${ROOT}/infra/edge/lib/vault-approle.sh"

phase() {
  printf 'WAIT | %s\n' "$1"
}

prepare_external_dns_namespace() {
  phase 'giving external-dns its Vault login'

  if ! kubectl get namespace external-dns >/dev/null 2>&1; then
    kubectl create namespace external-dns >/dev/null
  fi

  kubectl -n external-dns delete secret vault-ca --ignore-not-found >/dev/null
  kubectl -n external-dns create secret generic vault-ca \
    --from-file=ca.crt=/usr/local/share/ca-certificates/lab.crt >/dev/null

  install_approle_secret_id external-dns dns-vso approle-id
}

prepare_ingress_namespace() {
  phase 'giving ingress-nginx its Vault login'

  if ! kubectl get namespace ingress-nginx >/dev/null 2>&1; then
    kubectl create namespace ingress-nginx >/dev/null
  fi

  kubectl -n ingress-nginx delete secret vault-ca --ignore-not-found >/dev/null
  kubectl -n ingress-nginx create secret generic vault-ca \
    --from-file=ca.crt=/usr/local/share/ca-certificates/lab.crt >/dev/null

  install_approle_secret_id ingress-nginx tls-vso approle-id
}

main() {
  prepare_external_dns_namespace
  prepare_ingress_namespace
}

main "$@"
