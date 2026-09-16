#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tests
# Keep production views private; compile their actual source with the harness
# in one file rather than maintaining a second implementation for tests.
python3 - <<'PY'
from pathlib import Path
source = Path('Sources/Services/ScreenTranslateController.swift').read_text()
model = source[:source.index('@MainActor\nfinal class ScreenTranslateController')]
views = source[source.index('private final class ScreenPinFreezePanel'):]
Path('build/tests/ScreenPinScrollHarness.swift').write_text(model + views + Path('Tests/ScreenPinScrollTests.swift').read_text())
PY
swiftc -parse-as-library -framework AppKit -framework CoreImage -framework Translation \
  Sources/Models/AppLanguage.swift Sources/Models/ScreenTranslate.swift \
  Sources/Services/ScreenPinRenderer.swift Sources/Support/Theme.swift \
  build/tests/ScreenPinScrollHarness.swift -o build/tests/screen-scroll
build/tests/screen-scroll "$@"
