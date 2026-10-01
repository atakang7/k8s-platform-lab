#!/usr/bin/env bash
# End-to-end proof of the whole platform: the host-side validations, then
# policies, Jenkins, the application in this cluster's environment, and its
# metrics and logs. One request with a unique ID is traced from HTTPS through
# the application log file into Elasticsearch.
#
# Runs in two halves:
#   1. On the host: cluster, edge and observability validations.
#   2. With --cluster, through the SSH tunnel: everything in the cluster.
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT

# shellcheck source=../../infra/edge/config.env
source "${ROOT}/infra/edge/config.env"

readonly JENKINS_HOST="jenkins.${DNS_ZONE}"
readonly OBSERVABILITY_HOST="observability.${DNS_ZONE}"

# Set in the cluster half by read_application.
NAMESPACE=''
APPLICATION_HOST=''
DEPLOYMENT=''
REPLICAS=''
REQUEST_ID=''

fail() {
  printf 'FAIL | %s\n' "$1" >&2
  exit 1
}

phase() {
  printf 'WAIT | %s\n' "$1"
}

pass() {
  printf 'PASS | %s\n' "$1"
}

# ---- Host half ----

run_host_validations() {
  phase 'running the cluster, edge and observability validations'

  cd "${ROOT}"
  make cluster-validate
  make edge-validate
  make observability-smoke
}

# ---- Cluster half: policies and Jenkins ----

check_policies() {
  "${ROOT}/policies/bin/smoke" --cluster
}

check_jenkins_secrets() {
  phase 'checking the Jenkins Secrets'

  kubectl -n jenkins get secret jenkins-admin >/dev/null || fail 'Jenkins Secret jenkins-admin is missing'
  kubectl -n jenkins get secret github-creds >/dev/null || fail 'Jenkins Secret github-creds is missing'
  kubectl -n jenkins get secret dockerhub-creds >/dev/null || fail 'Jenkins Secret dockerhub-creds is missing'
}

check_jenkins_placement() {
  local nodes
  local volume_phases

  phase 'checking where Jenkins runs and that its volume is bound'

  kubectl -n jenkins rollout status statefulset/jenkins --timeout=90s >/dev/null

  nodes="$(kubectl -n jenkins get pods \
    --selector app.kubernetes.io/component=jenkins-controller \
    -o jsonpath='{.items[*].spec.nodeName}')"
  if [[ "${nodes}" != node-3 ]]; then
    fail "the Jenkins controller should run once on node-3; runs on: ${nodes}"
  fi

  volume_phases="$(kubectl -n jenkins get pvc -o jsonpath='{.items[*].status.phase}')"
  if [[ "${volume_phases}" != *Bound* ]]; then
    fail 'the Jenkins volume is not Bound'
  fi
}

check_jenkins_endpoint() {
  local ingress_class
  local address

  phase "checking https://${JENKINS_HOST}"

  ingress_class="$(kubectl -n jenkins get ingress jenkins -o jsonpath='{.spec.ingressClassName}')"
  if [[ "${ingress_class}" != nginx ]]; then
    fail 'the Jenkins ingress is missing'
  fi

  address="$(dig +short "@${EDGE_HOST_IP}" "${JENKINS_HOST}" A)"
  if [[ "${address}" != *"${INGRESS_VIP}"* ]]; then
    fail "${JENKINS_HOST} resolves to ${address:-nothing}, not the ingress VIP ${INGRESS_VIP}"
  fi

  if ! curl --noproxy '*' --silent --show-error --fail --location --max-time 15 \
    --output /dev/null "https://${JENKINS_HOST}/login"; then
    fail "https://${JENKINS_HOST}/login does not answer"
  fi
}

