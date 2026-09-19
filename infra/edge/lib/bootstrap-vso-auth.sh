#!/usr/bin/env bash
set -Eeuo pipefail

readonly root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "${root}/infra/edge/lib/vault-approle.sh"

prepare_namespace() {
  local namespace="$1"

  kubectl create namespace "${namespace}" --dry-run=client -o yaml |
    kubectl apply -f - >/dev/null

  kubectl -n "${namespace}" create secret generic vault-ca \
    --from-file=ca.crt=/usr/local/share/ca-certificates/lab.crt \
    --dry-run=client -o yaml |
    kubectl apply -f - >/dev/null
}

read_installed_secret_id() {
  local namespace="$1" output="$2"

  kubectl -n "${namespace}" get secret approle-id \
    -o jsonpath='{.data.id}' 2>/dev/null |
    base64 --decode > "${output}" || true
}

reconcile_identity() (
  set -Eeuo pipefail

  local namespace="$1" role="$2" name="$3"
  local temporary role_id installed_role_id installed_secret

  temporary="$(mktemp -d)"
  trap 'rm -rf -- "${temporary}"' EXIT
  chmod 0700 "${temporary}"
  umask 077

  installed_secret="${temporary}/installed-secret-id"
  role_id="$(vault read -field=role_id "auth/approle/role/${role}/role-id")"
  read_installed_secret_id "${namespace}" "${installed_secret}"

  installed_role_id="$(kubectl -n "${namespace}" get vaultauth "${name}" \
    -o jsonpath='{.spec.appRole.roleId}' 2>/dev/null || true)"

  if [[ "${installed_role_id}" != "${role_id}" ]] ||
    ! vault_approle_secret_is_valid "${role}" "${installed_secret}"; then
    vault write -field=secret_id -f \
      "auth/approle/role/${role}/secret-id" > "${temporary}/secret-id"

    kubectl -n "${namespace}" create secret generic approle-id \
      --from-file="id=${temporary}/secret-id" \
      --dry-run=client -o yaml |
      kubectl apply -f - >/dev/null
  fi

  kubectl apply -f - >/dev/null <<EOF
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultAuth
metadata:
  name: ${name}
  namespace: ${namespace}
spec:
  vaultConnectionRef: edge
  method: appRole
  mount: approle
  appRole:
    roleId: ${role_id}
    secretRef: approle-id
EOF
)

main() {
  prepare_namespace external-dns
  prepare_namespace ingress-nginx

  reconcile_identity external-dns dns-vso dns
  reconcile_identity ingress-nginx tls-vso tls
}

main "$@"
