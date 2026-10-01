#!/bin/bash
# Lay the two built bundles out as they are installed and sign them.
#   usage: stage-bundles.sh ROOT [IDENTITY]
# Without an identity the bundles keep their ad-hoc build signature.
set -euo pipefail
export TZ=Asia/Shanghai
cd "$(dirname "$0")/.."
ROOT="${1:?usage: stage-bundles.sh ROOT [IDENTITY]}"
IDENTITY="${2:-}"
PRODUCTS=build/Build/Products/Release
IME_BUILT="$PRODUCTS/SaylaneIME.app"
APP_BUILT="$PRODUCTS/Saylane.app"
[[ -d "$IME_BUILT" && -d "$APP_BUILT" ]] || { echo 'Build both targets first (make release).' >&2; exit 1; }

PROJECT_VERSION="$(awk -F '"' '/MARKETING_VERSION:/ {print $2; exit}' project.yml)"
PROJECT_BUILD="$(awk -F '"' '/CURRENT_PROJECT_VERSION:/ {print $2; exit}' project.yml)"
for BUNDLE in "$IME_BUILT" "$APP_BUILT"; do
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$BUNDLE/Contents/Info.plist")"
  BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$BUNDLE/Contents/Info.plist")"
  [[ "$VERSION" == "$PROJECT_VERSION" && "$BUILD" == "$PROJECT_BUILD" ]] || {
    echo "Version mismatch in $BUNDLE: built=$VERSION/$BUILD project=$PROJECT_VERSION/$PROJECT_BUILD; rebuild before packaging." >&2
    exit 1
  }
done

# Exact staging paths only; never a live installation.
rm -rf "$ROOT"
mkdir -p "$ROOT/Library/Input Methods" "$ROOT/Applications"
IME="$ROOT/Library/Input Methods/Saylane.app"
APP="$ROOT/Applications/Saylane.app"
ditto "$IME_BUILT" "$IME"
ditto "$APP_BUILT" "$APP"
scripts/assert-no-model-weights.sh "$IME"
scripts/assert-no-model-weights.sh "$APP"

# The input method must stay what it is: no microphone, no speech, no screen capture.
if /usr/bin/otool -L "$IME/Contents/MacOS/SaylaneIME" | /usr/bin/grep -Eq 'AVFAudio|AVFoundation|Speech\.framework|ScreenCaptureKit|Translation\.framework|CoreML'; then
  echo 'The input method links a framework that belongs to the main program.' >&2
  exit 1
fi

if [[ -n "$IDENTITY" ]]; then
  # Embedded native code gets the same stable identity before the outer seal.
  /usr/bin/codesign --force --options runtime --timestamp --sign "$IDENTITY" "$IME/Contents/Frameworks/librime.1.dylib"
  /usr/bin/codesign --force --options runtime --timestamp --sign "$IDENTITY" "$IME"
  for HELPER in "$APP"/Contents/Resources/Runtime/llama-funasr-*; do
    /usr/bin/codesign --force --options runtime --timestamp --sign "$IDENTITY" "$HELPER"
  done
  /usr/bin/codesign --force --options runtime --timestamp --sign "$IDENTITY" \
    --entitlements Sources/App/Saylane.entitlements "$APP"
fi
/usr/bin/codesign --verify --strict --verbose=2 "$IME"
/usr/bin/codesign --verify --strict --verbose=2 "$APP"
echo "$PROJECT_VERSION"