# Builds run on agents only; the controller has no executors.
check_jenkins_executors() {
  local admin_user
  local admin_password
  local answer
  local executors

  phase 'checking that the Jenkins controller runs no builds itself'

  admin_user="$(kubectl -n jenkins get secret jenkins-admin \
    -o go-template='{{ index .data "jenkins-admin-user" | base64decode }}')"
  admin_password="$(kubectl -n jenkins get secret jenkins-admin \
    -o go-template='{{ index .data "jenkins-admin-password" | base64decode }}')"

  answer="$(curl --noproxy '*' --silent --show-error --fail --max-time 15 \
    --user "${admin_user}:${admin_password}" \
    "https://${JENKINS_HOST}/api/json?tree=numExecutors")"
  executors="$(jq -r .numExecutors <<< "${answer}")"

  if [[ "${executors}" != 0 ]]; then
    fail "the Jenkins controller has ${executors} executors, not 0"
  fi
}

# ---- Cluster half: the application ----

read_application() {
  local environment

  environment="$("${ROOT}/platform/bin/cluster-environment")"
  NAMESPACE="${environment#* }"

  phase "checking sample-java-app in ${NAMESPACE}"

  kubectl -n "${NAMESPACE}" rollout status deployment/sample-java-app --timeout=90s >/dev/null

  DEPLOYMENT="$(kubectl -n "${NAMESPACE}" get deployment sample-java-app -o json)"
  REPLICAS="$(jq -r .spec.replicas <<< "${DEPLOYMENT}")"
  APPLICATION_HOST="$(kubectl -n "${NAMESPACE}" get ingress sample-java-app -o jsonpath='{.spec.rules[0].host}')"
}

check_application_replicas() {
  local ready

  ready="$(jq -r .status.readyReplicas <<< "${DEPLOYMENT}")"
  if [[ "${REPLICAS}" -lt 1 || "${ready}" != "${REPLICAS}" ]]; then
    fail "sample-java-app has ${ready} of ${REPLICAS} replicas ready"
  fi
}

check_application_image() {
  local image

  image="$(jq -r '.spec.template.spec.containers[] | select(.name == "app") | .image' <<< "${DEPLOYMENT}")"
  if [[ ! "${image}" =~ @sha256:[0-9a-f]{64}$ ]]; then
    fail "sample-java-app image is not pinned by digest: ${image}"
  fi
}

check_application_pod_security() {
  local automount
  local service_links
  local grace_period
  local seccomp
  local pull_policy
  local container_count
  local non_root_count
  local no_escalation_count
  local drop_all_count

  automount="$(jq -r .spec.template.spec.automountServiceAccountToken <<< "${DEPLOYMENT}")"
  service_links="$(jq -r .spec.template.spec.enableServiceLinks <<< "${DEPLOYMENT}")"
  grace_period="$(jq -r .spec.template.spec.terminationGracePeriodSeconds <<< "${DEPLOYMENT}")"
  seccomp="$(jq -r .spec.template.spec.securityContext.seccompProfile.type <<< "${DEPLOYMENT}")"
  pull_policy="$(jq -r '.spec.template.spec.containers[] | select(.name == "app") | .imagePullPolicy' <<< "${DEPLOYMENT}")"

  container_count="$(jq -r '.spec.template.spec.containers | length' <<< "${DEPLOYMENT}")"
  non_root_count="$(jq -r '[.spec.template.spec.containers[] | select(.securityContext.runAsNonRoot == true)] | length' <<< "${DEPLOYMENT}")"
  no_escalation_count="$(jq -r '[.spec.template.spec.containers[] | select(.securityContext.allowPrivilegeEscalation == false)] | length' <<< "${DEPLOYMENT}")"
  drop_all_count="$(jq -r '[.spec.template.spec.containers[] | select(.securityContext.capabilities.drop | index("ALL"))] | length' <<< "${DEPLOYMENT}")"

  if [[ "${automount}" != false ]]; then
    fail 'sample-java-app Pods mount a ServiceAccount token'
  fi
  if [[ "${service_links}" != false ]]; then
    fail 'sample-java-app Pods get Service environment variables (enableServiceLinks)'
  fi
  if [[ "${grace_period}" != 30 ]]; then
    fail "sample-java-app termination grace period is ${grace_period}s, not 30s"
  fi
  if [[ "${seccomp}" != RuntimeDefault ]]; then
    fail "sample-java-app seccomp profile is ${seccomp}, not RuntimeDefault"
  fi
  if [[ "${pull_policy}" != IfNotPresent ]]; then
    fail "sample-java-app pull policy is ${pull_policy}, not IfNotPresent"
  fi
  if [[ "${non_root_count}" != "${container_count}" ]]; then
    fail 'a sample-java-app container may run as root'
  fi
  if [[ "${no_escalation_count}" != "${container_count}" ]]; then
    fail 'a sample-java-app container allows privilege escalation'
  fi
  if [[ "${drop_all_count}" != "${container_count}" ]]; then
    fail 'a sample-java-app container keeps Linux capabilities'
  fi
}

