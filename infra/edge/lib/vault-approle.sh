#!/usr/bin/env bash

vault_approle_secret_is_valid() {
  local role="$1" secret_file="$2"
  [[ -s "${secret_file}" ]] &&
    vault write -format=json "auth/approle/role/${role}/secret-id/lookup" \
      secret_id="$(<"${secret_file}")" >/dev/null 2>&1
}
