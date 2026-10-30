#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT
source "${ROOT}/infra/edge/config.env"

export VAULT_ADDR=https://127.0.0.1:8200

fail() {
  printf 'FAIL | %s\n' "$1" >&2
  exit 1
}

check_vault() {
  vault status -format=json |
    jq -e '.initialized and (.sealed | not)' >/dev/null ||
    fail 'Vault is sealed or unavailable; run make edge-up'
}

check_host_services() {
  systemctl is-active --quiet named vault-agent ||
    fail 'BIND or Vault Agent is stopped; run make edge-up'
}

check_edge_dns() {
  local resolved

  resolved="$(dig +short "@${EDGE_HOST_IP}" "edge.${DNS_ZONE}" A | tail -1)"
  [[ "${resolved}" == "${INGRESS_VIP}" ]] ||
    fail "edge DNS resolved to ${resolved:-<empty>}, expected ${INGRESS_VIP}"
}

check_cluster_workloads() {
  "${ROOT}/infra/edge/lib/with-kubeconfig.sh" \
    "${ROOT}/validation/edge/check-cluster.sh" --smoke ||
    fail 'nodes or edge workloads are not Ready; inspect kubectl rollout status'
}

check_https() {
  local response

  response="$(curl \
    --noproxy '*' \
    --silent \
    --show-error \
    --fail \
    --max-time 5 \
    "https://stage3.${DNS_ZONE}")" ||
    fail 'trusted HTTPS to the retained validation backend failed; run make edge-validate if the backend is absent'

  [[ "${response}" == stage3-edge-ok ]] ||
    fail "retained validation backend returned unexpected response: ${response}"
}

main() {
  [[ "$#" -eq 0 ]] || fail 'edge smoke does not accept arguments'

  check_vault
  check_host_services
  check_edge_dns
  check_cluster_workloads
  check_https

  printf 'PASS | edge host services, workloads, DNS, and trusted HTTPS are healthy\n'
}

main "$@"
