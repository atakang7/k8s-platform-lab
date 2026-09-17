#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "${root}/infra/edge/versions.env"
mode="${1:-full}"

install_release() {
  local name="$1" namespace="$2" chart="$3" version="$4" values="$5"
  helm upgrade --install "${name}" "${chart}" \
    --namespace "${namespace}" --version "${version}" \
    --values "${root}/platform/edge/${values}/values.yaml" \
    --wait --atomic --timeout 5m >/dev/null
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
for _ in {1..60}; do
  if kubectl -n external-dns get secret rfc2136-tsig >/dev/null 2>&1 &&
     kubectl -n ingress-nginx get secret lab-wildcard >/dev/null 2>&1; then break; fi
  sleep 2
done
kubectl -n external-dns get secret rfc2136-tsig >/dev/null
kubectl -n ingress-nginx get secret lab-wildcard >/dev/null

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
echo 'PASS | VSO, MetalLB, ingress-nginx, and ExternalDNS are reconciled'
