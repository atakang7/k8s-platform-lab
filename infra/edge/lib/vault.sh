#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "${root}/infra/edge/lib/operator-state.sh"
source "${root}/infra/edge/lib/vault-approle.sh"

temporary="$(mktemp -d)"
trap 'rm -rf -- "${temporary}"' EXIT
chmod 0700 "${temporary}"
umask 077

ensure_vault_foundation() {
  if ! vault secrets list -format=json | jq -e 'has("secret/")' >/dev/null; then
    vault secrets enable -path=secret -version=2 kv
  fi
  if ! vault auth list -format=json | jq -e 'has("approle/")' >/dev/null; then
    vault auth enable approle
  fi
  if ! vault audit list -format=json | jq -e 'has("file/")' >/dev/null; then
    sudo install -o vault -g vault -m 0600 /dev/null /var/log/vault/audit.log
    vault audit enable file file_path=/var/log/vault/audit.log
  fi
}

configure_approles() {
  vault policy write dns-read "${root}/infra/ansible/roles/vault/files/dns-read.hcl"
  vault policy write tls-read "${root}/infra/ansible/roles/vault/files/tls-read.hcl"
  vault write auth/approle/role/dns-host token_policies=dns-read token_ttl=1h token_max_ttl=4h token_num_uses=0 secret_id_ttl=0 secret_id_num_uses=0 >/dev/null
  vault write auth/approle/role/dns-vso token_policies=dns-read token_ttl=1h token_max_ttl=4h secret_id_ttl=0 secret_id_num_uses=0 >/dev/null
  vault write auth/approle/role/tls-vso token_policies=tls-read token_ttl=1h token_max_ttl=4h secret_id_ttl=0 secret_id_num_uses=0 >/dev/null
}

ensure_dns_secret() {
  vault kv get secret/edge/dns/tsig >/dev/null 2>&1 && return
  jq -n --arg secret "$(openssl rand -base64 32)" \
    '{key_name: "external-dns-stage3", secret: $secret}' > "${temporary}/tsig.json"
  vault kv put secret/edge/dns/tsig "@${temporary}/tsig.json" >/dev/null
}

ensure_tls_secret() {
  vault kv get secret/edge/tls/wildcard >/dev/null 2>&1 && return
  # The privileged read and unprivileged destination are intentional.
  # shellcheck disable=SC2024
  sudo cat /etc/lab-ca/wildcard.crt > "${temporary}/wildcard.crt"
  # shellcheck disable=SC2024
  sudo cat /etc/lab-ca/wildcard.key > "${temporary}/wildcard.key"
  jq -n \
    --rawfile certificate "${temporary}/wildcard.crt" \
    --rawfile private_key "${temporary}/wildcard.key" \
    '{"tls.crt": $certificate, "tls.key": $private_key}' > "${temporary}/tls.json"
  vault kv put secret/edge/tls/wildcard "@${temporary}/tls.json" >/dev/null
}

read_installed_identity() {
  # shellcheck disable=SC2024
  sudo cat /etc/vault-agent/role-id > "${temporary}/installed-role-id" 2>/dev/null || true
  # shellcheck disable=SC2024
  sudo cat /etc/vault-agent/secret-id > "${temporary}/installed-secret-id" 2>/dev/null || true
}

rotate_host_identity() {
  vault write -field=secret_id -f auth/approle/role/dns-host/secret-id > "${temporary}/secret-id"
  sudo -n install -o root -g bind -m 0640 "${temporary}/role-id" /etc/vault-agent/role-id
  sudo -n install -o root -g bind -m 0640 "${temporary}/secret-id" /etc/vault-agent/secret-id
  sudo -n rm -f /run/lab-bind/tsig.key
  sudo -n systemctl enable vault-agent >/dev/null
  sudo -n systemctl restart vault-agent
}

reconcile_host_identity() {
  : > "${temporary}/installed-role-id"
  : > "${temporary}/installed-secret-id"
  vault read -field=role_id auth/approle/role/dns-host/role-id > "${temporary}/role-id"
  read_installed_identity
  if ! cmp -s "${temporary}/role-id" "${temporary}/installed-role-id" ||
     ! vault_approle_secret_is_valid dns-host "${temporary}/installed-secret-id"; then
    rotate_host_identity
    return
  fi
  sudo -n systemctl enable --now vault-agent >/dev/null
}

main() {
  require_vault_operator_token
  ensure_vault_foundation
  configure_approles
  ensure_dns_secret
  ensure_tls_secret
  reconcile_host_identity
  "${root}/infra/edge/lib/with-kubeconfig.sh" "${root}/infra/edge/lib/bootstrap-vso-auth.sh"
  echo 'PASS | Vault policies, secrets, audit, and AppRole identities are reconciled'
}

main "$@"
