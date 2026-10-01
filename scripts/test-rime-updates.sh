#!/bin/bash
set -euo pipefail
export TZ=Asia/Shanghai

swiftc() {
  command swiftc -swift-version 6 -strict-concurrency=complete "$@"
}

cd "$(dirname "$0")/.."
mkdir -p build/tests
swiftc Sources/IME/Rime/RimeDictionaryUpdateService.swift \
  Sources/IME/Rime/RimeDictionaryUpdateModel.swift Tests/RimeDictionaryUpdateTests.swift \
  -o build/tests/rime-updates
build/tests/rime-updates "$@"
