#!/usr/bin/env bash
set -Eeuo pipefail

readonly repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly application_directory="${repository_root}/app"
readonly query_value=container-validation
readonly expected_response="QueryStringValue: ${query_value}"

container_name=''
response_file=''

pass() {
  printf 'PASS | %s\n' "$1"
}

fail() {
  printf 'FAIL | %s\n' "$1" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 ||
    fail "required command is unavailable: $1"
}

cleanup() {
  if [[ -n "${container_name}" ]]; then
    docker rm --force "${container_name}" >/dev/null 2>&1 || true
  fi
  [[ -z "${response_file}" ]] || rm -f -- "${response_file}"
}

resolve_git_sha() {
  if [[ -n "${STAGE2_GIT_SHA:-}" ]]; then
    printf '%s\n' "${STAGE2_GIT_SHA}"
    return
  fi

  git -C "${repository_root}" rev-parse --verify HEAD 2>/dev/null ||
    fail 'no Git commit found; commit the project or set STAGE2_GIT_SHA'
}

resolve_source_repository() {
  if [[ -n "${STAGE2_SOURCE_REPOSITORY:-}" ]]; then
    printf '%s\n' "${STAGE2_SOURCE_REPOSITORY}"
    return
  fi

  git -C "${repository_root}" remote get-url origin 2>/dev/null ||
    fail 'no Git origin found; set STAGE2_SOURCE_REPOSITORY'
}