# A budget must leave a Pod evictable, or no node can be drained; a single
# replica needs none.
check_application_disruption_budget() {
  local min_available

  if [[ "${REPLICAS}" -eq 1 ]]; then
    if kubectl -n "${NAMESPACE}" get poddisruptionbudget sample-java-app >/dev/null 2>&1; then
      fail 'single-replica sample-java-app has a PodDisruptionBudget that blocks node drains'
    fi
    return
  fi

  min_available="$(kubectl -n "${NAMESPACE}" get poddisruptionbudget sample-java-app -o jsonpath='{.spec.minAvailable}')"
  if [[ "${min_available}" -ge "${REPLICAS}" ]]; then
    fail "sample-java-app PodDisruptionBudget (minAvailable ${min_available}) leaves no Pod evictable"
  fi
}

check_application_placement() {
  local nodes
  local -a node_list

  nodes="$(kubectl -n "${NAMESPACE}" get pods \
    --selector app.kubernetes.io/name=sample-java-app \
    --field-selector status.phase=Running \
    -o jsonpath='{.items[*].spec.nodeName}')"
  read -ra node_list <<< "${nodes}"

  if [[ "${#node_list[@]}" != "${REPLICAS}" ]]; then
    fail "${#node_list[@]} of ${REPLICAS} sample-java-app replicas are running"
  fi
  if [[ "${REPLICAS}" -gt 1 && ( " ${nodes} " != *' node-2 '* || " ${nodes} " != *' node-3 '* ) ]]; then
    fail "sample-java-app replicas should be spread over node-2 and node-3; run on: ${nodes}"
  fi
}

check_application_request() {
  local address
  local response

  phase "sending request ${REQUEST_ID} to https://${APPLICATION_HOST}"

  if [[ "${APPLICATION_HOST}" != *".${DNS_ZONE}" ]]; then
    fail "sample-java-app host ${APPLICATION_HOST} is outside ${DNS_ZONE}"
  fi

  address="$(dig +short "@${EDGE_HOST_IP}" "${APPLICATION_HOST}" A)"
  if [[ "${address}" != *"${INGRESS_VIP}"* ]]; then
    fail "${APPLICATION_HOST} resolves to ${address:-nothing}, not the ingress VIP ${INGRESS_VIP}"
  fi

  response="$(curl --noproxy '*' --silent --show-error --fail --get \
    --data-urlencode "val=${REQUEST_ID}" \
    "https://${APPLICATION_HOST}/api/foos")"
  if [[ "${response}" != "QueryStringValue: ${REQUEST_ID}" ]]; then
    fail "sample-java-app answered: ${response}"
  fi
}

# The application writes request logs to a file asynchronously; one of the
# replicas must have it within 15 seconds.
check_application_file_log() {
  local pods
  local pod

  pods="$(kubectl -n "${NAMESPACE}" get pods \
    --selector app.kubernetes.io/name=sample-java-app \
    -o jsonpath='{.items[*].metadata.name}')"

  for _ in {1..15}; do
    for pod in ${pods}; do
      if kubectl -n "${NAMESPACE}" exec "${pod}" -c app -- \
        grep -Fq "${REQUEST_ID}" /var/log/app/app.log; then
        return
      fi
    done
    sleep 1
  done

  fail "request ${REQUEST_ID} did not reach the application log file"
}

