#!/usr/bin/env bash

operator_state_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "${operator_state_root}/infra/edge/config.env"
export VAULT_ADDR=https://127.0.0.1:8200

require_vault_operator_token() {
  if [[ -n "${VAULT_TOKEN:-}" ]] && vault token lookup >/dev/null 2>&1; then
    export VAULT_TOKEN
    return
  fi
  [[ -s "${VAULT_INIT_OUTPUT}" ]] || {
    printf 'FAIL | Vault operator state is missing: %s\n' "${VAULT_INIT_OUTPUT}" >&2
    return 1
  }
  VAULT_TOKEN="$(jq -er '.root_token' "${VAULT_INIT_OUTPUT}")" || {
    printf 'FAIL | Vault operator state does not contain a root token\n' >&2
    return 1
  }
  export VAULT_TOKEN
  vault token lookup >/dev/null 2>&1 || {
    printf 'FAIL | Retained Vault operator token is invalid; restore operator state or reset Vault explicitly\n' >&2
    return 1
  }
}
