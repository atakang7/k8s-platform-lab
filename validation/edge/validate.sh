#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root}"
export VAULT_ADDR=https://127.0.0.1:8200
pass() { printf 'PASS | %s\n' "$1"; }
fail() { printf 'FAIL | %s\n' "$1" >&2; exit 1; }

for command in vagrant VBoxManage vault dig nsupdate curl jq; do
  command -v "${command}" >/dev/null || fail "missing command: ${command}"
done
sudo -v
[[ "$(ip -o -4 addr show | awk '$4 == "192.168.56.1/24" { print $4; exit }')" == 192.168.56.1/24 ]] || fail 'host edge IP is missing'
pass 'host has the edge network'
ssh_config="$(mktemp)"
trap 'rm -f -- "${ssh_config}"' EXIT
vagrant ssh-config | sed -n '/^Host /,$p' > "${ssh_config}"
for node in 1 2 3; do
  addresses="$(ssh -F "${ssh_config}" "node-${node}" 'ip -o -4 addr show')" || fail "node-${node} SSH is unavailable"
  grep -q "10.50.0.$((node + 9))/24" <<< "${addresses}" || fail "node-${node} lost its private address"
  if [[ "${node}" == 1 ]]; then
    ! grep -q '192.168.56.' <<< "${addresses}" || fail 'control plane has an edge interface'
  else
    grep -q "192.168.56.$((node + 9))/24" <<< "${addresses}" || fail "node-${node} lacks its edge address"
  fi
done
pass 'private cluster and worker-only edge NICs are intact'
for edge_ip in 192.168.56.11 192.168.56.12; do
  for private_port in 6443 2379; do
    if timeout 2 bash -c ": </dev/tcp/${edge_ip}/${private_port}" 2>/dev/null; then
      fail "private control-plane port ${private_port} is exposed on ${edge_ip}"
    fi
  done
done
pass 'Kubernetes API and etcd ports are not exposed on worker edge NICs'
! grep -Eq '(^|[[:space:]])[^#[:space:]]*\.lab\.test([[:space:]]|$)' /etc/hosts || fail '/etc/hosts contains a lab.test workaround'
pass 'host DNS does not rely on /etc/hosts'

status_code=0
status_json="$(vault status -format=json 2>/dev/null)" || status_code=$?
[[ "${status_code}" == 0 ]] || fail 'Vault is unavailable or sealed'
jq -e '.initialized and (.sealed | not)' <<< "${status_json}" >/dev/null || fail 'Vault is not initialized and unsealed'
sudo grep -q 'storage "raft"' /etc/vault/vault.hcl || fail 'Vault is not configured for Raft'
sudo grep -q 'tls_cert_file' /etc/vault/vault.hcl || fail 'Vault TLS is not configured'
sudo test -s /var/log/vault/audit.log || fail 'Vault audit file is unavailable'
pass 'Vault is initialized, unsealed, persistent, TLS enabled, and auditing'
if curl --noproxy '*' --silent --fail --max-time 3 http://192.168.56.1:8200/v1/sys/health >/dev/null 2>&1; then
  fail 'Vault accepted plaintext HTTP on the edge'
fi
pass 'Vault edge listener requires TLS'
if [[ -n "${VAULT_TOKEN:-}" ]]; then
  vault policy read dns-read | grep -q 'secret/data/edge/dns/tsig' || fail 'DNS read policy is absent'
  vault policy read tls-read | grep -q 'secret/data/edge/tls/wildcard' || fail 'TLS read policy is absent'
  vault audit list -format=json | jq -e 'has("file/")' >/dev/null || fail 'file audit device is absent'
  pass 'narrow Vault policies and file audit device exist'
else
  echo 'SKIP | Vault policy API checks require an operator token in VAULT_TOKEN'
fi

systemctl is-active --quiet named || fail 'BIND is not running'
dig +short @192.168.56.1 lab.test SOA | grep -q 'ns.lab.test' || fail 'authoritative zone is unavailable'
[[ "$(dig +short @192.168.56.1 example.com A)" == '' ]] || fail 'BIND performed recursion for an unrelated name'
unauthorized="unauthorized-$$.lab.test"
printf 'server 192.168.56.1\nzone lab.test\nupdate add %s 60 A 192.168.56.210\nsend\n' "${unauthorized}" | nsupdate >/dev/null 2>&1 || :
[[ -z "$(dig +short @192.168.56.1 "${unauthorized}" A)" ]] || fail 'unauthenticated DNS update succeeded'
pass 'BIND is authoritative, non-recursive, and rejects unsigned updates'

"${root}/infra/edge/lib/with-kubeconfig.sh" "${root}/validation/edge/check-cluster.sh"

resolvectl query edge.lab.test | grep -q '192.168.56.200' || fail 'host split DNS did not resolve the Service record'
[[ "$(dig +short @192.168.56.1 edge.lab.test A | tail -1)" == 192.168.56.200 ]] || fail 'Service record does not match ingress VIP'
pass 'ExternalDNS created the Service record and host split DNS resolves it'
echo 'PASS | Stage 3 edge validation complete'
