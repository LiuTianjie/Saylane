#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/prepare-rime.py
xcodegen generate
mkdir -p Saylane.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
cp Vendor/MLXASR/Package.resolved Saylane.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
