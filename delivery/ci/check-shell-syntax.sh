#!/usr/bin/env bash
# Parses every shell script under the given paths with bash -n. Fails when a
# script does not parse, and when no script is found (a check that inspects
# nothing must not pass).
set -euo pipefail

count=0
while IFS= read -r -d '' file; do
  if head -n1 "${file}" | grep -q '^#!.*sh'; then
    bash -n "${file}"
    count=$((count + 1))
  fi
done < <(find "$@" -type f -not -path '*/.git/*' -print0)

[[ "${count}" -gt 0 ]] || { echo "FAIL | no shell scripts found under: $*" >&2; exit 1; }
echo "PASS | ${count} shell scripts parse under: $*"
