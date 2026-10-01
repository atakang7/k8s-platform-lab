#!/usr/bin/env bash
# Cluster side of the edge validation. Runs through the SSH tunnel
# (with-kubeconfig.sh).
#
#   check-cluster.sh           deep checks, including a Service DNS lifecycle
#   check-cluster.sh --smoke   nodes and edge workloads only
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT
readonly VALIDATION_DIRECTORY="${ROOT}/validation/edge"

# shellcheck source=../../infra/edge/config.env
source "${ROOT}/infra/edge/config.env"

# Must match metallb.io/loadBalancerIPs in edge-service.yaml.
readonly VALIDATION_VIP=192.168.56.201

fail() {
  printf 'FAIL | %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'PASS | %s\n' "$1"
}

check_ready_nodes() {
  local ready

  ready="$(kubectl get nodes \
    -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{" "}{end}')"

  if [[ "${ready}" != 'True True True ' ]]; then
    fail "the cluster should have three Ready nodes; Ready states: ${ready}"
  fi
}

check_edge_workloads() {
  local timeout="$1"

  kubectl -n metallb-system rollout status deployment/metallb-controller --timeout="${timeout}" >/dev/null
  kubectl -n metallb-system rollout status daemonset/metallb-speaker --timeout="${timeout}" >/dev/null
  kubectl -n vault-secrets-operator rollout status deployment/vault-secrets-operator-controller-manager --timeout="${timeout}" >/dev/null
  kubectl -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout="${timeout}" >/dev/null
  kubectl -n external-dns rollout status deployment/external-dns --timeout="${timeout}" >/dev/null
}

check_metallb() {
  local auto_assign
  local ingress_ip
  local node_ports

  auto_assign="$(kubectl -n metallb-system get ipaddresspool edge -o jsonpath='{.spec.autoAssign}')"
  ingress_ip="$(kubectl -n ingress-nginx get service ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
  node_ports="$(kubectl -n ingress-nginx get service ingress-nginx-controller -o jsonpath='{.spec.allocateLoadBalancerNodePorts}')"

  if [[ "${auto_assign}" != false ]]; then
    fail 'the MetalLB edge pool hands out IPs automatically'
  fi
  if [[ "${ingress_ip}" != "${INGRESS_VIP}" ]]; then
    fail "the ingress Service has IP ${ingress_ip}, not ${INGRESS_VIP}"
  fi
  if [[ "${node_ports}" != false ]]; then
    fail 'the ingress Service allocated NodePorts'
  fi

  pass 'MetalLB hands out edge IPs only on request'
}

check_ingress_placement() {
  local nodes

  nodes="$(kubectl -n ingress-nginx get pods \
    --selector app.kubernetes.io/component=controller,app.kubernetes.io/instance=ingress-nginx \
    --field-selector status.phase=Running \
    -o jsonpath='{.items[*].spec.nodeName}')"

  if [[ " ${nodes} " != *' node-2 '* || " ${nodes} " != *' node-3 '* ]]; then
    fail "ingress replicas should run on node-2 and node-3; run on: ${nodes}"
  fi

  pass 'ingress replicas run on both workers'
}

check_vault_secrets_operator() {
  local dns_skip_verify
  local dns_ca
  local ingress_skip_verify
  local ingress_ca
  local tls_type

  dns_skip_verify="$(kubectl -n external-dns get vaultconnection edge -o jsonpath='{.spec.skipTLSVerify}')"
  dns_ca="$(kubectl -n external-dns get vaultconnection edge -o jsonpath='{.spec.caCertSecretRef}')"
  ingress_skip_verify="$(kubectl -n ingress-nginx get vaultconnection edge -o jsonpath='{.spec.skipTLSVerify}')"
  ingress_ca="$(kubectl -n ingress-nginx get vaultconnection edge -o jsonpath='{.spec.caCertSecretRef}')"
  tls_type="$(kubectl -n ingress-nginx get secret lab-wildcard -o jsonpath='{.type}')"

  if [[ "${dns_skip_verify}" != false || "${ingress_skip_verify}" != false ]]; then
    fail 'a Vault connection skips TLS verification'
  fi
  if [[ "${dns_ca}" != vault-ca || "${ingress_ca}" != vault-ca ]]; then
    fail 'a Vault connection does not use the vault-ca certificate'
  fi
  kubectl -n external-dns get secret rfc2136-tsig >/dev/null ||
    fail 'the DNS TSIG Secret has not been synced from Vault'
  if [[ "${tls_type}" != kubernetes.io/tls ]]; then
    fail 'the ingress TLS Secret has not been synced from Vault'
  fi

  pass 'Vault-managed DNS and TLS Secrets are present'
}

