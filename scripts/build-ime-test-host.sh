#!/bin/bash
set -euo pipefail
export TZ=Asia/Shanghai
cd "$(dirname "$0")/.."
app="$PWD/build/tests/IMEIntegrationHost.app"
mkdir -p "$app/Contents/MacOS"
python3 - "$app/Contents/Info.plist" <<'PY'
import plistlib, sys
from pathlib import Path
Path(sys.argv[1]).write_bytes(plistlib.dumps({
    'CFBundleIdentifier': 'com.saylane.tests.imeintegration',
    'CFBundleExecutable': 'IMEIntegrationHost',
    'CFBundleName': 'Saylane Input Test',
    'CFBundlePackageType': 'APPL',
    'NSPrincipalClass': 'NSApplication',
}))
PY
swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library -framework AppKit \
  Tests/IMEIntegrationHost.swift -o "$app/Contents/MacOS/IMEIntegrationHost"
echo "Built $app"
