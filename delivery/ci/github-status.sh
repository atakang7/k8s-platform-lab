#!/usr/bin/env sh
set -eu

state="${1:?state required}"
context="${2:?context required}"
description="${3:?description required}"
sha="${4:-${COMMIT_SHA:-}}"
repo="${GITHUB_REPOSITORY:-atakang7/lab}"
target_url="${BUILD_URL:-}"

case "$state" in
  pending|success|failure|error) ;;
  *) echo "invalid GitHub status state: $state" >&2; exit 2 ;;
esac

[ -n "$sha" ] || { echo "commit SHA required" >&2; exit 2; }
[ -n "${GITHUB_TOKEN:-}" ] || { echo "GITHUB_TOKEN required" >&2; exit 2; }

set +x
payload=$(printf '{"state":"%s","context":"%s","description":"%s","target_url":"%s"}' \
  "$state" "$context" "$description" "$target_url")

curl -fsS \
  -X POST \
  -H "Authorization: Bearer ${GITHUB_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/repos/${repo}/statuses/${sha}" \
  -d "$payload" >/dev/null
