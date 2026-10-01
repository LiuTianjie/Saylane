#!/bin/bash
set -euo pipefail
export TZ=Asia/Shanghai
# Explicit uninstall: product bundles only. Never remove settings, models, or other IMEs.
[[ "$EUID" == 0 ]] || { echo 'Administrator authorization required.' >&2; exit 1; }
USER_NAME="$(/usr/bin/stat -f '%Su' /dev/console)"
[[ -n "$USER_NAME" && "$USER_NAME" != root && "$USER_NAME" != loginwindow ]] || {
  echo 'No logged-in console user; cannot clean that user’s input-source registration.' >&2
  exit 1
}
USER_HOME="$(/usr/bin/dscl . -read "/Users/$USER_NAME" NFSHomeDirectory | /usr/bin/sed 's/^NFSHomeDirectory: //')"
[[ "$USER_HOME" == /Users/* && "$USER_HOME" != /Users/ ]] || exit 1
USER_UID="$(/usr/bin/id -u "$USER_NAME")"
as_user() { /bin/launchctl asuser "$USER_UID" /usr/bin/sudo -H -u "$USER_NAME" "$@"; }
remove_bundle() {
  local path="$1" actual
  [[ -d "$path" ]] || return 0
  actual=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$path/Contents/Info.plist")
  case "$actual" in
    com.rtranslate.saylane|com.rtranslate.app|com.rtranslate.inputmethod.rtranslate) ;;
    *) echo "Refusing unexpected bundle: $path ($actual)" >&2; return 1;;
  esac
  as_user /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$path" || true
  /bin/rm -rf -- "$path"
  echo "Removed: $path"
}

# 1. Leave the input source before anything is removed, so System Settings does
#    not keep a selected ghost entry. The main program's binary does it; builds
#    before 0.3 had the command in the input method itself.
disable_binary=''
for candidate in \
  '/Applications/Saylane.app/Contents/MacOS/Saylane' \
  '/Library/Input Methods/Saylane.app/Contents/MacOS/Saylane' \
  "$USER_HOME/Library/Input Methods/Saylane.app/Contents/MacOS/Saylane"; do
  if [[ -x "$candidate" ]]; then disable_binary="$candidate"; break; fi
done
if [[ -n "$disable_binary" ]]; then
  as_user "$disable_binary" --disable-input-source || {
    echo 'Input-source disable did not complete; bundles were left in place so this can be retried.' >&2
    exit 1
  }
fi

# 2. Stop both processes: the main program, then the input method (once).
stop_matching() {
  local pattern="$1"
  /usr/bin/pkill -TERM -f "$pattern" 2>/dev/null || true
  for _ in {1..50}; do
    /usr/bin/pgrep -f "$pattern" >/dev/null 2>&1 || return 0
    /bin/sleep 0.1
  done
  /usr/bin/pkill -KILL -f "$pattern" 2>/dev/null || true
  /usr/bin/pgrep -f "$pattern" >/dev/null 2>&1 && {
    echo "Could not stop a Saylane process ($pattern); bundles were left in place." >&2
    exit 1
  }
  return 0
}
stop_matching '^/Applications/Saylane\.app/Contents/MacOS/'
stop_matching '/Library/Input Methods/(Saylane|RTranslate)\.app/Contents/MacOS/'

# 3. Remove the bundles this product has ever installed.
for path in \
  '/Applications/Saylane.app' '/Library/Input Methods/Saylane.app' \
  '/Library/Input Methods/RTranslate.app' '/Applications/RTranslate.app' \
  "$USER_HOME/Library/Input Methods/Saylane.app" "$USER_HOME/Applications/Saylane.app" \
  "$USER_HOME/Library/Input Methods/RTranslate.app" "$USER_HOME/Applications/RTranslate.app"; do
  remove_bundle "$path"
done
/usr/sbin/pkgutil --forget com.rtranslate.app >/dev/null 2>&1 || true
echo 'Saylane uninstalled. Preferences and downloaded models preserved.'
