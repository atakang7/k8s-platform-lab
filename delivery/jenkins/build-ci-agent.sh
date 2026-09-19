#!/usr/bin/env bash
# Builds and publishes the Jenkins CI/CD agent image, then pins its digest in
# JCasC. Commit the JCasC change and run `make jenkins-up` afterwards.
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root}"

repository="${CI_AGENT_REPOSITORY:-docker.io/atakangul/lab-ci-agent}"
dockerfile=delivery/jenkins/ci-agent.Dockerfile
jcasc=platform/jenkins/jcasc/jenkins.yaml

# The pinned image must be reproducible from Git: never build uncommitted edits.
if ! git diff --quiet HEAD -- "${dockerfile}"; then
  echo "FAIL | ${dockerfile} has uncommitted changes; commit it before building" >&2
  exit 1
fi

# The tag names the Dockerfile content, so it survives squash merges.
tag="${repository}:dockerfile-$(sha256sum "${dockerfile}" | cut -c1-12)"

echo "==> Building ${tag}"
# The Dockerfile copies nothing, so the build context is only its directory.
docker build --pull -f "${dockerfile}" -t "${tag}" delivery/jenkins

echo "==> Pushing ${tag}"
docker push "${tag}"

# Docker records Docker Hub digests without the docker.io/ prefix.
digest="$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "${tag}" |
  sed -n "s#^${repository#docker.io/}@\(sha256:[0-9a-f]\{64\}\)\$#\1#p" | head -n1)"
[[ -n "${digest}" ]] || { echo "FAIL | no registry digest recorded for ${tag}" >&2; exit 1; }

sed -i -E "s#(image: )${repository}@sha256:[0-9a-f]{64}#\1${repository}@${digest}#" "${jcasc}"
grep -q "${repository}@${digest}" "${jcasc}" || { echo "FAIL | ${jcasc} was not updated" >&2; exit 1; }

echo "PASS | ${repository}@${digest} pinned in ${jcasc}"
