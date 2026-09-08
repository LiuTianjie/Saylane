#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate
mkdir -p RTranslate.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
cp Vendor/MLXASR/Package.resolved RTranslate.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
