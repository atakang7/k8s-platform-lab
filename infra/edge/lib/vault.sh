#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
export VAULT_ADDR=https://127.0.0.1:8200
if [[ -z "${VAULT_TOKEN:-}" ]]; then
  read -r -s -p 'Vault bootstrap token: ' VAULT_TOKEN
  echo
  export VAULT_TOKEN
fi
vault token lookup >/dev/null

temporary="$(mktemp -d)"
chmod 0700 "${temporary}"
trap 'rm -rf -- "${temporary}"' EXIT
umask 077

if ! vault secrets list -format=json | python3 -c 'import json,sys; sys.exit("secret/" not in json.load(sys.stdin))'; then
  vault secrets enable -path=secret -version=2 kv
fi
if ! vault auth list -format=json | python3 -c 'import json,sys; sys.exit("approle/" not in json.load(sys.stdin))'; then
  vault auth enable approle
fi
if ! vault audit list -format=json | python3 -c 'import json,sys; sys.exit("file/" not in json.load(sys.stdin))'; then
  sudo install -o vault -g vault -m 0600 /dev/null /var/log/vault/audit.log
  vault audit enable file file_path=/var/log/vault/audit.log
fi

vault policy write dns-read "${root}/infra/ansible/roles/vault/files/dns-read.hcl"
vault policy write tls-read "${root}/infra/ansible/roles/vault/files/tls-read.hcl"
vault write auth/approle/role/dns-host token_policies=dns-read token_ttl=1h token_max_ttl=4h token_num_uses=0 secret_id_ttl=0 secret_id_num_uses=0 >/dev/null
vault write auth/approle/role/dns-vso token_policies=dns-read token_ttl=1h token_max_ttl=4h secret_id_ttl=0 secret_id_num_uses=0 >/dev/null
vault write auth/approle/role/tls-vso token_policies=tls-read token_ttl=1h token_max_ttl=4h secret_id_ttl=0 secret_id_num_uses=0 >/dev/null

if ! vault kv get secret/edge/dns/tsig >/dev/null 2>&1; then
  python3 - "${temporary}/tsig.json" <<'PY'
import base64, json, os, sys
with open(sys.argv[1], 'w') as output:
    json.dump({'key_name': 'external-dns-stage3', 'secret': base64.b64encode(os.urandom(32)).decode()}, output)
PY
  vault kv put secret/edge/dns/tsig "@${temporary}/tsig.json" >/dev/null
fi
if ! vault kv get secret/edge/tls/wildcard >/dev/null 2>&1; then
  sudo cat /etc/lab-ca/wildcard.crt > "${temporary}/wildcard.crt"
  sudo cat /etc/lab-ca/wildcard.key > "${temporary}/wildcard.key"
  python3 - "${temporary}" <<'PY'
import json, pathlib, sys
directory = pathlib.Path(sys.argv[1])
with (directory / 'tls.json').open('w') as output:
    json.dump({'tls.crt': (directory / 'wildcard.crt').read_text(),
               'tls.key': (directory / 'wildcard.key').read_text()}, output)
PY
  vault kv put secret/edge/tls/wildcard "@${temporary}/tls.json" >/dev/null
fi

if ! sudo test -s /etc/vault-agent/secret-id; then
  vault read -field=role_id auth/approle/role/dns-host/role-id > "${temporary}/role-id"
  vault write -field=secret_id -f auth/approle/role/dns-host/secret-id > "${temporary}/secret-id"
  sudo install -o root -g bind -m 0640 "${temporary}/role-id" /etc/vault-agent/role-id
  sudo install -o root -g bind -m 0640 "${temporary}/secret-id" /etc/vault-agent/secret-id
fi
sudo systemctl enable --now vault-agent
"${root}/infra/edge/lib/with-kubeconfig.sh" "${root}/infra/edge/lib/bootstrap-vso-auth.sh"
echo 'PASS | Vault policies, audit, host agent, and VSO AppRole identities configured'
