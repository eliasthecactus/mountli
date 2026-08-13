#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:?usage: release-direct.sh VERSION}"
BUILD_DIR="${BUILD_DIR:-$ROOT/.build/release-direct}"
ARCHIVE="$BUILD_DIR/MOUNTLI.xcarchive"
EXPORT="$BUILD_DIR/export"
RELEASES="$BUILD_DIR/releases"
: "${NOTARY_KEYCHAIN_PROFILE:?Set NOTARY_KEYCHAIN_PROFILE to an xcrun notarytool profile}"
: "${SPARKLE_PRIVATE_KEY:?Set SPARKLE_PRIVATE_KEY to the exported Sparkle EdDSA key}"
: "${MOUNTLI_ENCRYPTION_EXPORT_COMPLIANCE_CODE:?Set the Apple-issued export compliance value}"

rm -rf "$BUILD_DIR"
mkdir -p "$EXPORT" "$RELEASES"
cd "$ROOT"
./Scripts/build-bridge.sh
xcodegen generate
xcodebuild archive \
  -project MOUNTLI.xcodeproj \
  -scheme MOUNTLI-macOS-Direct \
  -configuration Release \
  -archivePath "$ARCHIVE" \
  -clonedSourcePackagesDirPath "$BUILD_DIR/SourcePackages" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="${BUILD_NUMBER:-1}" \
  MOUNTLI_ENCRYPTION_EXPORT_COMPLIANCE_CODE="$MOUNTLI_ENCRYPTION_EXPORT_COMPLIANCE_CODE"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT" \
  -exportOptionsPlist Config/ExportOptions/DeveloperID.plist

APP="$EXPORT/MOUNTLI.app"
ZIP="$RELEASES/MOUNTLI-$VERSION.zip"
DMG="$RELEASES/MOUNTLI-$VERSION.dmg"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" --wait \
  | tee "$RELEASES/notarization-zip.txt"
xcrun stapler staple "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

KEY_FILE="$BUILD_DIR/sparkle-private-key"
printf '%s' "$SPARKLE_PRIVATE_KEY" > "$KEY_FILE"
chmod 600 "$KEY_FILE"
cleanup() { rm -f "$KEY_FILE"; }
trap cleanup EXIT INT TERM
SPARKLE_BIN="${SPARKLE_BIN:-$BUILD_DIR/SourcePackages/artifacts/sparkle/Sparkle/bin}"
"$SPARKLE_BIN/generate_appcast" \
  --ed-key-file "$KEY_FILE" \
  --download-url-prefix "https://github.com/eliasthecactus/mountli/releases/download/v$VERSION/" \
  "$RELEASES"
rm -f "$KEY_FILE"

DMG_STAGE="$BUILD_DIR/dmg"
mkdir -p "$DMG_STAGE"
ditto "$APP" "$DMG_STAGE/MOUNTLI.app"
hdiutil create -volname MOUNTLI -srcfolder "$DMG_STAGE" -ov -format UDZO "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" --wait \
  | tee "$RELEASES/notarization-dmg.txt"
xcrun stapler staple "$DMG"

cp LICENSE THIRD_PARTY_NOTICES.txt "$RELEASES/"
tar -czf "$RELEASES/ThirdPartyLicenses.tar.gz" ThirdPartyLicenses
./Scripts/generate-sboms.sh "$RELEASES"
(
  cd "$RELEASES"
  shasum -a 256 \
    "MOUNTLI-$VERSION.zip" \
    "MOUNTLI-$VERSION.dmg" \
    appcast.xml \
    LICENSE \
    THIRD_PARTY_NOTICES.txt \
    ThirdPartyLicenses.tar.gz \
    ./*.cdx.json > SHA256SUMS
)

codesign --verify --deep --strict --verbose=2 "$APP"
spctl --assess --type execute --verbose=2 "$APP"
xcrun stapler validate "$APP"
xcrun stapler validate "$DMG"
"$ROOT/Scripts/verify-release.sh" direct "$RELEASES" "$VERSION" "$ARCHIVE"
