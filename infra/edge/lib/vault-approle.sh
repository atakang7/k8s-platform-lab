#!/usr/bin/env bash

vault_approle_secret_is_valid() {
  local role="$1" secret_file="$2"
  # Vault answers an unknown secret ID with an empty result, not an error.
  [[ -s "${secret_file}" ]] &&
    [[ -n "$(vault write -field=secret_id_accessor "auth/approle/role/${role}/secret-id/lookup" \
      secret_id="$(<"${secret_file}")" 2>/dev/null)" ]]
}
