#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' build/Build/Products/Release/RTranslate.app/Contents/Info.plist)"
ROOT="$PWD/dist/pkgroot-$VERSION"
mkdir -p "$ROOT/Library/Input Methods"
# Exact build staging path only; never remove live installations without Installer privileges.
rm -rf "$ROOT/Library/Input Methods/RTranslate.app"
ditto build/Build/Products/Release/RTranslate.app "$ROOT/Library/Input Methods/RTranslate.app"
# A cdhash-only ad-hoc identity changes every release, undermining persistent
# microphone/Keychain consent. Release packages require a stable Developer ID.
IDENTITY="${RTRANSLATE_SIGNING_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITIES="$(/usr/bin/security find-identity -v -p codesigning | /usr/bin/awk '/Developer ID Application:/ {print $2}')"
  COUNT="$(printf '%s\n' "$IDENTITIES" | /usr/bin/awk 'NF {n++} END {print n+0}')"
  [[ "$COUNT" == 1 ]] || { echo 'Set RTRANSLATE_SIGNING_IDENTITY to one Developer ID Application identity.' >&2; exit 1; }
  IDENTITY="$IDENTITIES"
fi
STAGED_APP="$ROOT/Library/Input Methods/RTranslate.app"
/usr/bin/codesign --force --options runtime --timestamp --sign "$IDENTITY" \
  --entitlements Sources/RTranslate.entitlements "$STAGED_APP"
/usr/bin/codesign --verify --strict --verbose=2 "$STAGED_APP"
REQUIREMENT="$(/usr/bin/codesign -d -r- "$STAGED_APP" 2>&1)"
if printf '%s' "$REQUIREMENT" | /usr/bin/grep -q 'designated => cdhash'; then
  echo 'Refusing to package an ad-hoc release identity.' >&2
  exit 1
fi
pkgbuild --analyze --root "$ROOT" "$PWD/dist/components-$VERSION.plist"
/usr/libexec/PlistBuddy -c 'Set :0:BundleIsRelocatable false' "$PWD/dist/components-$VERSION.plist"
pkgbuild --root "$ROOT" --component-plist "$PWD/dist/components-$VERSION.plist" \
  --identifier com.rtranslate.app --version "$VERSION" --scripts scripts/pkg \
  --install-location / "$PWD/dist/RTranslate-$VERSION.pkg"
echo "Built dist/RTranslate-$VERSION.pkg (non-relocatable /Library/Input Methods installation)"
