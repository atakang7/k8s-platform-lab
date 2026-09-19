#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT
source "${ROOT}/infra/edge/config.env"

readonly VALIDATION_NAMESPACE=stage3-validation
readonly VALIDATION_VIP=192.168.56.201
readonly EXTERNAL_DNS_OWNER=lab-stage3

pass() {
  printf 'PASS | %s\n' "$1"
}

fail() {
  printf 'FAIL | %s\n' "$1" >&2
  exit 1
}

check_ready_nodes() {
  local nodes

  nodes="$(kubectl get nodes -o json)"
  jq -e '
    (.items | length == 3)
    and all(
      .items[];
      any(.status.conditions[]; .type == "Ready" and .status == "True")
    )
  ' <<< "${nodes}" >/dev/null ||
    fail 'cluster does not contain exactly three Ready nodes'
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

  workers="$(
    kubectl -n ingress-nginx get pods \
      -l app.kubernetes.io/component=controller,app.kubernetes.io/instance=ingress-nginx \
      -o json |
      jq -r '.items[] | select(.status.phase == "Running") | .spec.nodeName' |
      sort -u
  )"

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

  jq -e --arg zone "${DNS_ZONE}" --arg owner "${EXTERNAL_DNS_OWNER}" '
    [.spec.template.spec.containers[0].args[]] as $args
    | ($args | any(. == "--domain-filter=" + $zone))
      and ($args | any(. == "--policy=sync"))
      and ($args | any(. == "--registry=txt"))
      and ($args | any(. == "--txt-owner-id=" + $owner))
      and ($args | any(. == "--source=service"))
      and ($args | any(. == "--source=ingress"))
  ' <<< "${deployment}" >/dev/null ||
    fail 'ExternalDNS ownership, sync, domain, or source configuration is wrong'

  jq -e '
    .spec.template.spec.containers[0].env[]
    | select(.name == "EXTERNAL_DNS_RFC2136_TSIG_SECRET")
    | .valueFrom.secretKeyRef.name == "rfc2136-tsig"
  ' <<< "${deployment}" >/dev/null ||
    fail 'ExternalDNS TSIG does not come from the expected Secret'

  pass 'ExternalDNS configuration is scoped and owned'
}

cleanup_validation_services() {
  kubectl -n "${VALIDATION_NAMESPACE}" delete service \
    explicit-edge \
    no-edge-request \
    --ignore-not-found \
    --wait=true >/dev/null 2>&1 || true
}

check_private_load_balancer_default() {
  kubectl -n "${VALIDATION_NAMESPACE}" apply -f - >/dev/null <<'EOF_PRIVATE_SERVICE'
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
EOF_PRIVATE_SERVICE

  sleep 5

  [[ -z "$(kubectl -n "${VALIDATION_NAMESPACE}" get service no-edge-request \
    -o jsonpath='{.status.loadBalancer.ingress[*].ip}')" ]] ||
    fail 'unannotated LoadBalancer Service received an edge IP'

  pass 'unannotated LoadBalancer Service remains private'
}

create_explicit_edge_service() {
  local service_hostname="$1"

  kubectl -n "${VALIDATION_NAMESPACE}" apply -f - >/dev/null <<EOF_EDGE_SERVICE
apiVersion: v1
kind: Service
metadata:
  name: explicit-edge
  annotations:
    metallb.io/address-pool: edge
    metallb.io/loadBalancerIPs: ${VALIDATION_VIP}
    external-dns.alpha.kubernetes.io/hostname: ${service_hostname}
spec:
  type: LoadBalancer
  allocateLoadBalancerNodePorts: false
  selector:
    app: stage3-backend
  ports:
    - port: 80
      targetPort: 5678
EOF_EDGE_SERVICE
}

wait_for_service_dns() {
  local service_hostname="$1"
  local attempt

  for attempt in {1..90}; do
    if [[ "$(kubectl -n "${VALIDATION_NAMESPACE}" get service explicit-edge \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}')" == "${VALIDATION_VIP}" ]] &&
      [[ "$(dig +short "@${EDGE_HOST_IP}" "${service_hostname}" A | tail -1)" \
        == "${VALIDATION_VIP}" ]]; then
      return
    fi
    sleep 2
  done

  fail 'new Service did not receive its requested VIP and DNS record'
}

wait_for_dns_removal() {
  local service_hostname="$1"
  local attempt

  for attempt in {1..90}; do
    if [[ -z "$(dig +short "@${EDGE_HOST_IP}" "${service_hostname}" A)" ]]; then
      return
    fi
    sleep 2
  done

  fail 'Service DNS record was not deleted'
}

check_service_dns_lifecycle() {
  local service_hostname

  # An interrupted previous run must not satisfy today's create/delete proof.
  cleanup_validation_services

  kubectl -n "${VALIDATION_NAMESPACE}" rollout status deployment/backend \
    --timeout=180s >/dev/null

  check_private_load_balancer_default

  service_hostname="service-$$.${DNS_ZONE}"
  create_explicit_edge_service "${service_hostname}"
  wait_for_service_dns "${service_hostname}"
  pass 'new Service received its requested VIP and DNS A record'

  kubectl -n "${VALIDATION_NAMESPACE}" delete service explicit-edge \
    --wait=true >/dev/null

  wait_for_dns_removal "${service_hostname}"
  pass 'Service deletion removed its owned DNS record'
}

check_ingress_dns_and_tls() {
  local attempt
  local response
  local -r host="stage3.${DNS_ZONE}"

  for attempt in {1..90}; do
    if [[ "$(dig +short "@${EDGE_HOST_IP}" "${host}" A | tail -1)" \
      == "${INGRESS_VIP}" ]]; then
      response="$(
        curl \
          --noproxy '*' \
          --silent \
          --show-error \
          --fail \
          --max-time 3 \
          "https://${host}" 2>/dev/null || true
      )"

      if [[ "${response}" == stage3-edge-ok ]]; then
        pass 'Ingress DNS and trusted HTTPS are working'
        return
      fi
    fi
    sleep 2
  done

  fail 'validation backend is not reachable through DNS and trusted HTTPS'
}

run_smoke_checks() {
  check_ready_nodes
  check_edge_workloads 30s
}

run_deep_checks() {
  trap cleanup_validation_services EXIT

  check_ready_nodes
  check_edge_workloads 90s
  pass 'three nodes and edge workloads are Ready'

  check_metallb
  check_ingress_placement
  check_vault_secrets_operator
  check_external_dns_configuration
  check_service_dns_lifecycle
  check_ingress_dns_and_tls
}

main() {
  case "${1:-}" in
    --smoke)
      [[ "$#" -eq 1 ]] || fail 'edge cluster smoke accepts only --smoke'
      run_smoke_checks
      ;;
    '')
      run_deep_checks
      ;;
    *)
      fail "unknown edge cluster validation argument: $1"
      ;;
  esac
}

main "$@"
