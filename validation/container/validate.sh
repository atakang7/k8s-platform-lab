#!/usr/bin/env bash
# Builds the application image and runs it locally: it must answer requests,
# report healthy, expose metrics, and run as a non-root user.
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT
readonly IMAGE=sample-java-app:container-validation
readonly CONTAINER=sample-java-app-container-validation
readonly URL=http://127.0.0.1:19001

pass() {
  printf 'PASS | %s\n' "$1"
}

fail() {
  printf 'FAIL | %s\n' "$1" >&2
  exit 1
}

remove_container() {
  docker rm --force "${CONTAINER}" >/dev/null 2>&1 || true
}

# The Dockerfile runs the unit tests while it builds.
build_image() {
  printf 'WAIT | building the image (runs the unit tests)\n'
  docker build --tag "${IMAGE}" "${ROOT}/app"
  pass 'image built and unit tests passed'
}

start_container() {
  remove_container
  docker run --detach --name "${CONTAINER}" --publish 127.0.0.1:19001:9001 "${IMAGE}" >/dev/null
}

check_request() {
  local response

  for _ in {1..60}; do
    if response="$(curl --silent --fail --get --data-urlencode 'val=container-check' "${URL}/api/foos")"; then
      if [[ "${response}" != 'QueryStringValue: container-check' ]]; then
        fail "the app answered: ${response}"
      fi
      pass 'the app answers requests'
      return
    fi
    sleep 1
  done

  docker logs "${CONTAINER}" >&2
  fail 'the app did not answer within 60 seconds'
}

check_health_and_metrics() {
  local health

  health="$(curl --silent --show-error --fail "${URL}/actuator/health/readiness")"
  if [[ "${health}" != *'"status":"UP"'* ]]; then
    fail "readiness is not UP: ${health}"
  fi

  curl --silent --show-error --fail --output /dev/null "${URL}/actuator/prometheus" ||
    fail 'the Prometheus metrics endpoint does not answer'

  pass 'the app reports ready and exposes metrics'
}

check_non_root() {
  local user_id

  user_id="$(docker exec "${CONTAINER}" id -u)"
  if [[ "${user_id}" == 0 ]]; then
    fail 'the app runs as root'
  fi
  pass "the app runs as user ${user_id}, not root"
}

main() {
  [[ "$#" -eq 0 ]] || fail 'container validation does not accept arguments'

  docker info >/dev/null 2>&1 || fail 'Docker is not running'
  trap remove_container EXIT

  build_image
  start_container
  check_request
  check_health_and_metrics
  check_non_root

  pass 'application container validation complete'
}

main "$@"