check_external_dns_configuration() {
  local arguments
  local tsig_secret

  arguments=" $(kubectl -n external-dns get deployment external-dns -o jsonpath='{.spec.template.spec.containers[0].args[*]}') "
  tsig_secret="$(kubectl -n external-dns get deployment external-dns \
    -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="EXTERNAL_DNS_RFC2136_TSIG_SECRET")].valueFrom.secretKeyRef.name}')"

  if [[ "${arguments}" != *" --domain-filter=${DNS_ZONE} "* ]]; then
    fail "ExternalDNS is not limited to ${DNS_ZONE}"
  fi
  if [[ "${arguments}" != *' --policy=sync '* ]]; then
    fail 'ExternalDNS does not delete records it no longer needs (--policy=sync)'
  fi
  if [[ "${arguments}" != *' --registry=txt '* || "${arguments}" != *' --txt-owner-id=lab-stage3 '* ]]; then
    fail 'ExternalDNS does not mark its records with the lab-stage3 owner'
  fi
  if [[ "${arguments}" != *' --source=service '* || "${arguments}" != *' --source=ingress '* ]]; then
    fail 'ExternalDNS does not watch both Services and Ingresses'
  fi
  if [[ "${tsig_secret}" != rfc2136-tsig ]]; then
    fail 'ExternalDNS does not take its TSIG key from the rfc2136-tsig Secret'
  fi

  pass 'ExternalDNS is scoped to its zone and owns its records'
}

delete_validation_services() {
  kubectl -n stage3-validation delete service explicit-edge no-edge-request \
    --ignore-not-found --wait=true >/dev/null 2>&1 || true
}

check_private_service_stays_private() {
  local address

  kubectl -n stage3-validation apply -f "${VALIDATION_DIRECTORY}/private-service.yaml" >/dev/null
  sleep 5

  address="$(kubectl -n stage3-validation get service no-edge-request -o jsonpath='{.status.loadBalancer.ingress[*].ip}')"
  if [[ -n "${address}" ]]; then
    fail "a LoadBalancer Service that did not ask for the edge got edge IP ${address}"
  fi

  pass 'a LoadBalancer Service without an edge request stays private'
}

# A Service asking for an edge IP and hostname gets both, and its DNS record
# goes away with it.
check_service_dns_lifecycle() {
  local hostname="service-$$.${DNS_ZONE}"
  local address
  local service_ip
  local created=false
  local removed=false

  kubectl -n stage3-validation apply -f "${VALIDATION_DIRECTORY}/edge-service.yaml" >/dev/null
  kubectl -n stage3-validation annotate service explicit-edge \
    "external-dns.alpha.kubernetes.io/hostname=${hostname}" --overwrite >/dev/null

  for _ in {1..90}; do
    service_ip="$(kubectl -n stage3-validation get service explicit-edge -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
    address="$(dig +short "@${EDGE_HOST_IP}" "${hostname}" A)"
    if [[ "${service_ip}" == "${VALIDATION_VIP}" && "${address}" == *"${VALIDATION_VIP}"* ]]; then
      created=true
      break
    fi
    sleep 2
  done
  if [[ "${created}" != true ]]; then
    fail "the edge Service did not get IP ${VALIDATION_VIP} and DNS record ${hostname}"
  fi
  pass 'a new edge Service got its requested IP and DNS record'

  kubectl -n stage3-validation delete service explicit-edge --wait=true >/dev/null

  for _ in {1..90}; do
    address="$(dig +short "@${EDGE_HOST_IP}" "${hostname}" A)"
    if [[ -z "${address}" ]]; then
      removed=true
      break
    fi
    sleep 2
  done
  if [[ "${removed}" != true ]]; then
    fail "DNS record ${hostname} stayed after its Service was deleted"
  fi
  pass 'deleting the Service removed its DNS record'
}

check_ingress_dns_and_tls() {
  local host="stage3.${DNS_ZONE}"
  local address
  local response

  for _ in {1..90}; do
    address="$(dig +short "@${EDGE_HOST_IP}" "${host}" A)"
    if [[ "${address}" == *"${INGRESS_VIP}"* ]]; then
      response="$(curl --noproxy '*' --silent --show-error --fail --max-time 3 "https://${host}" 2>/dev/null || true)"
      if [[ "${response}" == stage3-edge-ok ]]; then
        pass 'Ingress DNS and trusted HTTPS work'
        return
      fi
    fi
    sleep 2
  done

  fail "https://${host} is not reachable through DNS and trusted HTTPS"
}

main() {
  case "${1:-}" in
    --smoke)
      [[ "$#" -eq 1 ]] || fail 'check-cluster --smoke does not accept extra arguments'
      check_ready_nodes
      check_edge_workloads 30s
      ;;
    '')
      # An interrupted earlier run must not satisfy this run's checks.
      delete_validation_services
      trap delete_validation_services EXIT

      check_ready_nodes
      check_edge_workloads 90s
      pass 'three nodes and the edge workloads are Ready'

      check_metallb
      check_ingress_placement
      check_vault_secrets_operator
      check_external_dns_configuration

      kubectl -n stage3-validation rollout status deployment/backend --timeout=180s >/dev/null
      check_private_service_stays_private
      check_service_dns_lifecycle
      check_ingress_dns_and_tls
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
}

main "$@"
