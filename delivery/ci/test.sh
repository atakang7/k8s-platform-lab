#!/usr/bin/env bash
set -eo pipefail

echo "==> Running Unit Tests..."
mvn -B test -f app/pom.xml
