#!/bin/bash
set -euo pipefail
# Explicit uninstall: product bundles only. Never remove settings, models, or other IMEs.
[[ "$EUID" == 0 ]] || { echo 'Administrator authorization required.' >&2; exit 1; }
USER_NAME="$(stat -f '%Su' /dev/console)"
USER_HOME="$(dscl . -read "/Users/$USER_NAME" NFSHomeDirectory | sed 's/^NFSHomeDirectory: //')"
[[ "$USER_HOME" == /Users/* && "$USER_HOME" != /Users/ ]] || exit 1
remove_bundle() {
  local path="$1" expected="$2" actual
  [[ -d "$path" ]] || return 0
  actual=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$path/Contents/Info.plist")
  [[ "$actual" == "$expected" ]] || { echo "Refusing unexpected bundle: $path ($actual)" >&2; return 1; }
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$path" || true
  /bin/rm -rf -- "$path"
  echo "Removed: $path"
}
/usr/bin/pkill -x RTranslate || true
for path in '/Library/Input Methods/RTranslate.app' '/Applications/RTranslate.app' "$USER_HOME/Library/Input Methods/RTranslate.app" "$USER_HOME/Applications/RTranslate.app"; do
  [[ -d "$path" ]] || continue
  bid=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$path/Contents/Info.plist")
  case "$bid" in
    com.rtranslate.app|com.rtranslate.inputmethod.rtranslate) remove_bundle "$path" "$bid";;
    *) echo "Refusing unexpected bundle: $path" >&2; exit 1;;
  esac
done
remove_bundle "$USER_HOME/Library/Input Methods/RTranslate-SignedProbe.app" com.rtranslate.inputmethod.signedprobe
remove_bundle "$USER_HOME/Library/Input Methods/RTranslate-MetadataProbe.app" com.rtranslate.inputmethod.metadataprobe
echo 'RTranslate uninstalled. Preferences and downloaded models preserved.'
