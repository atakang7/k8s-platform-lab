#!/usr/bin/env bash
set -Eeuo pipefail

repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly repository_root
readonly application_directory="${repository_root}/app"
readonly query_value="stage2-validation"
readonly expected_response="QueryStringValue: ${query_value}"

container_name=""
response_file="$(mktemp)"

cleanup() {
  if [[ -n "${container_name}" ]]; then
    docker rm --force "${container_name}" >/dev/null 2>&1 || true
  fi
  rm -f "${response_file}"
}
trap cleanup EXIT

pass() {
  printf 'PASS | %s\n' "$1"
}

fail() {
  printf 'FAIL | %s\n' "$1" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command is unavailable: $1"
}

resolve_git_sha() {
  if [[ -n "${STAGE2_GIT_SHA:-}" ]]; then
    printf '%s' "${STAGE2_GIT_SHA}"
    return
  fi

  git -C "${repository_root}" rev-parse --verify HEAD 2>/dev/null ||
    fail "no Git commit found; commit the project or set STAGE2_GIT_SHA"
}

resolve_source_repository() {
  if [[ -n "${STAGE2_SOURCE_REPOSITORY:-}" ]]; then
    printf '%s' "${STAGE2_SOURCE_REPOSITORY}"
    return
  fi

  git -C "${repository_root}" remote get-url origin 2>/dev/null ||
    fail "no Git origin found; set STAGE2_SOURCE_REPOSITORY to the submission repository URL"
}

for command_name in curl docker git; do
  require_command "${command_name}"
done
docker info >/dev/null 2>&1 || fail "Docker daemon is unavailable"

git_sha="$(resolve_git_sha)"
git_sha="${git_sha,,}"
[[ "${git_sha}" =~ ^[0-9a-f]{7,40}$ ]] || fail "Git SHA must contain 7 to 40 hexadecimal characters"
pass "resolved source revision ${git_sha}"

source_repository="$(resolve_source_repository)"
[[ "${source_repository}" != "https://github.com/SampleJavaApp/app" ]] ||
  fail "OCI source must identify the submission repository, not the upstream sample"
[[ "${source_repository}" =~ ^(https://|ssh://|git@|file://).+ ]] ||
  fail "submission repository must be an HTTPS, SSH, or file Git URL"
pass "resolved submission repository ${source_repository}"

readonly image_repository="${DOCKERHUB_REPOSITORY:-sample-java-app}"
readonly image_reference="${image_repository}:${git_sha}"
readonly build_reference="stage2-build:${git_sha}"

docker build \
  --target build \
  --build-arg "SOURCE_REVISION=${git_sha}" \
  --tag "${build_reference}" \
  "${application_directory}"
pass "application builds successfully with its Maven Wrapper"

docker build \
  --build-arg "SOURCE_REPOSITORY=${source_repository}" \
  --build-arg "SOURCE_REVISION=${git_sha}" \
  --tag "${image_reference}" \
  "${application_directory}"
pass "runtime image builds as ${image_reference}"

revision_label="$(docker image inspect \
  --format '{{ index .Config.Labels "org.opencontainers.image.revision" }}' \
  "${image_reference}")"
[[ "${revision_label}" == "${git_sha}" ]] ||
  fail "OCI revision label does not match the supplied Git SHA"
pass "OCI revision label contains the supplied Git SHA"

source_label="$(docker image inspect \
  --format '{{ index .Config.Labels "org.opencontainers.image.source" }}' \
  "${image_reference}")"
[[ "${source_label}" == "${source_repository}" ]] ||
  fail "OCI source label does not match the submission repository"
pass "OCI source label identifies the submission repository"

container_name="stage2-${git_sha:0:12}-$$"
docker run \
  --detach \
  --name "${container_name}" \
  --publish 127.0.0.1::9001 \
  "${image_reference}" >/dev/null

host_port="$(docker port "${container_name}" 9001/tcp | awk -F: 'NR == 1 { print $NF }')"
[[ "${host_port}" =~ ^[0-9]+$ ]] || fail "container did not publish application port 9001"

application_url="http://127.0.0.1:${host_port}/api/foos"
application_ready=false
for _ in $(seq 1 60); do
  if curl --silent --show-error --fail \
    --get --data-urlencode "val=${query_value}" \
    --output "${response_file}" "${application_url}" 2>/dev/null; then
    application_ready=true
    break
  fi
  if [[ "$(docker inspect --format '{{.State.Running}}' "${container_name}")" != "true" ]]; then
    docker logs "${container_name}" >&2
    fail "container exited before the application became ready"
  fi
  sleep 1
done
[[ "${application_ready}" == "true" ]] || fail "HTTP endpoint did not become ready within 60 seconds"
pass "container starts and the HTTP endpoint responds"

actual_response="$(<"${response_file}")"
[[ "${actual_response}" == "${expected_response}" ]] ||
  fail "HTTP response did not contain the supplied query parameter"
pass "HTTP response contains the supplied query parameter"

container_output="$(docker logs "${container_name}" 2>&1)"
grep --fixed-strings --quiet "${expected_response}" <<<"${container_output}" ||
  fail "application output did not contain the supplied query parameter"
pass "application output contains the supplied query parameter"

runtime_uid="$(docker exec "${container_name}" sh -c 'id -u')"
[[ "${runtime_uid}" =~ ^[0-9]+$ && "${runtime_uid}" != "0" ]] ||
  fail "container process is running as root"
pass "container process runs as non-root UID ${runtime_uid}"

docker exec "${container_name}" sh -c '
  ! command -v mvn >/dev/null 2>&1 &&
  ! command -v javac >/dev/null 2>&1 &&
  ! test -e /app/src &&
  ! test -e /app/pom.xml &&
  ! test -e /app/mvnw
' || fail "runtime image contains build tooling or source artifacts"
pass "runtime image contains no Maven, JDK compiler, or application source tree"

docker image inspect "${image_reference}" >/dev/null
pass "image is tagged with the Git SHA"

if [[ "${STAGE2_PUSH:-false}" == "true" ]]; then
  [[ -n "${DOCKERHUB_REPOSITORY:-}" ]] ||
    fail "DOCKERHUB_REPOSITORY is required when STAGE2_PUSH=true"
  require_command docker
  docker push "${image_reference}"

  registry_details="$(docker buildx imagetools inspect "${image_reference}")"
  registry_digest="$(awk '/^Digest:/ { print $2; exit }' <<<"${registry_details}")"
  [[ "${registry_digest}" =~ ^sha256:[0-9a-f]{64}$ ]] ||
    fail "registry did not return an immutable SHA256 digest"
  pass "image pushed; immutable artifact is ${image_repository}@${registry_digest}"
else
  printf 'SKIP | registry push was not requested; set STAGE2_PUSH=true and DOCKERHUB_REPOSITORY\n'
fi

pass "Stage 2 application and container validation complete"
