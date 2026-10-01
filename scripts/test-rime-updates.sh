#!/bin/bash
set -euo pipefail
export TZ=Asia/Shanghai

swiftc() {
  command swiftc -swift-version 6 -strict-concurrency=complete "$@"
}

cd "$(dirname "$0")/.."
mkdir -p build/tests
swiftc Sources/Shared/PinyinKeyOptions.swift Sources/Shared/BridgeMessages.swift Sources/Shared/TestHome.swift Sources/Services/RimeDictionaryUpdateService.swift \
  Sources/Services/RimeDictionaryUpdateModel.swift Tests/RimeDictionaryUpdateTests.swift \
  -o build/tests/rime-updates
build/tests/rime-updates "$@"
