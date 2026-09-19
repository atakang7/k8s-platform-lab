#!/usr/bin/env bash
# Change router for lab-build: prints the CI flows to run for the changes
# between BASE and HEAD, one per line.
#
# Deliberately small and specific to this repository's four top-level areas.
# It is not a general monorepo build system; see "Change router" in
# delivery/README.md before extending it.
#
#   app       app/, delivery/                           test, build, scan, publish, deploy
#   platform  platform/, policies/                      static checks; applied by the operator
#   infra     infra/, validation/, Vagrantfile, Makefile  static checks; applied by the operator
#
# Markdown never triggers a flow. Anything else (docs/, .gitignore) triggers
# nothing. Without a usable BASE (first build, rewritten history) every flow runs.
set -euo pipefail

base="${1:-}"
head="${2:?usage: route.sh BASE HEAD}"

if [[ -z "${base}" ]] || ! git cat-file -e "${base}^{commit}" 2>/dev/null; then
  printf '%s\n' app platform infra
  exit 0
fi

git diff --name-only "${base}" "${head}" | awk '
  /\.md$/                                        { next }
  /^(app|delivery)\//                            { print "app"; next }
  /^(platform|policies)\//                       { print "platform"; next }
  /^(infra|validation)\// || /^(Vagrantfile|Makefile)$/ { print "infra"; next }
' | sort -u
