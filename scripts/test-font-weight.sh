#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $# == 3 ]] || { echo 'usage: test-font-weight.sh image.png ocr.txt reference.json' >&2; exit 2; }
mkdir -p build/font-weight
swiftc -parse-as-library -O -framework AppKit -framework CoreML \
 Sources/Models/AppLanguage.swift Sources/Models/ScreenTranslate.swift \
 Sources/Services/ScreenFontWeightService.swift Tests/ScreenFontWeightIntegrationTests.swift \
 -o build/font-weight/integration-test
build/font-weight/integration-test "$@"
