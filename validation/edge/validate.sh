#!/usr/bin/env bash
# Edge validation: the trust and network boundaries on the host, then the
# cluster side (check-cluster.sh) through the SSH tunnel.
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT
source "${ROOT}/infra/edge/lib/operator-state.sh"

pass() {
  printf 'PASS | %s\n' "$1"
}

fail() {
  printf 'FAIL | %s\n' "$1" >&2
  exit 1
}

require_commands() {
  local command_name

  for command_name in vault dig nsupdate curl jq timeout; do
    command -v "${command_name}" >/dev/null ||
      fail "missing command: ${command_name}"
  done
}

# The workers' edge addresses face the outside. Only the ingress IP may
# answer there; the nodes' own ports must be closed (roles/edge_firewall).
validate_private_ports() {
  local edge_ip
  local private_port

  for edge_ip in "${NODE2_EDGE_IP}" "${NODE3_EDGE_IP}"; do
    for private_port in 22 2379 6443 9100 10250; do
      if timeout 2 bash -c ": </dev/tcp/${edge_ip}/${private_port}" 2>/dev/null; then
        fail "port ${private_port} is open on worker edge address ${edge_ip}"
      fi
    done
  done

  pass 'worker edge addresses expose no node ports'
}

validate_vault() {
  local status

  status="$(vault status -format=json 2>/dev/null)" ||
    fail 'Vault is unavailable or sealed'
  jq -e '.initialized and (.sealed | not)' <<< "${status}" >/dev/null ||
    fail 'Vault is not initialized and unsealed'

  pass 'Vault is unsealed'
}

# BIND answers for the lab zone, and refuses a DNS update that is not signed
# with the TSIG key.
validate_bind() {
  local soa
  local unsigned_record="unsigned-$$.${DNS_ZONE}"

  soa="$(dig +short "@${EDGE_HOST_IP}" "${DNS_ZONE}" SOA)"
  [[ "${soa}" == *"ns.${DNS_ZONE}"* ]] ||
    fail 'BIND does not answer for the lab zone'

  printf 'server %s\nzone %s\nupdate add %s 60 A %s\nsend\n' \
    "${EDGE_HOST_IP}" "${DNS_ZONE}" "${unsigned_record}" "${METALLB_POOL_END}" |
    nsupdate >/dev/null 2>&1 || true

  [[ -z "$(dig +short "@${EDGE_HOST_IP}" "${unsigned_record}" A)" ]] ||
    fail 'BIND accepted an unsigned DNS update'

  pass 'BIND answers for the lab zone and rejects unsigned updates'
}

validate_cluster_edge() {
  "${ROOT}/infra/edge/lib/with-kubeconfig.sh" \
    "${ROOT}/validation/edge/check-cluster.sh"
}

main() {
  [[ "$#" -eq 0 ]] || fail 'edge validation does not accept arguments'

  cd "${ROOT}"
  require_commands
  validate_private_ports
  validate_vault
  validate_bind
  validate_cluster_edge

  pass 'edge validation complete'
}

main "$@"
