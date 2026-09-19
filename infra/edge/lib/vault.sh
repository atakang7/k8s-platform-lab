#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
readonly ROOT
TEMPORARY_DIRECTORY="$(mktemp -d)"
readonly TEMPORARY_DIRECTORY

source "${ROOT}/infra/edge/lib/operator-state.sh"
source "${ROOT}/infra/edge/lib/vault-approle.sh"

trap 'rm -rf -- "${TEMPORARY_DIRECTORY}"' EXIT
chmod 0700 "${TEMPORARY_DIRECTORY}"
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

configure_vault_policies() {
  vault policy write dns-read "${ROOT}/infra/ansible/roles/vault/files/dns-read.hcl"
  vault policy write tls-read "${ROOT}/infra/ansible/roles/vault/files/tls-read.hcl"
}

configure_dns_host_approle() {
  vault write auth/approle/role/dns-host \
    token_policies=dns-read \
    token_ttl=1h \
    token_max_ttl=4h \
    token_num_uses=0 \
    secret_id_ttl=0 \
    secret_id_num_uses=0 >/dev/null
}

configure_dns_vso_approle() {
  vault write auth/approle/role/dns-vso \
    token_policies=dns-read \
    token_ttl=1h \
    token_max_ttl=4h \
    secret_id_ttl=0 \
    secret_id_num_uses=0 >/dev/null
}

configure_tls_vso_approle() {
  vault write auth/approle/role/tls-vso \
    token_policies=tls-read \
    token_ttl=1h \
    token_max_ttl=4h \
    secret_id_ttl=0 \
    secret_id_num_uses=0 >/dev/null
}

configure_approles() {
  configure_dns_host_approle
  configure_dns_vso_approle
  configure_tls_vso_approle
}

ensure_dns_secret() {
  if vault kv get secret/edge/dns/tsig >/dev/null 2>&1; then
    return
  fi

  jq -n \
    --arg secret "$(openssl rand -base64 32)" \
    '{key_name: "external-dns-stage3", secret: $secret}' \
    > "${TEMPORARY_DIRECTORY}/tsig.json"

  vault kv put secret/edge/dns/tsig "@${TEMPORARY_DIRECTORY}/tsig.json" >/dev/null
}

ensure_tls_secret() {
  if vault kv get secret/edge/tls/wildcard >/dev/null 2>&1; then
    return
  fi

  # The privileged source and unprivileged temporary destination are intentional.
  # shellcheck disable=SC2024
  sudo cat /etc/lab-ca/wildcard.crt > "${TEMPORARY_DIRECTORY}/wildcard.crt"
  # shellcheck disable=SC2024
  sudo cat /etc/lab-ca/wildcard.key > "${TEMPORARY_DIRECTORY}/wildcard.key"

  jq -n \
    --rawfile certificate "${TEMPORARY_DIRECTORY}/wildcard.crt" \
    --rawfile private_key "${TEMPORARY_DIRECTORY}/wildcard.key" \
    '{"tls.crt": $certificate, "tls.key": $private_key}' \
    > "${TEMPORARY_DIRECTORY}/tls.json"

  vault kv put secret/edge/tls/wildcard "@${TEMPORARY_DIRECTORY}/tls.json" >/dev/null
}

read_installed_host_identity() {
  : > "${TEMPORARY_DIRECTORY}/installed-role-id"
  : > "${TEMPORARY_DIRECTORY}/installed-secret-id"

  # shellcheck disable=SC2024
  sudo cat /etc/vault-agent/role-id \
    > "${TEMPORARY_DIRECTORY}/installed-role-id" 2>/dev/null || true
  # shellcheck disable=SC2024
  sudo cat /etc/vault-agent/secret-id \
    > "${TEMPORARY_DIRECTORY}/installed-secret-id" 2>/dev/null || true
}

rotate_host_identity() {
  vault write -field=secret_id -f \
    auth/approle/role/dns-host/secret-id \
    > "${TEMPORARY_DIRECTORY}/secret-id"

  sudo -n install -o root -g bind -m 0640 \
    "${TEMPORARY_DIRECTORY}/role-id" /etc/vault-agent/role-id
  sudo -n install -o root -g bind -m 0640 \
    "${TEMPORARY_DIRECTORY}/secret-id" /etc/vault-agent/secret-id

  sudo -n rm -f /run/lab-bind/tsig.key
  sudo -n systemctl enable vault-agent >/dev/null
  sudo -n systemctl restart vault-agent
}

reconcile_host_identity() {
  vault read -field=role_id \
    auth/approle/role/dns-host/role-id \
    > "${TEMPORARY_DIRECTORY}/role-id"

  read_installed_host_identity

  if ! cmp -s \
      "${TEMPORARY_DIRECTORY}/role-id" \
      "${TEMPORARY_DIRECTORY}/installed-role-id" ||
    ! vault_approle_secret_is_valid \
      dns-host "${TEMPORARY_DIRECTORY}/installed-secret-id"; then
    rotate_host_identity
    return
  fi

  sudo -n systemctl enable --now vault-agent >/dev/null
}

main() {
  require_vault_operator_token
  ensure_vault_foundation
  configure_vault_policies
  configure_approles
  ensure_dns_secret
  ensure_tls_secret
  reconcile_host_identity

  "${ROOT}/infra/edge/lib/with-kubeconfig.sh" \
    "${ROOT}/infra/edge/lib/bootstrap-vso-auth.sh"

  printf 'PASS | Vault policies, secrets, audit, and AppRole identities are reconciled\n'
}

main "$@"
