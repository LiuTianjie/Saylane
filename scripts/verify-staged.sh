#!/bin/bash
# Run the self-tests against the bundles exactly as they will be installed:
# signed, with the hardened runtime, from the package root. What ships is what
# was exercised.
#   usage: verify-staged.sh ROOT
set -euo pipefail
export TZ=Asia/Shanghai
cd "$(dirname "$0")/.."
ROOT="${1:?usage: verify-staged.sh ROOT}"
export SAYLANE_IME_BUNDLE="$ROOT/Library/Input Methods/Saylane.app"
export SAYLANE_APP_BUNDLE="$ROOT/Applications/Saylane.app"
scripts/test-ime.sh | tail -n 1
scripts/test-duo.sh | tail -n 1
scripts/test-ui.sh | tail -n 1
