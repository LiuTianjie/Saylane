#!/bin/bash
set -euo pipefail
export TZ=Asia/Shanghai

swiftc() {
  command swiftc -swift-version 6 -strict-concurrency=complete "$@"
}

cd "$(dirname "$0")/.."
mkdir -p build/tests
# The pin model lives at the top of the controller file; the views are their own files.
python3 - <<'PY'
from pathlib import Path
source = Path('Sources/Screen/ScreenTranslateController.swift').read_text()
model = source[:source.index('/// Screen translation: selection')]
Path('build/tests/ScreenPinScrollHarness.swift').write_text(model + Path('Tests/ScreenPinScrollTests.swift').read_text())
PY
swiftc -parse-as-library -framework AppKit -framework CoreImage \
  Sources/Models/AppLanguage.swift Sources/Screen/ScreenLayout.swift \
  Sources/Screen/ScreenPinRenderer.swift Sources/Support/Theme.swift \
  Sources/Screen/ScreenPinViews.swift Sources/Screen/ScreenPinPanel.swift Sources/Screen/ScreenPinChrome.swift \
  build/tests/ScreenPinScrollHarness.swift -o build/tests/screen-scroll
build/tests/screen-scroll "$@"
