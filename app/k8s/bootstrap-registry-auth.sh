#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
export VAULT_ADDR="${VAULT_ADDR:-https://127.0.0.1:8200}"

if [[ "${1:-}" != --cluster ]]; then
  vault token lookup >/dev/null
  vault policy write dockerhub-runtime-read "${root}/app/k8s/dockerhub-read.hcl" >/dev/null
  vault write auth/approle/role/dockerhub-runtime-vso \
    token_policies=dockerhub-runtime-read token_ttl=1h token_max_ttl=4h \
    secret_id_ttl=0 secret_id_num_uses=0 >/dev/null
  "${root}/infra/edge/lib/with-kubeconfig.sh" "$0" --cluster
  exit
fi

kubectl -n default create secret generic vault-ca \
  --from-file=ca.crt=/usr/local/share/ca-certificates/lab.crt \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl apply -f "${root}/app/k8s/vault-connection.yaml" >/dev/null

if ! kubectl -n default get secret dockerhub-runtime-approle-id >/dev/null 2>&1; then
  temporary="$(mktemp)"
  trap 'rm -f -- "${temporary}"' EXIT
  umask 077
  vault write -field=secret_id -f auth/approle/role/dockerhub-runtime-vso/secret-id > "${temporary}"
  kubectl -n default create secret generic dockerhub-runtime-approle-id \
    --from-file="id=${temporary}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
fi

role_id="$(vault read -field=role_id auth/approle/role/dockerhub-runtime-vso/role-id)"
kubectl apply -f - >/dev/null <<EOF
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultAuth
metadata:
  name: dockerhub-runtime
  namespace: default
spec:
  vaultConnectionRef: edge
  method: appRole
  mount: approle
  appRole:
    roleId: ${role_id}
    secretRef: dockerhub-runtime-approle-id
EOF
kubectl apply -f "${root}/app/k8s/registry-secret.yaml" >/dev/null
