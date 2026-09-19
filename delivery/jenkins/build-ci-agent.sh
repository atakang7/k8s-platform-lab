#!/usr/bin/env bash
# Builds and publishes the Jenkins CI/CD agent image, then pins its digest in
# JCasC. Commit the JCasC change and run `make jenkins-up` afterwards.
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly root
cd "${root}"

readonly repository="${CI_AGENT_REPOSITORY:-docker.io/atakangul/lab-ci-agent}"
readonly dockerfile=delivery/jenkins/ci-agent.Dockerfile
readonly jcasc=platform/jenkins/jcasc/jenkins.yaml

# The pinned image must be reproducible from Git: never build uncommitted edits.
if ! git diff --quiet HEAD -- "${dockerfile}"; then
  printf 'FAIL | %s has uncommitted changes; commit it before building\n' "${dockerfile}" >&2
  exit 1
fi

# The tag names the Dockerfile content, so it survives squash merges.
tag="${repository}:dockerfile-$(sha256sum "${dockerfile}" | cut -c1-12)"

printf 'WAIT | building %s\n' "${tag}"
# The Dockerfile copies nothing, so the build context is only its directory.
docker build --pull -f "${dockerfile}" -t "${tag}" delivery/jenkins

printf 'WAIT | pushing %s\n' "${tag}"
docker push "${tag}"

# Docker records Docker Hub digests without the docker.io/ prefix.
digest="$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "${tag}" |
  sed -n "s#^${repository#docker.io/}@\(sha256:[0-9a-f]\{64\}\)\$#\1#p" | head -n1)"
[[ -n "${digest}" ]] || { printf 'FAIL | no registry digest recorded for %s\n' "${tag}" >&2; exit 1; }

sed -i -E "s#(image: )${repository}@sha256:[0-9a-f]{64}#\1${repository}@${digest}#" "${jcasc}"
grep -q "${repository}@${digest}" "${jcasc}" || { printf 'FAIL | %s was not updated\n' "${jcasc}" >&2; exit 1; }

printf 'PASS | %s@%s pinned in %s\n' "${repository}" "${digest}" "${jcasc}"
