#!/bin/bash
set -euo pipefail
export TZ=Asia/Shanghai

swiftc() {
  command swiftc -swift-version 6 -strict-concurrency=complete "$@"
}

cd "$(dirname "$0")/.."
[[ $# == 3 ]] || { echo 'usage: test-font-weight.sh image.png ocr.txt reference.json' >&2; exit 2; }
mkdir -p build/font-weight
swiftc -parse-as-library -O -framework AppKit -framework CoreML \
 Sources/Models/AppLanguage.swift Sources/Screen/ScreenLayout.swift \
 Sources/Screen/ScreenFontWeightService.swift Tests/ScreenFontWeightIntegrationTests.swift \
 -o build/font-weight/integration-test
build/font-weight/integration-test "$@"
