#!/usr/bin/env bash
# Cluster side of the edge validation. Runs through the SSH tunnel
# (with-kubeconfig.sh).
#
#   check-cluster.sh           nodes, edge workloads, Vault-synced Secrets and
#                              one request through DNS, ingress and TLS
#   check-cluster.sh --smoke   nodes and edge workloads only
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT

# shellcheck source=../../infra/edge/config.env
source "${ROOT}/infra/edge/config.env"

fail() {
  printf 'FAIL | %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'PASS | %s\n' "$1"
}

check_ready_nodes() {
  local ready

  ready="$(kubectl get nodes \
    -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{" "}{end}')"

  if [[ "${ready}" != 'True True True ' ]]; then
    fail "the cluster should have three Ready nodes; Ready states: ${ready}"
  fi
}

check_edge_workloads() {
  local timeout="$1"

  kubectl -n metallb-system rollout status deployment/metallb-controller --timeout="${timeout}" >/dev/null
  kubectl -n metallb-system rollout status daemonset/metallb-speaker --timeout="${timeout}" >/dev/null
  kubectl -n vault-secrets-operator rollout status deployment/vault-secrets-operator-controller-manager --timeout="${timeout}" >/dev/null
  kubectl -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout="${timeout}" >/dev/null
  kubectl -n external-dns rollout status deployment/external-dns --timeout="${timeout}" >/dev/null
}

# The DNS key and the TLS certificate come from Vault through the Vault
# Secrets Operator; both must have arrived as Kubernetes Secrets.
check_vault_secrets() {
  kubectl -n external-dns get secret rfc2136-tsig >/dev/null ||
    fail 'the DNS TSIG Secret has not been synced from Vault'
  kubectl -n ingress-nginx get secret lab-wildcard >/dev/null ||
    fail 'the ingress TLS Secret has not been synced from Vault'

  pass 'the DNS and TLS Secrets arrived from Vault'
}

# One request proves the whole edge: ExternalDNS published the record, MetalLB
# answers on the ingress IP, and the ingress serves the lab CA's certificate.
check_ingress_dns_and_tls() {
  local host="stage3.${DNS_ZONE}"
  local address
  local response

  for _ in {1..90}; do
    address="$(dig +short "@${EDGE_HOST_IP}" "${host}" A)"
    if [[ "${address}" == *"${INGRESS_VIP}"* ]]; then
      response="$(curl --noproxy '*' --silent --show-error --fail --max-time 3 "https://${host}" 2>/dev/null || true)"
      if [[ "${response}" == stage3-edge-ok ]]; then
        pass 'Ingress DNS and trusted HTTPS work'
        return
      fi
    fi
    sleep 2
  done

  fail "https://${host} is not reachable through DNS and trusted HTTPS"
}

main() {
  case "${1:-}" in
    --smoke)
      [[ "$#" -eq 1 ]] || fail 'check-cluster --smoke does not accept extra arguments'
      check_ready_nodes
      check_edge_workloads 30s
      ;;
    '')
      check_ready_nodes
      check_edge_workloads 90s
      pass 'three nodes and the edge workloads are Ready'

      check_vault_secrets

      kubectl -n stage3-validation rollout status deployment/backend --timeout=180s >/dev/null
      check_ingress_dns_and_tls
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
}

main "$@"
