#!/bin/bash
# Run the built input method's own code against a text client inside the same
# process: the real client bookkeeping, Rime, candidate window and bridge. No
# IMKServer is created, so the installed input method is not disturbed and the
# system does not count the run as an input-method restart.
set -euo pipefail
export TZ=Asia/Shanghai
cd "$(dirname "$0")/.."
# SAYLANE_IME_BUNDLE points at another copy, for example the signed one staged for a package.
BIN="${SAYLANE_IME_BUNDLE:-build/Build/Products/Release/SaylaneIME.app}/Contents/MacOS/SaylaneIME"
[[ -x "$BIN" ]] || { echo 'Build first (make release).' >&2; exit 1; }
"$BIN" --pinyin-self-test
HOME_DIR="$(mktemp -d /tmp/saylane-ime-test.XXXXXX)"
trap 'rm -rf "$HOME_DIR"' EXIT
# An exception inside AppKit's event loop is swallowed and would leave the
# process waiting for ever: give it a limit.
SAYLANE_TEST_HOME="$HOME_DIR" "$BIN" --self-test 2>/dev/null &
PID=$!
for _ in {1..120}; do
  kill -0 "$PID" 2>/dev/null || break
  sleep 0.25
done
if kill -0 "$PID" 2>/dev/null; then
  kill "$PID" 2>/dev/null || true
  echo 'FAILED: the input method self-test did not finish' >&2
  exit 1
fi
wait "$PID"
