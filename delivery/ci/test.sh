#!/usr/bin/env bash
set -eo pipefail

echo "==> Running Unit Tests..."
mvn -B -ntp test -f app/pom.xml
