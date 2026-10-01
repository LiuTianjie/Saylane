#!/bin/bash
# Build an installer for testing on this Mac. The package itself is unsigned and
# not notarized, so it is never written to the release name: scripts/package.sh
# stays the only way to produce dist/Saylane-<version>.pkg.
set -euo pipefail
export TZ=Asia/Shanghai
cd "$(dirname "$0")/.."
APP=build/Build/Products/Release/Saylane.app
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist")"
SOURCE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Sources/Info.plist)"
SOURCE_BUILD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' Sources/Info.plist)"
[[ "$VERSION" == "$SOURCE_VERSION" && "$BUILD_VERSION" == "$SOURCE_BUILD_VERSION" ]] || {
  echo "Version mismatch: built=$VERSION/$BUILD_VERSION plist=$SOURCE_VERSION/$SOURCE_BUILD_VERSION; rebuild before packaging." >&2
  exit 1
}
ROOT="$PWD/dist/pkgroot-$VERSION-local"
rm -rf "$ROOT"
mkdir -p "$ROOT/Library/Input Methods"
STAGED_APP="$ROOT/Library/Input Methods/Saylane.app"
ditto "$APP" "$STAGED_APP"
scripts/assert-no-model-weights.sh "$STAGED_APP"
# A stable identity keeps the microphone, Accessibility and Input Monitoring
# grants across builds; an ad-hoc signature makes macOS ask again every time.
IDENTITY="${SAYLANE_SIGNING_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITIES="$(/usr/bin/security find-identity -v -p codesigning | /usr/bin/awk '/Developer ID Application:/ {print $2}')"
  COUNT="$(printf '%s\n' "$IDENTITIES" | /usr/bin/awk 'NF {n++} END {print n+0}')"
  [[ "$COUNT" == 1 ]] && IDENTITY="$IDENTITIES"
fi
if [[ -n "$IDENTITY" ]]; then
  for HELPER in "$STAGED_APP"/Contents/Resources/Runtime/llama-funasr-*; do
    /usr/bin/codesign --force --options runtime --timestamp --sign "$IDENTITY" "$HELPER"
  done
  /usr/bin/codesign --force --options runtime --timestamp --sign "$IDENTITY" \
    "$STAGED_APP/Contents/Frameworks/librime.1.dylib"
  /usr/bin/codesign --force --options runtime --timestamp --sign "$IDENTITY" \
    --entitlements Sources/Saylane.entitlements "$STAGED_APP"
  SIGNING="signed with a stable identity"
else
  SIGNING="ad-hoc signed: macOS will ask for every permission again after each build"
fi
/usr/bin/codesign --verify --strict --verbose=2 "$STAGED_APP"
pkgbuild --analyze --root "$ROOT" "$PWD/dist/components-$VERSION-local.plist"
/usr/libexec/PlistBuddy -c 'Set :0:BundleIsRelocatable false' "$PWD/dist/components-$VERSION-local.plist"
OUTPUT="$PWD/dist/Saylane-$VERSION-local.pkg"
rm -f "$OUTPUT"
pkgbuild --root "$ROOT" --component-plist "$PWD/dist/components-$VERSION-local.plist" \
  --identifier com.rtranslate.app --version "$VERSION" --scripts scripts/pkg \
  --install-location / "$OUTPUT"
echo "Built $OUTPUT for local testing (app $SIGNING; package unsigned, not notarized)."
