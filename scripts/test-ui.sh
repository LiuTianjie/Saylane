#!/bin/bash
# Drive the real windows of the built main program with real mouse and key
# events, in a scratch home that never touches the installed product. Needs a
# window server; a small window appears for a few seconds.
set -euo pipefail
export TZ=Asia/Shanghai
cd "$(dirname "$0")/.."
# SAYLANE_APP_BUNDLE points at another copy, for example the signed one staged for a package.
BIN="${SAYLANE_APP_BUNDLE:-build/Build/Products/Release/Saylane.app}/Contents/MacOS/Saylane"
[[ -x "$BIN" ]] || { echo 'Build first (make release).' >&2; exit 1; }
source scripts/test-home.sh
REAL_BEFORE="$(real_preferences)"
HOME_DIR="$(mktemp -d /tmp/saylane-ui-test.XXXXXX)"
trap 'rm -rf "$HOME_DIR"; reset_test_preferences' EXIT
reset_test_preferences
SAYLANE_TEST_HOME="$HOME_DIR" "$BIN" --ui-self-test "$@" 2>/dev/null
assert_real_preferences_untouched "$REAL_BEFORE"
