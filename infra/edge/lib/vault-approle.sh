#!/usr/bin/env bash
# AppRole login material. A role ID is a name (not secret); a secret ID is the
# password. Every role has a pinned role ID.

vault_approle_secret_is_valid() {
  local role="$1" secret_file="$2"
  # Vault answers an unknown secret ID with an empty result, not an error.
  [[ -s "${secret_file}" ]] &&
    [[ -n "$(vault write -field=secret_id_accessor "auth/approle/role/${role}/secret-id/lookup" \
      secret_id="$(<"${secret_file}")" 2>/dev/null)" ]]
}

# Gives a namespace the secret ID for a role, as Kubernetes Secret <secret>
# with key "id". The stored one is kept while Vault still knows it; otherwise
# a new one is issued.
#   install_approle_secret_id <namespace> <role> <secret>
install_approle_secret_id() {
  local namespace="$1"
  local role="$2"
  local secret="$3"
  local stored_secret_id=''
  local accessor=''
  local new_secret_id

  if kubectl -n "${namespace}" get secret "${secret}" >/dev/null 2>&1; then
    stored_secret_id="$(kubectl -n "${namespace}" get secret "${secret}" \
      -o go-template='{{ .data.id | base64decode }}')"
  fi

  # Vault answers an unknown secret ID with an empty result, not an error.
  if [[ -n "${stored_secret_id}" ]]; then
    accessor="$(vault write -field=secret_id_accessor \
      "auth/approle/role/${role}/secret-id/lookup" \
      secret_id="${stored_secret_id}" 2>/dev/null || true)"
  fi

  if [[ -n "${accessor}" ]]; then
    return
  fi

  new_secret_id="$(vault write -f -field=secret_id "auth/approle/role/${role}/secret-id")"

  kubectl -n "${namespace}" delete secret "${secret}" --ignore-not-found >/dev/null
  kubectl -n "${namespace}" create secret generic "${secret}" \
    --from-literal=id="${new_secret_id}" >/dev/null
}
