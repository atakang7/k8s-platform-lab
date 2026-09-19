#!/usr/bin/env bash
# Builds and publishes the Jenkins CI/CD agent image, resolves the registry
# digest, and pins that digest in JCasC. Commit the JCasC change and run
# `make jenkins-up` afterwards.
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT
readonly REPOSITORY="${CI_AGENT_REPOSITORY:-docker.io/atakangul/lab-ci-agent}"
readonly DOCKERFILE=delivery/jenkins/ci-agent.Dockerfile
readonly BUILD_CONTEXT=delivery/jenkins
readonly JCASC=platform/jenkins/jcasc/jenkins.yaml

fail() {
  printf 'FAIL | %s\n' "$1" >&2
  exit 1
}

verify_source_is_committed() {
  # The build is traceable to Git only when the Dockerfile being built matches
  # HEAD. External package repositories can still change between rebuilds; the
  # registry digest pinned into JCasC remains the runtime source of truth.
  git diff --quiet HEAD -- "${DOCKERFILE}" ||
    fail "${DOCKERFILE} has uncommitted changes; commit it before building"
}

build_image() {
  local tag="$1"

  printf 'WAIT | building %s\n' "${tag}"
  # The Dockerfile copies nothing, so its own directory is the complete build
  # context required by the recipe.
  docker build \
    --pull \
    --file "${DOCKERFILE}" \
    --tag "${tag}" \
    "${BUILD_CONTEXT}"
}

push_image() {
  local tag="$1"

  printf 'WAIT | pushing %s\n' "${tag}"
  docker push "${tag}"
}

resolve_registry_digest() {
  local tag="$1"
  local digest

  # Docker records Docker Hub RepoDigests without the docker.io/ prefix.
  digest="$(docker image inspect \
    --format '{{range .RepoDigests}}{{println .}}{{end}}' \
    "${tag}" |
    sed -n "s#^${REPOSITORY#docker.io/}@\\(sha256:[0-9a-f]\\{64\\}\\)\$#\\1#p" |
    head -n1)"

  [[ "${digest}" =~ ^sha256:[0-9a-f]{64}$ ]] ||
    fail "no registry digest recorded for ${tag}"

  printf '%s\n' "${digest}"
}

pin_digest_in_jcasc() {
  local digest="$1"

  sed -i -E \
    "s#(image: )${REPOSITORY}@sha256:[0-9a-f]{64}#\\1${REPOSITORY}@${digest}#" \
    "${JCASC}"

  grep -qF "${REPOSITORY}@${digest}" "${JCASC}" ||
    fail "${JCASC} was not updated"
}

main() {
  local dockerfile_hash
  local tag
  local digest

  cd "${ROOT}"
  verify_source_is_committed

  dockerfile_hash="$(sha256sum "${DOCKERFILE}" | cut -c1-12)"
  tag="${REPOSITORY}:dockerfile-${dockerfile_hash}"

  build_image "${tag}"
  push_image "${tag}"
  digest="$(resolve_registry_digest "${tag}")"
  pin_digest_in_jcasc "${digest}"

  printf 'PASS | %s@%s pinned in %s\n' "${REPOSITORY}" "${digest}" "${JCASC}"
}

main "$@"
