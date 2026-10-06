#!/usr/bin/env bash
# Builds and publishes the Jenkins CI/CD agent image, resolves the registry
# digest, and pins that digest in the agent pod specs. Commit that change and run
# `make jenkins-up` afterwards.
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT
readonly REPOSITORY="${CI_AGENT_REPOSITORY:-docker.io/atakangul/lab-ci-agent}"
readonly DOCKERFILE=delivery/jenkins/ci-agent.Dockerfile
readonly BUILD_CONTEXT=delivery/jenkins
readonly AGENT_PODS=(platform/jenkins/pods/*.yaml)

fail() {
  printf 'FAIL | %s\n' "$1" >&2
  exit 1
}

verify_source_is_committed() {
  # The build is traceable to Git only when the Dockerfile being built matches
  # HEAD. External package repositories can still change between rebuilds; the
  # registry digest pinned into the agent pod specs remains the runtime source of truth.
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
  local repo_digests
  local digest

  # Docker records Docker Hub RepoDigests without the docker.io/ prefix.
  repo_digests="$(docker image inspect \
    --format '{{range .RepoDigests}}{{println .}}{{end}}' \
    "${tag}")"
  digest="$(sed -n "s#^${REPOSITORY#docker.io/}@\\(sha256:[0-9a-f]\\{64\\}\\)\$#\\1#p" <<< "${repo_digests}")"
  # Keep the first match. Not `| head -n1`: under pipefail, head exiting early
  # can kill sed and fail the line.
  digest="${digest%%$'\n'*}"

  [[ "${digest}" =~ ^sha256:[0-9a-f]{64}$ ]] ||
    fail "no registry digest recorded for ${tag}"

  printf '%s\n' "${digest}"
}

pin_digest_in_agent_pods() {
  local digest="$1"
  local pod

  for pod in "${AGENT_PODS[@]}"; do
    sed -i -E \
      "s#(image: )${REPOSITORY}@sha256:[0-9a-f]{64}#\\1${REPOSITORY}@${digest}#" \
      "${pod}"

    grep -qF "${REPOSITORY}@${digest}" "${pod}" ||
      fail "${pod} was not updated"
  done
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
  pin_digest_in_agent_pods "${digest}"

  printf 'PASS | %s@%s pinned in %s\n' "${REPOSITORY}" "${digest}" platform/jenkins/pods
}

main "$@"
