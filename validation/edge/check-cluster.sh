#!/usr/bin/env bash
set -Eeuo pipefail

pass() { printf 'PASS | %s\n' "$1"; }
fail() { printf 'FAIL | %s\n' "$1" >&2; exit 1; }

check_smoke_workloads() {
  [[ "$(kubectl get nodes --no-headers | awk '$2 == "Ready" { count++ } END { print count+0 }')" == 3 ]] ||
    fail 'not all three Kubernetes nodes are Ready'
  kubectl -n metallb-system rollout status deployment/metallb-controller --timeout=30s >/dev/null
  kubectl -n metallb-system rollout status daemonset/metallb-speaker --timeout=30s >/dev/null
  kubectl -n vault-secrets-operator rollout status deployment/vault-secrets-operator-controller-manager --timeout=30s >/dev/null
  kubectl -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout=30s >/dev/null
  kubectl -n external-dns rollout status deployment/external-dns --timeout=30s >/dev/null
}

if [[ "${1:-}" == --smoke ]]; then
  check_smoke_workloads
  exit 0
fi

[[ "$(kubectl get nodes --no-headers | awk '$2 == "Ready" { count++ } END { print count+0 }')" == 3 ]] || fail 'not all three Kubernetes nodes are Ready'
pass 'three Kubernetes nodes remain Ready'
kubectl -n metallb-system rollout status deployment/metallb-controller --timeout=90s >/dev/null
kubectl -n metallb-system rollout status daemonset/metallb-speaker --timeout=90s >/dev/null
[[ "$(kubectl -n metallb-system get ipaddresspool edge -o jsonpath='{.spec.autoAssign}')" == false ]] || fail 'MetalLB edge pool allows automatic allocation'
[[ "$(kubectl -n ingress-nginx get service ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}')" == 192.168.56.200 ]] || fail 'ingress VIP is not 192.168.56.200'
[[ "$(kubectl -n ingress-nginx get service ingress-nginx-controller -o jsonpath='{.spec.allocateLoadBalancerNodePorts}')" == false ]] || fail 'ingress Service allocated NodePorts'
pass 'MetalLB is healthy and edge allocation is explicit'

kubectl -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout=90s >/dev/null
workers="$(kubectl -n ingress-nginx get pods -l app.kubernetes.io/component=controller,app.kubernetes.io/instance=ingress-nginx -o json | jq -r '.items[] | select(.status.phase == "Running") | .spec.nodeName' | sort -u)"
[[ "${workers}" == $'node-2\nnode-3' ]] || fail 'two ingress replicas are not spread across both workers'
pass 'two ingress replicas run on separate workers'

kubectl -n vault-secrets-operator rollout status deployment/vault-secrets-operator-controller-manager --timeout=90s >/dev/null
for namespace in external-dns ingress-nginx; do
  [[ "$(kubectl -n "${namespace}" get vaultconnection edge -o jsonpath='{.spec.skipTLSVerify}')" == false ]] || fail "${namespace} Vault connection disables TLS verification"
  [[ "$(kubectl -n "${namespace}" get vaultconnection edge -o jsonpath='{.spec.caCertSecretRef}')" == vault-ca ]] || fail "${namespace} Vault CA is missing"
done
kubectl -n external-dns get secret rfc2136-tsig >/dev/null
[[ "$(kubectl -n ingress-nginx get secret lab-wildcard -o jsonpath='{.type}')" == kubernetes.io/tls ]] || fail 'VSO has not synchronized TLS secret'
pass 'VSO synchronizes TSIG and TLS via verified Vault connections'

