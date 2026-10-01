#!/bin/bash
# Build an installer for testing on this Mac. The package itself is unsigned and
# not notarized, so it is never written to the release name: scripts/package.sh
# stays the only way to produce dist/Saylane-<version>.pkg.
set -euo pipefail
export TZ=Asia/Shanghai
cd "$(dirname "$0")/.."
# A stable identity keeps the microphone, Accessibility and Screen Recording
# grants across builds; an ad-hoc signature makes macOS ask again every time.
IDENTITY="${SAYLANE_SIGNING_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITIES="$(/usr/bin/security find-identity -v -p codesigning | /usr/bin/awk '/Developer ID Application:/ {print $2}')"
  COUNT="$(printf '%s\n' "$IDENTITIES" | /usr/bin/awk 'NF {n++} END {print n+0}')"
  [[ "$COUNT" == 1 ]] && IDENTITY="$IDENTITIES"
fi
VERSION="$(awk -F '"' '/MARKETING_VERSION:/ {print $2; exit}' project.yml)"
BUILD="$(awk -F '"' '/CURRENT_PROJECT_VERSION:/ {print $2; exit}' project.yml)"
ROOT="$PWD/dist/pkgroot-$VERSION-local"
# Staging folders of earlier versions are whole copies of both programs with
# the product's own identifiers: do not leave them lying around.
for old in "$PWD"/dist/pkgroot-*-local "$PWD"/dist/components-*-local.plist; do
  [[ -e "$old" && "$old" != "$ROOT" && "$old" != "$PWD/dist/components-$VERSION-local.plist" ]] && rm -rf -- "$old"
done
scripts/stage-bundles.sh "$ROOT" "$IDENTITY" >/dev/null
if [[ -n "$IDENTITY" ]]; then
  SIGNING="signed with a stable identity"
else
  SIGNING="ad-hoc signed: macOS will ask for every permission again after each build"
fi
# The signed bundles are run through the self-tests before they are packaged.
scripts/verify-staged.sh "$ROOT"
COMPONENTS="$PWD/dist/components-$VERSION-local.plist"
python3 scripts/component-plist.py "$ROOT" "$COMPONENTS" --allow-same-version
OUTPUT="$PWD/dist/Saylane-$VERSION-$BUILD-local.pkg"
rm -f "$OUTPUT"
pkgbuild --root "$ROOT" --component-plist "$COMPONENTS" \
  --identifier com.rtranslate.app --version "$VERSION" --scripts scripts/pkg \
  --install-location / "$OUTPUT"
echo "Built $OUTPUT for local testing (bundles $SIGNING; package unsigned, not notarized)."
