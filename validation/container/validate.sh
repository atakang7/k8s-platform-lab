#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT
readonly APPLICATION_DIRECTORY="${ROOT}/app"
readonly QUERY_VALUE=container-validation
readonly EXPECTED_RESPONSE="QueryStringValue: ${QUERY_VALUE}"

CONTAINER_NAME=''
# start_application sets this: capturing its stdout would run it in a subshell,
# losing CONTAINER_NAME and leaving every later docker call without a container.
HOST_PORT=''
RESPONSE_FILE=''

pass() {
  printf 'PASS | %s\n' "$1"
}

fail() {
  printf 'FAIL | %s\n' "$1" >&2
  exit 1
}

require_command() {
  local command_name="$1"

  command -v "${command_name}" >/dev/null 2>&1 ||
    fail "required command is unavailable: ${command_name}"
}

cleanup() {
  if [[ -n "${CONTAINER_NAME}" ]]; then
    docker rm --force "${CONTAINER_NAME}" >/dev/null 2>&1 || true
  fi

  if [[ -n "${RESPONSE_FILE}" ]]; then
    rm -f -- "${RESPONSE_FILE}"
  fi
}

resolve_git_sha() {
  if [[ -n "${STAGE2_GIT_SHA:-}" ]]; then
    printf '%s\n' "${STAGE2_GIT_SHA}"
    return
  fi

  git -C "${ROOT}" rev-parse --verify HEAD 2>/dev/null ||
    fail 'no Git commit found; commit the project or set STAGE2_GIT_SHA'
}

resolve_source_repository() {
  if [[ -n "${STAGE2_SOURCE_REPOSITORY:-}" ]]; then
    printf '%s\n' "${STAGE2_SOURCE_REPOSITORY}"
    return
  fi

  git -C "${ROOT}" remote get-url origin 2>/dev/null ||
    fail 'no Git origin found; set STAGE2_SOURCE_REPOSITORY'
}

validate_inputs() {
  local git_sha="$1"
  local source_repository="$2"
  local push_mode="${STAGE2_PUSH:-false}"

  [[ "${git_sha}" =~ ^[0-9a-f]{7,40}$ ]] ||
    fail 'Git SHA must contain 7 to 40 lowercase hexadecimal characters'

  [[ "${source_repository}" != 'https://github.com/SampleJavaApp/app' ]] ||
    fail 'OCI source must identify the submission repository'

  [[ "${source_repository}" =~ ^(https://|ssh://|git@|file://).+ ]] ||
    fail 'submission repository must be an HTTPS, SSH, or file Git URL'

  case "${push_mode}" in
    true|false)
      ;;
    *)
      fail 'STAGE2_PUSH must be true or false'
      ;;
  esac

  if [[ "${push_mode}" == true && -z "${DOCKERHUB_REPOSITORY:-}" ]]; then
    fail 'DOCKERHUB_REPOSITORY is required when STAGE2_PUSH=true'
  fi
}

build_images() {
  local git_sha="$1"
  local source_repository="$2"
  local image_reference="$3"
  local build_reference="container-validation-build:${git_sha}"

  printf 'WAIT | building application test stage\n'
  docker build \
    --target build \
    --build-arg "SOURCE_REVISION=${git_sha}" \
    --tag "${build_reference}" \
    "${APPLICATION_DIRECTORY}"
  pass 'application build stage completed'

  printf 'WAIT | building runtime image\n'
  docker build \
    --build-arg "SOURCE_REPOSITORY=${source_repository}" \
    --build-arg "SOURCE_REVISION=${git_sha}" \
    --tag "${image_reference}" \
    "${APPLICATION_DIRECTORY}"
  pass "runtime image built as ${image_reference}"
}

validate_oci_labels() {
  local image_reference="$1"
  local git_sha="$2"
  local source_repository="$3"
  local revision_label
  local source_label

  revision_label="$(
    docker image inspect \
      --format '{{ index .Config.Labels "org.opencontainers.image.revision" }}' \
      "${image_reference}"
  )"
  [[ "${revision_label}" == "${git_sha}" ]] ||
    fail 'OCI revision label does not match the supplied Git SHA'

  source_label="$(
    docker image inspect \
      --format '{{ index .Config.Labels "org.opencontainers.image.source" }}' \
      "${image_reference}"
  )"
  [[ "${source_label}" == "${source_repository}" ]] ||
    fail 'OCI source label does not match the submission repository'

  pass 'OCI source and revision labels match the build inputs'
}

start_application() {
  local image_reference="$1"
  local git_sha="$2"

  CONTAINER_NAME="container-validation-${git_sha:0:12}-$$"

  docker run \
    --detach \
    --name "${CONTAINER_NAME}" \
    --publish 127.0.0.1::9001 \
    "${image_reference}" >/dev/null

  HOST_PORT="$(
    docker port "${CONTAINER_NAME}" 9001/tcp |
      awk -F: 'NR == 1 { print $NF }'
  )"

  [[ "${HOST_PORT}" =~ ^[0-9]+$ ]] ||
    fail 'container did not publish application port 9001'
}

