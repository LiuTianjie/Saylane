# Sourced by the self-test scripts. A self-test runs a built copy next to the
# installed product: it gets a preferences domain of its own, emptied before
# and removed after each run, and the installed product's preferences must come
# out of the run exactly as they went in.
REAL_PREFERENCES_DOMAIN='com.rtranslate.inputmethod.rtranslate'
TEST_PREFERENCES_DOMAIN='local.saylane.test'

real_preferences() {
  /usr/bin/defaults export "$REAL_PREFERENCES_DOMAIN" - 2>/dev/null | /usr/bin/shasum | /usr/bin/cut -d' ' -f1
}

reset_test_preferences() {
  /usr/bin/defaults delete "$TEST_PREFERENCES_DOMAIN" >/dev/null 2>&1 || true
  # `defaults delete` leaves an empty file behind.
  /bin/rm -f "$HOME/Library/Preferences/$TEST_PREFERENCES_DOMAIN.plist"
}

# Call once before the first run, with the value of `real_preferences` taken then.
assert_real_preferences_untouched() {
  [[ "$(real_preferences)" == "$1" ]] && return 0
  echo "FAILED: the installed product's preferences ($REAL_PREFERENCES_DOMAIN) changed during the self-test" >&2
  return 1
}
