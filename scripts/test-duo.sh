#!/bin/bash
# The two built programs together, in a scratch home: the input method feeds the
# talk key as InputMethodKit would, the main program runs a dictation with a
# scripted recognizer, and the text must arrive in the input method's client.
# Everything is exercised except InputMethodKit's transport, the microphone and
# the recognizer. The installed product, its data and the pasteboard are not touched.
set -euo pipefail
export TZ=Asia/Shanghai
cd "$(dirname "$0")/.."
PRODUCTS=build/Build/Products/Release
IME="$PRODUCTS/SaylaneIME.app/Contents/MacOS/SaylaneIME"
APP="$PRODUCTS/Saylane.app/Contents/MacOS/Saylane"
[[ -x "$IME" && -x "$APP" ]] || { echo 'Build first (make release).' >&2; exit 1; }
export SAYLANE_TEST_HOME="$(mktemp -d /tmp/saylane-duo-test.XXXXXX)"
export SAYLANE_TEST_SPEECH='你好，世界。'
export SAYLANE_TEST_FRONT='local.saylane.selftest'
APP_PID=''
cleanup() {
  [[ -n "$APP_PID" ]] && kill "$APP_PID" 2>/dev/null || true
  if [[ "${KEEP_TEST_HOME:-}" == 1 ]]; then echo "kept $SAYLANE_TEST_HOME"; else rm -rf "$SAYLANE_TEST_HOME"; fi
}
trap cleanup EXIT
"$APP" --background 2>/dev/null &
APP_PID=$!
"$IME" --self-test-duo 2>/dev/null &
IME_PID=$!
for _ in {1..240}; do
  kill -0 "$IME_PID" 2>/dev/null || break
  sleep 0.25
done
if kill -0 "$IME_PID" 2>/dev/null; then
  kill "$IME_PID" 2>/dev/null || true
  echo 'FAILED: the two-process self-test did not finish' >&2
  exit 1
fi
wait "$IME_PID"
