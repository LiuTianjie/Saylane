#!/bin/bash
set -euo pipefail
export TZ=Asia/Shanghai

cd "$(dirname "$0")/.."
mkdir -p build/tests
swiftc -swift-version 6 -strict-concurrency=complete \
  Sources/Core/AppDirectories.swift Tests/AppDirectoriesMigrationTests.swift \
  -o build/tests/app-directories-migration
build/tests/app-directories-migration
