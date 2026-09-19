#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${root}/infra/edge/config.env"
export VAULT_ADDR=https://127.0.0.1:8200

fail() { printf 'FAIL | %s\n' "$1" >&2; exit 1; }

vault status -format=json | jq -e '.initialized and (.sealed | not)' >/dev/null ||
  fail 'Vault is sealed or unavailable; run make edge-up'
systemctl is-active --quiet named vault-agent || fail 'BIND or Vault Agent is stopped; run make edge-up'
[[ "$(dig +short "@${EDGE_HOST_IP}" "edge.${DNS_ZONE}" A | tail -1)" == "${INGRESS_VIP}" ]] || fail 'edge DNS does not resolve to the ingress VIP'

"${root}/infra/edge/lib/with-kubeconfig.sh" \
  "${root}/validation/edge/check-cluster.sh" --smoke ||
  fail 'nodes or edge workloads are not Ready; inspect kubectl rollout status'

[[ "$(curl --noproxy '*' --silent --show-error --fail --max-time 5 "https://stage3.${DNS_ZONE}")" == stage3-edge-ok ]] || fail 'trusted HTTPS to the retained validation backend failed; run make edge-validate if the backend is absent'
echo 'PASS | Stage 3 nodes, host services, workloads, DNS, and trusted HTTPS are healthy'