kubectl -n external-dns rollout status deployment/external-dns --timeout=90s >/dev/null
deployment="$(kubectl -n external-dns get deployment external-dns -o json)"
jq -e '[.spec.template.spec.containers[0].args[]] | any(. == "--domain-filter=lab.test")' <<< "${deployment}" >/dev/null || fail 'ExternalDNS domain filter is absent'
jq -e '[.spec.template.spec.containers[0].args[]] | any(. == "--policy=sync")' <<< "${deployment}" >/dev/null || fail 'ExternalDNS sync policy is absent'
jq -e '[.spec.template.spec.containers[0].args[]] | any(. == "--registry=txt")' <<< "${deployment}" >/dev/null || fail 'ExternalDNS TXT ownership is absent'
jq -e '[.spec.template.spec.containers[0].args[]] | any(. == "--txt-owner-id=lab-stage3")' <<< "${deployment}" >/dev/null || fail 'ExternalDNS owner ID is absent'
jq -e '[.spec.template.spec.containers[0].args[]] | any(. == "--source=service")' <<< "${deployment}" >/dev/null || fail 'ExternalDNS Service source is absent'
jq -e '[.spec.template.spec.containers[0].args[]] | any(. == "--source=ingress")' <<< "${deployment}" >/dev/null || fail 'ExternalDNS Ingress source is absent'
jq -e '.spec.template.spec.containers[0].env[] | select(.name == "EXTERNAL_DNS_RFC2136_TSIG_SECRET") | .valueFrom.secretKeyRef.name == "rfc2136-tsig"' <<< "${deployment}" >/dev/null || fail 'ExternalDNS TSIG does not come from a Secret'
pass 'ExternalDNS has restricted sync, TXT ownership, and both sources'

# shellcheck disable=SC2329
cleanup() {
  kubectl -n stage3-validation delete service explicit-edge no-edge-request --ignore-not-found --wait=true >/dev/null || :
}
trap cleanup EXIT
kubectl -n stage3-validation rollout status deployment/backend --timeout=180s >/dev/null
kubectl -n stage3-validation apply -f - >/dev/null <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: no-edge-request
  namespace: stage3-validation
spec:
  type: LoadBalancer
  selector: {app: stage3-backend}
  ports: [{port: 80, targetPort: 5678}]
EOF
sleep 5
[[ -z "$(kubectl -n stage3-validation get service no-edge-request -o jsonpath='{.status.loadBalancer.ingress[*].ip}')" ]] || fail 'unannotated LoadBalancer Service received an edge IP'
pass 'unannotated LoadBalancer Service remains private'
service_hostname="service-$$.lab.test"
kubectl -n stage3-validation apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Service
metadata:
  name: explicit-edge
  namespace: stage3-validation
  annotations:
    metallb.io/address-pool: edge
    metallb.io/loadBalancerIPs: 192.168.56.201
    external-dns.alpha.kubernetes.io/hostname: ${service_hostname}
spec:
  type: LoadBalancer
  allocateLoadBalancerNodePorts: false
  selector: {app: stage3-backend}
  ports: [{port: 80, targetPort: 5678}]
EOF
for _ in {1..90}; do
  if [[ "$(kubectl -n stage3-validation get service explicit-edge -o jsonpath='{.status.loadBalancer.ingress[0].ip}')" == 192.168.56.201 ]] &&
     [[ "$(dig +short @192.168.56.1 "${service_hostname}" A | tail -1)" == 192.168.56.201 ]]; then
    pass 'new Service automatically created its DNS A record through ExternalDNS'
    break
  fi
  sleep 2
done
[[ "$(dig +short @192.168.56.1 "${service_hostname}" A | tail -1)" == 192.168.56.201 ]] || fail 'new Service did not create its DNS record'
kubectl -n stage3-validation delete service explicit-edge --wait=true >/dev/null
for _ in {1..90}; do
  if [[ -z "$(dig +short @192.168.56.1 "${service_hostname}" A)" ]]; then
    pass 'ExternalDNS removed its owned record after Service deletion'
    break
  fi
  sleep 2
done
[[ -z "$(dig +short @192.168.56.1 "${service_hostname}" A)" ]] || fail 'Service record was not deleted by ExternalDNS sync'
for _ in {1..90}; do
  if [[ "$(dig +short @192.168.56.1 stage3.lab.test A | tail -1)" == 192.168.56.200 ]] &&
     [[ "$(curl --noproxy '*' --silent --show-error --fail --max-time 3 https://stage3.lab.test 2>/dev/null)" == stage3-edge-ok ]]; then
    pass 'Ingress source created DNS; trusted HTTPS reaches the Stage 3 hostname'
    exit 0
  fi
  sleep 2
done
fail 'temporary backend was not reachable via trusted HTTPS and automatic DNS'
