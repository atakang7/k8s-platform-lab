#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT
source "${ROOT}/infra/edge/lib/operator-state.sh"
source "${ROOT}/infra/edge/lib/sudo.sh"

pass() {
  printf 'PASS | %s\n' "$1"
}

fail() {
  printf 'FAIL | %s\n' "$1" >&2
  exit 1
}

require_commands() {
  local command_name

  for command_name in \
    vagrant VBoxManage vault dig nsupdate curl jq ssh ip timeout resolvectl; do
    command -v "${command_name}" >/dev/null ||
      fail "missing command: ${command_name}"
  done

  require_sudo 'edge validation' ||
    fail 'sudo authentication is required for edge validation'
}

validate_host_network() (
  set -Eeuo pipefail

  local host_addresses
  local ssh_config
  local node
  local addresses
  local edge_ip
  local private_port

  host_addresses="$(ip -o -4 addr show)"
  [[ "${host_addresses}" == *" ${EDGE_HOST_IP}/24 "* ]] ||
    fail 'host edge IP is missing'

  ssh_config="$(mktemp)"
  trap 'rm -f -- "${ssh_config}"' EXIT

  vagrant ssh-config |
    sed -n '/^Host /,$p' > "${ssh_config}"
  [[ -s "${ssh_config}" ]] ||
    fail 'Vagrant SSH configuration is empty'

  for node in 1 2 3; do
    addresses="$(ssh -F "${ssh_config}" "node-${node}" 'ip -o -4 addr show')" ||
      fail "node-${node} SSH is unavailable"

    grep -q "10.50.0.$((node + 9))/24" <<< "${addresses}" ||
      fail "node-${node} lost its private address"

    if [[ "${node}" == 1 ]]; then
      ! grep -q '192\.168\.56\.' <<< "${addresses}" ||
        fail 'control plane has an edge interface'
    else
      grep -q "192.168.56.$((node + 9))/24" <<< "${addresses}" ||
        fail "node-${node} lacks its edge address"
    fi
  done

  for edge_ip in "${NODE2_EDGE_IP}" "${NODE3_EDGE_IP}"; do
    for private_port in 6443 2379; do
      if timeout 2 bash -c ": </dev/tcp/${edge_ip}/${private_port}" 2>/dev/null; then
        fail "private control-plane port ${private_port} is exposed on ${edge_ip}"
      fi
    done
  done

  ! grep -Eq \
    '(^|[[:space:]])[^#[:space:]]*\.lab\.test([[:space:]]|$)' \
    /etc/hosts ||
    fail '/etc/hosts contains a lab.test workaround'

  pass 'host and VM network boundaries are intact'
)

validate_vault() {
  local status_json
  local dns_policy
  local tls_policy

  status_json="$(vault status -format=json 2>/dev/null)" ||
    fail 'Vault is unavailable or sealed'

  jq -e '.initialized and (.sealed | not)' <<< "${status_json}" >/dev/null ||
    fail 'Vault is not initialized and unsealed'

  sudo -n grep -q 'storage "raft"' /etc/vault/vault.hcl ||
    fail 'Vault is not configured for Raft'
  sudo -n grep -q 'tls_cert_file' /etc/vault/vault.hcl ||
    fail 'Vault TLS is not configured'
  sudo -n test -s /var/log/vault/audit.log ||
    fail 'Vault audit file is unavailable'

  if curl \
    --noproxy '*' \
    --silent \
    --fail \
    --max-time 3 \
    "http://${EDGE_HOST_IP}:8200/v1/sys/health" >/dev/null 2>&1; then
    fail 'Vault accepted plaintext HTTP on the edge'
  fi

  require_vault_operator_token

  # Read into a variable first: `vault … | grep -q` under pipefail fails when
  # grep exits early and vault gets SIGPIPE, which reported a present policy
  # as absent.
  dns_policy="$(vault policy read dns-read)"
  [[ "${dns_policy}" == *secret/data/edge/dns/tsig* ]] ||
    fail 'DNS read policy is absent'

  tls_policy="$(vault policy read tls-read)"
  [[ "${tls_policy}" == *secret/data/edge/tls/wildcard* ]] ||
    fail 'TLS read policy is absent'

  vault audit list -format=json |
    jq -e 'has("file/")' >/dev/null ||
    fail 'Vault file audit device is absent'

  pass 'Vault storage, TLS, audit, and scoped policies are configured'
}

validate_bind() {
  local unauthorized_record
  local soa

  systemctl is-active --quiet named ||
    fail 'BIND is not running'

  soa="$(dig +short "@${EDGE_HOST_IP}" "${DNS_ZONE}" SOA)"
  [[ "${soa}" == *"ns.${DNS_ZONE}"* ]] ||
    fail 'authoritative zone is unavailable'

  [[ -z "$(dig +short "@${EDGE_HOST_IP}" example.com A)" ]] ||
    fail 'BIND performed recursion for an unrelated name'

  unauthorized_record="unauthorized-$$.${DNS_ZONE}"
  printf 'server %s\nzone %s\nupdate add %s 60 A %s\nsend\n' \
    "${EDGE_HOST_IP}" \
    "${DNS_ZONE}" \
    "${unauthorized_record}" \
    "${METALLB_POOL_END}" |
    nsupdate >/dev/null 2>&1 || true

  [[ -z "$(dig +short "@${EDGE_HOST_IP}" "${unauthorized_record}" A)" ]] ||
    fail 'unauthenticated DNS update succeeded'

  pass 'BIND is authoritative, non-recursive, and rejects unsigned updates'
}

validate_cluster_edge() {
  local resolved

  "${ROOT}/infra/edge/lib/with-kubeconfig.sh" \
    "${ROOT}/validation/edge/check-cluster.sh"

  resolved="$(resolvectl query "edge.${DNS_ZONE}")"
  [[ "${resolved}" == *"${INGRESS_VIP}"* ]] ||
    fail 'host split DNS did not resolve the ingress Service record'

  [[ "$(dig +short "@${EDGE_HOST_IP}" "edge.${DNS_ZONE}" A | tail -1)" \
    == "${INGRESS_VIP}" ]] ||
    fail 'ingress Service DNS record does not match the VIP'

  pass 'cluster edge integration is healthy'
}

main() {
  [[ "$#" -eq 0 ]] || fail 'edge validation does not accept arguments'

  cd "${ROOT}"
  require_commands
  validate_host_network
  validate_vault
  validate_bind
  validate_cluster_edge

  pass 'edge validation complete'
}

main "$@"