validate_inputs() {
  local git_sha="$1" source_repository="$2"

  [[ "${git_sha}" =~ ^[0-9a-f]{7,40}$ ]] ||
    fail 'Git SHA must contain 7 to 40 hexadecimal characters'

  [[ "${source_repository}" != 'https://github.com/SampleJavaApp/app' ]] ||
    fail 'OCI source must identify the submission repository'

  [[ "${source_repository}" =~ ^(https://|ssh://|git@|file://).+ ]] ||
    fail 'submission repository must be an HTTPS, SSH, or file Git URL'
}

build_images() {
  local git_sha="$1" source_repository="$2" image_reference="$3"
  local build_reference="container-validation-build:${git_sha}"

  docker build \
    --target build \
    --build-arg "SOURCE_REVISION=${git_sha}" \
    --tag "${build_reference}" \
    "${application_directory}"
  pass 'application build stage completed'

  docker build \
    --build-arg "SOURCE_REPOSITORY=${source_repository}" \
    --build-arg "SOURCE_REVISION=${git_sha}" \
    --tag "${image_reference}" \
    "${application_directory}"
  pass "runtime image built as ${image_reference}"
}

validate_oci_labels() {
  local image_reference="$1" git_sha="$2" source_repository="$3"
  local revision_label source_label

  revision_label="$(docker image inspect \
    --format '{{ index .Config.Labels "org.opencontainers.image.revision" }}' \
    "${image_reference}")"
  [[ "${revision_label}" == "${git_sha}" ]] ||
    fail 'OCI revision label does not match the supplied Git SHA'

  source_label="$(docker image inspect \
    --format '{{ index .Config.Labels "org.opencontainers.image.source" }}' \
    "${image_reference}")"
  [[ "${source_label}" == "${source_repository}" ]] ||
    fail 'OCI source label does not match the submission repository'

  pass 'OCI source and revision labels match the build inputs'
}

start_application() {
  local image_reference="$1" git_sha="$2"
  local host_port

  container_name="container-validation-${git_sha:0:12}-$$"
  docker run \
    --detach \
    --name "${container_name}" \
    --publish 127.0.0.1::9001 \
    "${image_reference}" >/dev/null

  host_port="$(docker port "${container_name}" 9001/tcp | awk -F: 'NR == 1 { print $NF }')"
  [[ "${host_port}" =~ ^[0-9]+$ ]] ||
    fail 'container did not publish application port 9001'

  printf '%s\n' "${host_port}"
}

wait_for_application() {
  local host_port="$1"
  local application_url="http://127.0.0.1:${host_port}/api/foos"

  for _ in {1..60}; do
    if curl --silent --show-error --fail \
      --get \
      --data-urlencode "val=${query_value}" \
      --output "${response_file}" \
      "${application_url}" 2>/dev/null; then
      [[ "$(<"${response_file}")" == "${expected_response}" ]] ||
        fail 'HTTP response did not contain the supplied query parameter'
      pass 'container is ready and echoes the query parameter'
      return
    fi

    if [[ "$(docker inspect --format '{{.State.Running}}' "${container_name}")" != true ]]; then
      docker logs "${container_name}" >&2
      fail 'container exited before the application became ready'
    fi

    sleep 1
  done

  fail 'HTTP endpoint did not become ready within 60 seconds'
}

validate_application_log() {
  for _ in {1..10}; do
    if docker exec "${container_name}" \
      grep --fixed-strings --quiet "${expected_response}" /var/log/app/app.log; then
      pass 'application file log contains the request'
      return
    fi
    sleep 1
  done

  fail 'application file log did not contain the request'
}

validate_metrics() {
  local host_port="$1"

  curl --silent --show-error --fail \
    --output "${response_file}" \
    "http://127.0.0.1:${host_port}/actuator/prometheus" ||
    fail 'Prometheus endpoint is unavailable'

  grep --fixed-strings --quiet 'http_server_requests_seconds_count' "${response_file}" ||
    fail 'Prometheus endpoint does not expose HTTP request metrics'

  pass 'Prometheus endpoint exposes HTTP request metrics'
}

validate_runtime_image() {
  local image_reference="$1"
  local runtime_uid

  runtime_uid="$(docker exec "${container_name}" sh -c 'id -u')"
  [[ "${runtime_uid}" =~ ^[0-9]+$ && "${runtime_uid}" != 0 ]] ||
    fail 'container process is running as root'

  docker exec "${container_name}" sh -c '
    ! command -v mvn >/dev/null 2>&1 &&
    ! command -v javac >/dev/null 2>&1 &&
    ! test -e /app/src &&
    ! test -e /app/pom.xml &&
    ! test -e /app/mvnw
  ' || fail 'runtime image contains build tooling or source artifacts'

  docker image inspect "${image_reference}" >/dev/null
  pass "runtime image is non-root and contains no build source/tooling"
}

push_if_requested() {
  local image_reference="$1" image_repository="$2"

  if [[ "${STAGE2_PUSH:-false}" != true ]]; then
    printf 'SKIP | registry push not requested; set STAGE2_PUSH=true and DOCKERHUB_REPOSITORY\n'
    return
  fi

  [[ -n "${DOCKERHUB_REPOSITORY:-}" ]] ||
    fail 'DOCKERHUB_REPOSITORY is required when STAGE2_PUSH=true'

  docker push "${image_reference}"

  local registry_details registry_digest
  registry_details="$(docker buildx imagetools inspect "${image_reference}")"
  registry_digest="$(awk '/^Digest:/ { print $2; exit }' <<<"${registry_details}")"
  [[ "${registry_digest}" =~ ^sha256:[0-9a-f]{64}$ ]] ||
    fail 'registry did not return an immutable SHA256 digest'

  pass "image pushed as ${image_repository}@${registry_digest}"
}

main() {
  local git_sha source_repository image_repository image_reference host_port

  for command_name in curl docker git; do
    require_command "${command_name}"
  done
  docker info >/dev/null 2>&1 ||
    fail 'Docker daemon is unavailable'

  response_file="$(mktemp)"
  trap cleanup EXIT

  git_sha="$(resolve_git_sha)"
  git_sha="${git_sha,,}"
  source_repository="$(resolve_source_repository)"
  validate_inputs "${git_sha}" "${source_repository}"

  image_repository="${DOCKERHUB_REPOSITORY:-sample-java-app}"
  image_reference="${image_repository}:${git_sha}"

  build_images "${git_sha}" "${source_repository}" "${image_reference}"
  validate_oci_labels "${image_reference}" "${git_sha}" "${source_repository}"
  host_port="$(start_application "${image_reference}" "${git_sha}")"
  wait_for_application "${host_port}"
  validate_application_log
  validate_metrics "${host_port}"
  validate_runtime_image "${image_reference}"
  push_if_requested "${image_reference}" "${image_repository}"

  pass 'application container validation complete'
}

main "$@"
