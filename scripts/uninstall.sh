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
remove_bundle() {
  local path="$1" expected="$2" actual
  [[ -d "$path" ]] || return 0
  actual=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$path/Contents/Info.plist")
  [[ "$actual" == "$expected" ]] || { echo "Refusing unexpected bundle: $path ($actual)" >&2; return 1; }
  /bin/launchctl asuser "$USER_UID" /usr/bin/sudo -H -u "$USER_NAME" \
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$path" || true
  /bin/rm -rf -- "$path"
  echo "Removed: $path"
}
disable_binary=''
for candidate in \
  '/Library/Input Methods/Saylane.app/Contents/MacOS/Saylane' \
  '/Applications/Saylane.app/Contents/MacOS/Saylane' \
  "$USER_HOME/Library/Input Methods/Saylane.app/Contents/MacOS/Saylane" \
  "$USER_HOME/Applications/Saylane.app/Contents/MacOS/Saylane"; do
  if [[ -x "$candidate" ]]; then disable_binary="$candidate"; break; fi
done
if [[ -n "$disable_binary" ]]; then
  /bin/launchctl asuser "$USER_UID" /usr/bin/sudo -H -u "$USER_NAME" \
    "$disable_binary" --disable-input-source || {
      echo 'Input-source disable did not complete; bundles were left in place so this can be retried.' >&2
      exit 1
    }
fi
stop_process() {
  local name="$1"
  /usr/bin/pkill -TERM -x "$name" 2>/dev/null || true
  for _ in {1..50}; do
    /usr/bin/pgrep -x "$name" >/dev/null 2>&1 || return 0
    /bin/sleep 0.1
  done
  /usr/bin/pkill -KILL -x "$name" 2>/dev/null || true
  /usr/bin/pgrep -x "$name" >/dev/null 2>&1 && {
    echo "Could not stop $name; bundles were left in place." >&2
    exit 1
  }
}
stop_process Saylane
stop_process RTranslate
for path in '/Library/Input Methods/RTranslate.app' '/Applications/RTranslate.app' "$USER_HOME/Library/Input Methods/RTranslate.app" "$USER_HOME/Applications/RTranslate.app" '/Library/Input Methods/Saylane.app' '/Applications/Saylane.app' "$USER_HOME/Library/Input Methods/Saylane.app" "$USER_HOME/Applications/Saylane.app"; do
  [[ -d "$path" ]] || continue
  bid=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$path/Contents/Info.plist")
  case "$bid" in
    com.rtranslate.app|com.rtranslate.inputmethod.rtranslate) remove_bundle "$path" "$bid";;
    *) echo "Refusing unexpected bundle: $path" >&2; exit 1;;
  esac
done
remove_bundle "$USER_HOME/Library/Input Methods/RTranslate-SignedProbe.app" com.rtranslate.inputmethod.signedprobe
remove_bundle "$USER_HOME/Library/Input Methods/RTranslate-MetadataProbe.app" com.rtranslate.inputmethod.metadataprobe
/usr/sbin/pkgutil --forget com.rtranslate.app >/dev/null 2>&1 || true
echo 'Saylane uninstalled. Preferences and downloaded models preserved.'