wait_for_application() {
  local host_port="$1"
  local application_url="http://127.0.0.1:${host_port}/api/foos"

  for _ in {1..60}; do
    if curl \
      --silent \
      --show-error \
      --fail \
      --get \
      --data-urlencode "val=${QUERY_VALUE}" \
      --output "${RESPONSE_FILE}" \
      "${application_url}" 2>/dev/null; then
      [[ "$(<"${RESPONSE_FILE}")" == "${EXPECTED_RESPONSE}" ]] ||
        fail 'HTTP response did not contain the supplied query parameter'

      pass 'container is ready and echoes the query parameter'
      return
    fi

    if [[ "$(docker inspect --format '{{.State.Running}}' "${CONTAINER_NAME}")" != true ]]; then
      docker logs "${CONTAINER_NAME}" >&2
      fail 'container exited before the application became ready'
    fi

    sleep 1
  done

  fail 'HTTP endpoint did not become ready within 60 seconds'
}

validate_health_endpoints() {
  local host_port="$1"
  local endpoint

  for endpoint in liveness readiness; do
    curl \
      --silent \
      --show-error \
      --fail \
      --output "${RESPONSE_FILE}" \
      "http://127.0.0.1:${host_port}/actuator/health/${endpoint}" ||
      fail "Actuator ${endpoint} endpoint is unavailable"

    grep --fixed-strings --quiet '"status":"UP"' "${RESPONSE_FILE}" ||
      fail "Actuator ${endpoint} endpoint did not report UP"
  done

  pass 'Actuator liveness and readiness endpoints report UP'
}

validate_application_log() {

  for _ in {1..10}; do
    if docker exec "${CONTAINER_NAME}" \
      grep --fixed-strings --quiet "${EXPECTED_RESPONSE}" /var/log/app/app.log; then
      pass 'application file log contains the request'
      # stdout keeps WARN and above only; an INFO request line there means the
      # app pays the stdout cost again.
      if grep --fixed-strings --quiet "${EXPECTED_RESPONSE}" <<<"$(docker logs "${CONTAINER_NAME}" 2>&1)"; then
        fail 'request log line was also written to stdout'
      fi
      pass 'request log line stays off stdout'
      return
    fi
    sleep 1
  done

  fail 'application file log did not contain the request'
}

validate_metrics() {
  local host_port="$1"

  curl \
    --silent \
    --show-error \
    --fail \
    --output "${RESPONSE_FILE}" \
    "http://127.0.0.1:${host_port}/actuator/prometheus" ||
    fail 'Prometheus endpoint is unavailable'

  grep --fixed-strings --quiet \
    'http_server_requests_seconds_count' "${RESPONSE_FILE}" ||
    fail 'Prometheus endpoint does not expose HTTP request metrics'

  pass 'Prometheus endpoint exposes HTTP request metrics'
}

validate_runtime_image() {
  local runtime_uid

  runtime_uid="$(docker exec "${CONTAINER_NAME}" id -u)"
  [[ "${runtime_uid}" =~ ^[0-9]+$ && "${runtime_uid}" != 0 ]] ||
    fail 'container process is running as root'

  docker exec "${CONTAINER_NAME}" sh -c '
    ! command -v mvn >/dev/null 2>&1 &&
    ! command -v javac >/dev/null 2>&1 &&
    ! test -e /app/src &&
    ! test -e /app/pom.xml &&
    ! test -e /app/mvnw
  ' || fail 'runtime image contains build tooling or source artifacts'

  pass 'runtime image is non-root and contains no build source/tooling'
}

push_if_requested() {
  local image_reference="$1"
  local image_repository="$2"
  local registry_details
  local registry_digest

  if [[ "${STAGE2_PUSH:-false}" == false ]]; then
    printf 'SKIP | registry push not requested; set STAGE2_PUSH=true and DOCKERHUB_REPOSITORY\n'
    return
  fi

  docker push "${image_reference}"

  registry_details="$(docker buildx imagetools inspect "${image_reference}")"
  registry_digest="$(
    awk '/^Digest:/ { print $2; exit }' <<< "${registry_details}"
  )"

  [[ "${registry_digest}" =~ ^sha256:[0-9a-f]{64}$ ]] ||
    fail 'registry did not return an immutable SHA256 digest'

  pass "image pushed as ${image_repository}@${registry_digest}"
}

main() {
  local command_name
  local git_sha
  local source_repository
  local image_repository
  local image_reference

  [[ "$#" -eq 0 ]] || fail 'container validation does not accept arguments'

  for command_name in curl docker git; do
    require_command "${command_name}"
  done

  docker info >/dev/null 2>&1 ||
    fail 'Docker daemon is unavailable'

  RESPONSE_FILE="$(mktemp)"
  trap cleanup EXIT

  git_sha="$(resolve_git_sha)"
  git_sha="${git_sha,,}"
  source_repository="$(resolve_source_repository)"
  validate_inputs "${git_sha}" "${source_repository}"

  image_repository="${DOCKERHUB_REPOSITORY:-sample-java-app}"
  image_reference="${image_repository}:${git_sha}"

  build_images "${git_sha}" "${source_repository}" "${image_reference}"
  validate_oci_labels "${image_reference}" "${git_sha}" "${source_repository}"

  start_application "${image_reference}" "${git_sha}"
  wait_for_application "${HOST_PORT}"
  validate_health_endpoints "${HOST_PORT}"
  validate_application_log
  validate_metrics "${HOST_PORT}"
  validate_runtime_image
  push_if_requested "${image_reference}" "${image_repository}"

  pass 'application container validation complete'
}

main "$@"
