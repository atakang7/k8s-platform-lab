#!/usr/bin/env bash
# Prepares Vault for the edge: the kv store, AppRole login, audit log, the DNS
# and TLS secrets with their read policies and AppRoles, and the login of the
# Vault Agent that renders the DNS key for BIND on this host.
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
readonly ROOT
TEMPORARY_DIRECTORY="$(mktemp -d)"
readonly TEMPORARY_DIRECTORY

# shellcheck source=operator-state.sh
source "${ROOT}/infra/edge/lib/operator-state.sh"
# shellcheck source=vault-approle.sh
source "${ROOT}/infra/edge/lib/vault-approle.sh"

trap 'rm -rf -- "${TEMPORARY_DIRECTORY}"' EXIT
chmod 0700 "${TEMPORARY_DIRECTORY}"
umask 077

phase() {
  printf 'WAIT | %s\n' "$1"
}

pass() {
  printf 'PASS | %s\n' "$1"
}

enable_vault_features() {
  local secret_engines
  local auth_methods
  local audit_devices

  phase 'enabling the kv store, AppRole login and the audit log'

  secret_engines="$(vault secrets list -format=json)"
  auth_methods="$(vault auth list -format=json)"
  audit_devices="$(vault audit list -format=json)"

  if ! jq -e 'has("secret/")' <<< "${secret_engines}" >/dev/null; then
    vault secrets enable -path=secret -version=2 kv
  fi

  if ! jq -e 'has("approle/")' <<< "${auth_methods}" >/dev/null; then
    vault auth enable approle
  fi

  if ! jq -e 'has("file/")' <<< "${audit_devices}" >/dev/null; then
    sudo install -o vault -g vault -m 0600 /dev/null /var/log/vault/audit.log
    vault audit enable file file_path=/var/log/vault/audit.log
  fi
}

write_policies() {
  phase 'writing the DNS and TLS read policies'

  vault policy write dns-read "${ROOT}/infra/ansible/roles/vault/files/dns-read.hcl" >/dev/null
  vault policy write tls-read "${ROOT}/infra/ansible/roles/vault/files/tls-read.hcl" >/dev/null
}

# Role IDs are pinned to the role names, so the VaultAuth files and the Vault
# Agent config can name them. A role ID is a name, not a secret.
configure_approles() {
  phase 'configuring the DNS and TLS AppRoles'

  # Vault Agent on this host logs in over 127.0.0.1.
  vault write auth/approle/role/dns-host \
    token_policies=dns-read \
    token_ttl=1h \
    token_max_ttl=4h \
    token_num_uses=0 \
    secret_id_ttl=0 \
    secret_id_num_uses=0 \
    secret_id_bound_cidrs=127.0.0.1/32 \
    token_bound_cidrs=127.0.0.1/32 >/dev/null
  vault write auth/approle/role/dns-host/role-id role_id=dns-host >/dev/null

  # Vault Secrets Operator in the cluster logs in from the worker edge IPs.
  vault write auth/approle/role/dns-vso \
    token_policies=dns-read \
    token_ttl=1h \
    token_max_ttl=4h \
    secret_id_ttl=0 \
    secret_id_num_uses=0 \
    secret_id_bound_cidrs="${CLUSTER_VAULT_CLIENTS}" \
    token_bound_cidrs="${CLUSTER_VAULT_CLIENTS}" >/dev/null
  vault write auth/approle/role/dns-vso/role-id role_id=dns-vso >/dev/null

  vault write auth/approle/role/tls-vso \
    token_policies=tls-read \
    token_ttl=1h \
    token_max_ttl=4h \
    secret_id_ttl=0 \
    secret_id_num_uses=0 \
    secret_id_bound_cidrs="${CLUSTER_VAULT_CLIENTS}" \
    token_bound_cidrs="${CLUSTER_VAULT_CLIENTS}" >/dev/null
  vault write auth/approle/role/tls-vso/role-id role_id=tls-vso >/dev/null
}

create_dns_key() {
  phase 'creating the DNS update key in Vault (first run only)'

  if vault kv get secret/edge/dns/tsig >/dev/null 2>&1; then
    return
  fi

  vault kv put secret/edge/dns/tsig \
    key_name=external-dns-stage3 \
    secret="$(openssl rand -base64 32)" >/dev/null
}

store_tls_certificate() {
  phase 'storing the wildcard TLS certificate in Vault (first run only)'

  if vault kv get secret/edge/tls/wildcard >/dev/null 2>&1; then
    return
  fi

  # The local CA writes these root-only; Vault reads them from a private copy.
  # shellcheck disable=SC2024
  sudo cat /etc/lab-ca/wildcard.crt > "${TEMPORARY_DIRECTORY}/wildcard.crt"
  # shellcheck disable=SC2024
  sudo cat /etc/lab-ca/wildcard.key > "${TEMPORARY_DIRECTORY}/wildcard.key"

  vault kv put secret/edge/tls/wildcard \
    tls.crt=@"${TEMPORARY_DIRECTORY}/wildcard.crt" \
    tls.key=@"${TEMPORARY_DIRECTORY}/wildcard.key" >/dev/null
}

# Vault Agent reads its login from /etc/vault-agent/role-id and secret-id.
# The stored secret ID is kept while Vault still knows it.
install_host_agent_login() {
  local installed_role_id=''
  local installed_secret_id=''
  local accessor=''

  phase 'installing the Vault Agent login on this host'

  if sudo -n test -s /etc/vault-agent/role-id; then
    installed_role_id="$(sudo -n cat /etc/vault-agent/role-id)"
  fi
  if sudo -n test -s /etc/vault-agent/secret-id; then
    installed_secret_id="$(sudo -n cat /etc/vault-agent/secret-id)"
  fi

  # Vault answers an unknown secret ID with an empty result, not an error.
  if [[ -n "${installed_secret_id}" ]]; then
    accessor="$(vault write -field=secret_id_accessor \
      auth/approle/role/dns-host/secret-id/lookup \
      secret_id="${installed_secret_id}" 2>/dev/null || true)"
  fi

  if [[ "${installed_role_id}" == dns-host && -n "${accessor}" ]]; then
    sudo -n systemctl enable --now vault-agent >/dev/null
    return
  fi

  destroy_approle_secret_ids dns-host
  printf 'dns-host' > "${TEMPORARY_DIRECTORY}/role-id"
  vault write -f -field=secret_id auth/approle/role/dns-host/secret-id > "${TEMPORARY_DIRECTORY}/secret-id"

  sudo -n install -o root -g bind -m 0640 "${TEMPORARY_DIRECTORY}/role-id" /etc/vault-agent/role-id
  sudo -n install -o root -g bind -m 0640 "${TEMPORARY_DIRECTORY}/secret-id" /etc/vault-agent/secret-id

  # Remove the old rendered key so up waits for one rendered with the new login.
  sudo -n rm -f /run/lab-bind/tsig.key
  sudo -n systemctl enable vault-agent >/dev/null
  sudo -n systemctl restart vault-agent
}

main() {
  require_vault_operator_token
  enable_vault_features
  write_policies
  configure_approles
  create_dns_key
  store_tls_certificate
  install_host_agent_login

  "${ROOT}/infra/edge/lib/with-kubeconfig.sh" "${ROOT}/infra/edge/lib/bootstrap-vso-auth.sh"

  pass 'Vault policies, secrets, audit log and AppRole logins are ready'
}

main "$@"
