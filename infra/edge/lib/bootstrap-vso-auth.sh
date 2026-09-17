#!/usr/bin/env bash
set -Eeuo pipefail

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
for pair in 'external-dns dns-vso dns' 'ingress-nginx tls-vso tls'; do
  read -r namespace role name <<< "${pair}"
  role_id="$(vault read -field=role_id "auth/approle/role/${role}/role-id")"
  if ! kubectl -n "${namespace}" get secret approle-id >/dev/null 2>&1; then
    vault write -field=secret_id -f "auth/approle/role/${role}/secret-id" > "${temporary}/id"
    kubectl -n "${namespace}" create secret generic approle-id \
      --from-file="id=${temporary}/id" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    rm -f "${temporary}/id"
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
done
