#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "${root}/infra/edge/lib/vault-approle.sh"

for namespace in external-dns ingress-nginx; do
  kubectl create namespace "${namespace}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n "${namespace}" create secret generic vault-ca \
    --from-file=ca.crt=/usr/local/share/ca-certificates/lab.crt \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
done

temporary="$(mktemp -d)"
chmod 0700 "${temporary}"
trap 'rm -rf -- "${temporary}"' EXIT
umask 077
read_kubernetes_secret() {
  local namespace="$1" output="$2"
  kubectl -n "${namespace}" get secret approle-id -o jsonpath='{.data.id}' 2>/dev/null |
    base64 --decode > "${output}" || true
}

reconcile_identity() {
  local namespace="$1" role="$2" name="$3"
  local role_id installed_role_id secret_file
  secret_file="${temporary}/${namespace}-secret-id"
  role_id="$(vault read -field=role_id "auth/approle/role/${role}/role-id")"
  read_kubernetes_secret "${namespace}" "${secret_file}"
  installed_role_id="$(kubectl -n "${namespace}" get vaultauth "${name}" -o jsonpath='{.spec.appRole.roleId}' 2>/dev/null || true)"
  if [[ "${installed_role_id}" != "${role_id}" ]] ||
     ! vault_approle_secret_is_valid "${role}" "${secret_file}"; then
    vault write -field=secret_id -f "auth/approle/role/${role}/secret-id" > "${temporary}/new-secret-id"
    kubectl -n "${namespace}" create secret generic approle-id \
      --from-file="id=${temporary}/new-secret-id" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    rm -f "${temporary}/new-secret-id"
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
}

reconcile_identity external-dns dns-vso dns
reconcile_identity ingress-nginx tls-vso tls
