#!/usr/bin/env bash
set -Eeuo pipefail

readonly root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${root}/infra/edge/config.env"

readonly validation_namespace=stage3-validation
readonly validation_vip=192.168.56.201
readonly external_dns_owner=lab-stage3

pass() {
  printf 'PASS | %s\n' "$1"
}

fail() {
  printf 'FAIL | %s\n' "$1" >&2
  exit 1
}

check_ready_nodes() {
  [[ "$(kubectl get nodes --no-headers |
    awk '$2 == "Ready" { count++ } END { print count+0 }')" == 3 ]] ||
    fail 'not all three Kubernetes nodes are Ready'
}

check_edge_workloads() {
  local timeout="$1"

  kubectl -n metallb-system rollout status deployment/metallb-controller \
    --timeout="${timeout}" >/dev/null
  kubectl -n metallb-system rollout status daemonset/metallb-speaker \
    --timeout="${timeout}" >/dev/null
  kubectl -n vault-secrets-operator rollout status \
    deployment/vault-secrets-operator-controller-manager \
    --timeout="${timeout}" >/dev/null
  kubectl -n ingress-nginx rollout status deployment/ingress-nginx-controller \
    --timeout="${timeout}" >/dev/null
  kubectl -n external-dns rollout status deployment/external-dns \
    --timeout="${timeout}" >/dev/null
}

check_metallb() {
  [[ "$(kubectl -n metallb-system get ipaddresspool edge \
    -o jsonpath='{.spec.autoAssign}')" == false ]] ||
    fail 'MetalLB edge pool allows automatic allocation'

  [[ "$(kubectl -n ingress-nginx get service ingress-nginx-controller \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}')" == "${INGRESS_VIP}" ]] ||
    fail "ingress VIP is not ${INGRESS_VIP}"

  [[ "$(kubectl -n ingress-nginx get service ingress-nginx-controller \
    -o jsonpath='{.spec.allocateLoadBalancerNodePorts}')" == false ]] ||
    fail 'ingress Service allocated NodePorts'

  pass 'MetalLB allocation is explicit'
}

check_ingress_placement() {
  local workers

  workers="$(kubectl -n ingress-nginx get pods \
    -l app.kubernetes.io/component=controller,app.kubernetes.io/instance=ingress-nginx \
    -o json |
    jq -r '.items[] | select(.status.phase == "Running") | .spec.nodeName' |
    sort -u)"

  [[ "${workers}" == $'node-2\nnode-3' ]] ||
    fail 'ingress replicas are not spread across both workers'

  pass 'ingress replicas run on separate workers'
}

check_vault_secrets_operator() {
  local namespace

  for namespace in external-dns ingress-nginx; do
    [[ "$(kubectl -n "${namespace}" get vaultconnection edge \
      -o jsonpath='{.spec.skipTLSVerify}')" == false ]] ||
      fail "${namespace} Vault connection disables TLS verification"

    [[ "$(kubectl -n "${namespace}" get vaultconnection edge \
      -o jsonpath='{.spec.caCertSecretRef}')" == vault-ca ]] ||
      fail "${namespace} Vault CA is missing"
  done

  kubectl -n external-dns get secret rfc2136-tsig >/dev/null
  [[ "$(kubectl -n ingress-nginx get secret lab-wildcard \
    -o jsonpath='{.type}')" == kubernetes.io/tls ]] ||
    fail 'VSO has not synchronized the ingress TLS Secret'

  pass 'Vault-managed DNS and TLS Secrets are present'
}

check_external_dns_configuration() {
  local deployment

  deployment="$(kubectl -n external-dns get deployment external-dns -o json)"

  jq -e --arg zone "${DNS_ZONE}" --arg owner "${external_dns_owner}" '
    [.spec.template.spec.containers[0].args[]] as $args
    | ($args | any(. == "--domain-filter=" + $zone))
      and ($args | any(. == "--policy=sync"))
      and ($args | any(. == "--registry=txt"))
      and ($args | any(. == "--txt-owner-id=" + $owner))
      and ($args | any(. == "--source=service"))
      and ($args | any(. == "--source=ingress"))
  ' <<<"${deployment}" >/dev/null ||
    fail 'ExternalDNS ownership, sync, domain, or source configuration is wrong'

  jq -e '
    .spec.template.spec.containers[0].env[]
    | select(.name == "EXTERNAL_DNS_RFC2136_TSIG_SECRET")
    | .valueFrom.secretKeyRef.name == "rfc2136-tsig"
  ' <<<"${deployment}" >/dev/null ||
    fail 'ExternalDNS TSIG does not come from the expected Secret'

  pass 'ExternalDNS configuration is scoped and owned'
}

