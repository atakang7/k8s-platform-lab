#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "${root}/infra/edge/versions.env"
mode="${1:-full}"
temporary="$(mktemp -d)"
trap 'rm -rf -- "${temporary}"' EXIT
chmod 0700 "${temporary}"

remove_edge() {
  local release name namespace
  for release in "external-dns external-dns" "ingress-nginx ingress-nginx" "metallb metallb-system"; do
    read -r name namespace <<< "${release}"
    helm --namespace "${namespace}" uninstall "${name}" --ignore-not-found
  done
  kubectl -n external-dns delete vaultstaticsecret rfc2136-tsig --ignore-not-found --wait=true
  kubectl -n ingress-nginx delete vaultstaticsecret lab-wildcard --ignore-not-found --wait=true
  helm --namespace vault-secrets-operator uninstall vault-secrets-operator --ignore-not-found
  kubectl delete namespace external-dns ingress-nginx metallb-system vault-secrets-operator stage3-validation \
    --ignore-not-found --wait=true
}

if [[ "${mode}" == down ]]; then
  remove_edge
  exit 0
fi

install_release() {
  local name="$1" namespace="$2" chart="$3" version="$4" values="$5"
  echo "WAIT | Reconciling ${name} ${version} in ${namespace} (timeout: 5m)"
  helm upgrade --install "${name}" "${chart}" \
    --namespace "${namespace}" --version "${version}" \
    --values "${root}/platform/edge/${values}/values.yaml" \
    --wait --rollback-on-failure --timeout 5m >/dev/null
  echo "PASS | ${name} is ready"
}

helm repo add metallb https://metallb.github.io/metallb --force-update >/dev/null
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx --force-update >/dev/null
helm repo add external-dns https://kubernetes-sigs.github.io/external-dns/ --force-update >/dev/null
helm repo add hashicorp https://helm.releases.hashicorp.com --force-update >/dev/null
helm repo update metallb ingress-nginx external-dns hashicorp >/dev/null

kubectl create namespace vault-secrets-operator --dry-run=client -o yaml | kubectl apply -f - >/dev/null
install_release vault-secrets-operator vault-secrets-operator hashicorp/vault-secrets-operator \
  "${VSO_CHART_VERSION}" vault-secrets-operator
[[ "${mode}" == vso ]] && exit 0

kubectl apply -f "${root}/platform/edge/vault-secrets-operator/resources/external-dns-connection.yaml" >/dev/null
kubectl apply -f "${root}/platform/edge/vault-secrets-operator/resources/external-dns-secret.yaml" >/dev/null
kubectl apply -f "${root}/platform/edge/vault-secrets-operator/resources/ingress-connection.yaml" >/dev/null
kubectl apply -f "${root}/platform/edge/vault-secrets-operator/resources/ingress-secret.yaml" >/dev/null
echo 'WAIT | Waiting for Vault-managed DNS and TLS Secrets (timeout: 2m)'
kubectl -n external-dns wait --for=condition=Ready vaultstaticsecret/rfc2136-tsig --timeout=2m >/dev/null
kubectl -n ingress-nginx wait --for=condition=Ready vaultstaticsecret/lab-wildcard --timeout=2m >/dev/null
vault kv get -format=json secret/edge/dns/tsig > "${temporary}/dns-vault.json"
kubectl -n external-dns get secret rfc2136-tsig -o json > "${temporary}/dns-kubernetes.json"
jq -e --slurpfile installed "${temporary}/dns-kubernetes.json" \
  '.data.data as $wanted | ($installed[0].data.key_name | @base64d) == $wanted.key_name and ($installed[0].data.secret | @base64d) == $wanted.secret' \
  "${temporary}/dns-vault.json" >/dev/null
vault kv get -format=json secret/edge/tls/wildcard > "${temporary}/tls-vault.json"
kubectl -n ingress-nginx get secret lab-wildcard -o json > "${temporary}/tls-kubernetes.json"
jq -e --slurpfile installed "${temporary}/tls-kubernetes.json" \
  '.data.data as $wanted | ($installed[0].data["tls.crt"] | @base64d) == $wanted["tls.crt"] and ($installed[0].data["tls.key"] | @base64d) == $wanted["tls.key"]' \
  "${temporary}/tls-vault.json" >/dev/null
echo 'PASS | Vault-managed DNS and TLS Secrets are ready'

kubectl label node node-2 node-3 edge.lab.test/worker=true --overwrite >/dev/null
kubectl create namespace metallb-system --dry-run=client -o yaml |
  kubectl label -f - pod-security.kubernetes.io/enforce=privileged \
    pod-security.kubernetes.io/audit=privileged \
    pod-security.kubernetes.io/warn=privileged --local -o yaml |
  kubectl apply -f - >/dev/null
install_release metallb metallb-system metallb/metallb "${METALLB_CHART_VERSION}" metallb
kubectl apply -f "${root}/platform/edge/metallb/resources/ip-address-pool.yaml" >/dev/null

install_release ingress-nginx ingress-nginx ingress-nginx/ingress-nginx \
  "${INGRESS_NGINX_CHART_VERSION}" ingress-nginx

install_release external-dns external-dns external-dns/external-dns \
  "${EXTERNAL_DNS_CHART_VERSION}" external-dns
kubectl apply -f "${root}/platform/edge/health/resources.yaml" >/dev/null
kubectl -n stage3-validation rollout status deployment/backend --timeout=3m >/dev/null
echo 'PASS | Retained edge health endpoint is ready'
echo 'PASS | VSO, MetalLB, ingress-nginx, and ExternalDNS are reconciled'
