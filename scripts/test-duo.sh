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
# SAYLANE_IME_BUNDLE / SAYLANE_APP_BUNDLE point at other copies, for example the signed ones staged for a package.
IME="${SAYLANE_IME_BUNDLE:-$PRODUCTS/SaylaneIME.app}/Contents/MacOS/SaylaneIME"
APP="${SAYLANE_APP_BUNDLE:-$PRODUCTS/Saylane.app}/Contents/MacOS/Saylane"
[[ -x "$IME" && -x "$APP" ]] || { echo 'Build first (make release).' >&2; exit 1; }
source scripts/test-home.sh
REAL_BEFORE="$(real_preferences)"

# One run: the main program is told which application is in front. A second
# argument is a sentence to dictate, a third a correction (heard>corrected)
# the test makes in it afterwards, for the main program to learn.
APP_PID=''
stop_app() {
  [[ -n "$APP_PID" ]] || return 0
  kill "$APP_PID" 2>/dev/null || true
  wait "$APP_PID" 2>/dev/null || true
  APP_PID=''
  if [[ "${KEEP_TEST_HOME:-}" == 1 ]]; then echo "kept $SAYLANE_TEST_HOME"; else rm -rf "$SAYLANE_TEST_HOME"; fi
  reset_test_preferences
}
trap stop_app EXIT

run() {
  export SAYLANE_TEST_HOME="$(mktemp -d /tmp/saylane-duo-test.XXXXXX)"
  export SAYLANE_TEST_FRONT="$1"
  export SAYLANE_TEST_SPEECH="${2:-你好，世界。}"
  export SAYLANE_TEST_CORRECTION="${3:-}"
  local ime_pid status=0
  reset_test_preferences
  "$APP" --background 2>/dev/null &
  APP_PID=$!
  "$IME" --self-test-duo 2>/dev/null &
  ime_pid=$!
  for _ in {1..240}; do
    kill -0 "$ime_pid" 2>/dev/null || break
    sleep 0.25
  done
  if kill -0 "$ime_pid" 2>/dev/null; then
    kill "$ime_pid" 2>/dev/null || true
    echo 'FAILED: the two-process self-test did not finish' >&2
    status=1
  else
    wait "$ime_pid" || status=$?
  fi
  stop_app
  return "$status"
}

# The text client belongs to the application in front…
run 'local.saylane.selftest'
# …and it is a panel over another one, as Spotlight or a launcher is.
run 'local.saylane.another-application'
# A name that is heard wrong and corrected by hand, twice: the third time it is written right.
run 'local.saylane.selftest' '明天和黄根诚开会。' '黄根诚>黄根成'
assert_real_preferences_untouched "$REAL_BEFORE"