cleanup_validation_services() {
  kubectl -n "${validation_namespace}" delete service \
    explicit-edge no-edge-request --ignore-not-found --wait=true >/dev/null || true
}

check_service_dns_lifecycle() {
  local service_hostname

  trap cleanup_validation_services EXIT

  kubectl -n "${validation_namespace}" rollout status deployment/backend \
    --timeout=180s >/dev/null

  kubectl -n "${validation_namespace}" apply -f - >/dev/null <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: no-edge-request
spec:
  type: LoadBalancer
  selector:
    app: stage3-backend
  ports:
    - port: 80
      targetPort: 5678
EOF

  sleep 5
  [[ -z "$(kubectl -n "${validation_namespace}" get service no-edge-request \
    -o jsonpath='{.status.loadBalancer.ingress[*].ip}')" ]] ||
    fail 'unannotated LoadBalancer Service received an edge IP'
  pass 'unannotated LoadBalancer Service remains private'

  service_hostname="service-$$.${DNS_ZONE}"
  kubectl -n "${validation_namespace}" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Service
metadata:
  name: explicit-edge
  annotations:
    metallb.io/address-pool: edge
    metallb.io/loadBalancerIPs: ${validation_vip}
    external-dns.alpha.kubernetes.io/hostname: ${service_hostname}
spec:
  type: LoadBalancer
  allocateLoadBalancerNodePorts: false
  selector:
    app: stage3-backend
  ports:
    - port: 80
      targetPort: 5678
EOF

  for _ in {1..90}; do
    if [[ "$(kubectl -n "${validation_namespace}" get service explicit-edge \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}')" == "${validation_vip}" ]] &&
      [[ "$(dig +short "@${EDGE_HOST_IP}" "${service_hostname}" A | tail -1)" \
        == "${validation_vip}" ]]; then
      pass 'new Service created its DNS A record'
      break
    fi
    sleep 2
  done

  [[ "$(dig +short "@${EDGE_HOST_IP}" "${service_hostname}" A | tail -1)" \
    == "${validation_vip}" ]] ||
    fail 'new Service did not create its DNS record'

  kubectl -n "${validation_namespace}" delete service explicit-edge --wait=true >/dev/null

  for _ in {1..90}; do
    if [[ -z "$(dig +short "@${EDGE_HOST_IP}" "${service_hostname}" A)" ]]; then
      pass 'Service deletion removed its owned DNS record'
      break
    fi
    sleep 2
  done

  [[ -z "$(dig +short "@${EDGE_HOST_IP}" "${service_hostname}" A)" ]] ||
    fail 'Service DNS record was not deleted'
}

check_ingress_dns_and_tls() {
  local readonly host="stage3.${DNS_ZONE}"

  for _ in {1..90}; do
    if [[ "$(dig +short "@${EDGE_HOST_IP}" "${host}" A | tail -1)" == "${INGRESS_VIP}" ]] &&
      [[ "$(curl --noproxy '*' --silent --show-error --fail --max-time 3 \
        "https://${host}" 2>/dev/null)" == stage3-edge-ok ]]; then
      pass 'Ingress DNS and trusted HTTPS are working'
      return
    fi
    sleep 2
  done

  fail 'validation backend is not reachable through DNS and trusted HTTPS'
}

main() {
  check_ready_nodes

  if [[ "${1:-}" == --smoke ]]; then
    check_edge_workloads 30s
    return
  fi

  check_edge_workloads 90s
  pass 'three nodes and edge workloads are Ready'

  check_metallb
  check_ingress_placement
  check_vault_secrets_operator
  check_external_dns_configuration
  check_service_dns_lifecycle
  check_ingress_dns_and_tls
}

main "$@"