# ---- Cluster half: observability ----

check_application_metrics() {
  local up
  local up_value
  local heap
  local heap_series

  phase 'checking the application metrics in Prometheus'

  kubectl -n "${NAMESPACE}" get servicemonitor sample-java-app >/dev/null ||
    fail 'the sample-java-app ServiceMonitor is missing'

  up="$(curl --noproxy '*' --silent --show-error --fail --get \
    --data-urlencode 'query=up{service="sample-java-app"}' \
    "https://${OBSERVABILITY_HOST}/prometheus/api/v1/query")"
  up_value="$(jq -r '.data.result[0].value[1] // "none"' <<< "${up}")"
  if [[ "${up_value}" != 1 ]]; then
    fail "Prometheus does not see sample-java-app as up (up = ${up_value})"
  fi

  heap="$(curl --noproxy '*' --silent --show-error --fail --get \
    --data-urlencode 'query=jvm_memory_used_bytes{area="heap"}' \
    "https://${OBSERVABILITY_HOST}/prometheus/api/v1/query")"
  heap_series="$(jq -r '.data.result | length' <<< "${heap}")"
  if [[ "${heap_series}" -eq 0 ]]; then
    fail 'Prometheus has no JVM heap metric from sample-java-app'
  fi
}

check_dashboards() {
  local values
  local log_datasource

  phase 'checking the Grafana dashboards and log datasource'

  kubectl -n observability get configmap lab-cluster-dashboard >/dev/null ||
    fail 'the Grafana cluster dashboard is missing'
  kubectl -n observability get configmap lab-logs-dashboard >/dev/null ||
    fail 'the Grafana logs dashboard is missing'

  values="$(helm -n observability get values observability -o json)"
  log_datasource="$(jq -r '.grafana.additionalDataSources[] | select(.uid == "application-logs") | .database' <<< "${values}")"
  if [[ "${log_datasource}" != app-logs ]]; then
    fail 'Grafana has no application-logs datasource on the app-logs index'
  fi
}

# Fluent Bit ships the application log file to Elasticsearch.
check_log_delivery() {
  local search
  local hits

  phase "checking that request ${REQUEST_ID} reached Elasticsearch"

  for _ in {1..30}; do
    search="$(kubectl get --raw \
      "/api/v1/namespaces/observability/services/http:logs-es-http:9200/proxy/app-logs/_search?q=log:${REQUEST_ID}" \
      2>/dev/null || true)"
    if [[ -n "${search}" ]]; then
      hits="$(jq -r '.hits.total.value // 0' <<< "${search}")"
      if [[ "${hits}" -gt 0 ]]; then
        return
      fi
    fi
    sleep 2
  done

  fail "request ${REQUEST_ID} did not reach Elasticsearch"
}

main() {
  case "${1:-}" in
    '')
      [[ "$#" -eq 0 ]] || fail 'e2e validation does not accept arguments'
      run_host_validations
      exec "${ROOT}/infra/edge/lib/with-kubeconfig.sh" "$0" --cluster
      ;;
    --cluster)
      [[ "$#" -eq 1 ]] || fail 'e2e validation --cluster does not accept extra arguments'
      REQUEST_ID="e2e-$(date +%s)-$$"

      check_policies
      check_jenkins_secrets
      check_jenkins_placement
      check_jenkins_endpoint
      check_jenkins_executors
      pass 'Jenkins secrets, placement, HTTPS and executor policy'

      read_application
      check_application_replicas
      check_application_image
      check_application_pod_security
      check_application_disruption_budget
      check_application_placement
      check_application_request
      check_application_file_log
      pass 'application replicas, image, security, disruption budget, placement, HTTPS and file log'

      check_application_metrics
      check_dashboards
      check_log_delivery
      pass 'application metrics, dashboards and log delivery'

      pass 'the whole platform is validated end to end'
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
}

main "$@"
