#!/bin/bash
set -euo pipefail
export TZ=Asia/Shanghai
cd "$(dirname "$0")/.."
VERSION="$(awk -F '"' '/MARKETING_VERSION:/ {print $2; exit}' project.yml)"
BUILD_VERSION="$(awk -F '"' '/CURRENT_PROJECT_VERSION:/ {print $2; exit}' project.yml)"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$BUILD_VERSION" =~ ^[0-9]+$ ]] || {
  echo "Invalid version values: $VERSION/$BUILD_VERSION" >&2
  exit 1
}
# Resolve every required release setting before touching a signing key. Missing
# installer/notary configuration must not trigger partial signing or prompts.
IDENTITY="${SAYLANE_SIGNING_IDENTITY:-${RTRANSLATE_SIGNING_IDENTITY:-}}"
[[ -n "$IDENTITY" ]] || { echo 'Set SAYLANE_SIGNING_IDENTITY to the intended Developer ID Application identity.' >&2; exit 1; }
INSTALLER="${SAYLANE_INSTALLER_IDENTITY:-}"
[[ -n "$INSTALLER" ]] || {
  echo 'Set SAYLANE_INSTALLER_IDENTITY to the intended Developer ID Installer identity for team L95PYLFT86.' >&2
  exit 1
}
NOTARY_PROFILE="${SAYLANE_NOTARY_PROFILE:-}"
[[ -n "$NOTARY_PROFILE" ]] || {
  echo 'Set SAYLANE_NOTARY_PROFILE to an existing notarytool keychain profile; a public package must be notarized.' >&2
  exit 1
}
ROOT="$PWD/dist/pkgroot-$VERSION"
# A cdhash-only ad-hoc identity changes every release, undermining persistent
# permission grants. Release packages require a stable Developer ID. Built
# versions are checked against project.yml while staging.
scripts/stage-bundles.sh "$ROOT" "$IDENTITY" >/dev/null
for STAGED_APP in "$ROOT/Library/Input Methods/Saylane.app" "$ROOT/Applications/Saylane.app"; do
  SIGN_DETAILS="$(/usr/bin/codesign -dvvv "$STAGED_APP" 2>&1)"
  printf '%s\n' "$SIGN_DETAILS" | /usr/bin/grep -q 'Authority=Developer ID Application:' || {
    echo 'Release app is not signed with a Developer ID Application certificate.' >&2
    exit 1
  }
  printf '%s\n' "$SIGN_DETAILS" | /usr/bin/grep -q 'TeamIdentifier=L95PYLFT86' || {
    echo 'Release app TeamIdentifier must be L95PYLFT86.' >&2
    exit 1
  }
  REQUIREMENT="$(/usr/bin/codesign -d -r- "$STAGED_APP" 2>&1)"
  if printf '%s' "$REQUIREMENT" | /usr/bin/grep -q 'designated => cdhash'; then
    echo 'Refusing to package an ad-hoc release identity.' >&2
    exit 1
  fi
done
python3 scripts/component-plist.py "$ROOT" "$PWD/dist/components-$VERSION.plist"
UNSIGNED="$PWD/dist/Saylane-$VERSION.unsigned.pkg"
SIGNED_PENDING="$PWD/dist/Saylane-$VERSION.signed-unnotarized.pkg"
SIGNED="$PWD/dist/Saylane-$VERSION.pkg"
rm -f "$UNSIGNED" "$SIGNED_PENDING" "$SIGNED"
pkgbuild --root "$ROOT" --component-plist "$PWD/dist/components-$VERSION.plist" \
  --identifier com.rtranslate.app --version "$VERSION" --scripts scripts/pkg \
  --install-location / "$UNSIGNED"
/usr/bin/productsign --sign "$INSTALLER" --timestamp "$UNSIGNED" "$SIGNED_PENDING"
rm -f "$UNSIGNED"
PKG_SIGNATURE="$(/usr/sbin/pkgutil --check-signature "$SIGNED_PENDING" 2>&1)"
printf '%s\n' "$PKG_SIGNATURE"
printf '%s\n' "$PKG_SIGNATURE" | /usr/bin/grep -q 'Developer ID Installer:' || {
  rm -f "$SIGNED_PENDING"
  echo 'Package is not signed with a Developer ID Installer certificate.' >&2
  exit 1
}
printf '%s\n' "$PKG_SIGNATURE" | /usr/bin/grep -q 'L95PYLFT86' || {
  rm -f "$SIGNED_PENDING"
  echo 'Package installer certificate must belong to team L95PYLFT86.' >&2
  exit 1
}
/usr/bin/xcrun notarytool submit "$SIGNED_PENDING" --keychain-profile "$NOTARY_PROFILE" --wait
mv "$SIGNED_PENDING" "$SIGNED"
/usr/bin/xcrun stapler staple "$SIGNED"
/usr/bin/xcrun stapler validate "$SIGNED"
/usr/sbin/spctl -a -vv -t install "$SIGNED"
echo "Built signed and notarized dist/Saylane-$VERSION.pkg"
echo "Non-relocatable: /Library/Input Methods/Saylane.app and /Applications/Saylane.app"
