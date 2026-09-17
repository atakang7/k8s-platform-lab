#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${root}/infra/edge/config.env"
export VAULT_ADDR=https://127.0.0.1:8200

fail() { printf 'FAIL | %s\n' "$1" >&2; exit 1; }

[[ "$(vault status -format=json | python3 -c 'import json,sys; s=json.load(sys.stdin); print(s["initialized"] and not s["sealed"])')" == True ]] || fail 'Vault is sealed or unavailable; run make vault-unseal'
systemctl is-active --quiet named vault-agent || fail 'BIND or Vault Agent is stopped; run make edge-up'
[[ "$(dig +short "@${EDGE_HOST_IP}" "edge.${DNS_ZONE}" A | tail -1)" == "${INGRESS_VIP}" ]] || fail 'edge DNS does not resolve to the ingress VIP'

"${root}/infra/edge/lib/with-kubeconfig.sh" bash -c '
  set -Eeuo pipefail
  [[ "$(kubectl get nodes --no-headers | awk '\''$2 == "Ready" { n++ } END { print n+0 }'\'')" == 3 ]]
  kubectl -n metallb-system rollout status deployment/metallb-controller --timeout=30s >/dev/null
  kubectl -n metallb-system rollout status daemonset/metallb-speaker --timeout=30s >/dev/null
  kubectl -n vault-secrets-operator rollout status deployment/vault-secrets-operator-controller-manager --timeout=30s >/dev/null
  kubectl -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout=30s >/dev/null
  kubectl -n external-dns rollout status deployment/external-dns --timeout=30s >/dev/null
' || fail 'nodes or edge workloads are not Ready; inspect kubectl rollout status'

[[ "$(curl --noproxy '*' --silent --show-error --fail --max-time 5 "https://stage3.${DNS_ZONE}")" == stage3-edge-ok ]] || fail 'trusted HTTPS to the retained validation backend failed; run make edge-validate if the backend is absent'
echo 'PASS | Stage 3 nodes, host services, workloads, DNS, and trusted HTTPS are healthy'
