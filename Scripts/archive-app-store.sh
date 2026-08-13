#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:?usage: archive-app-store.sh VERSION BUILD_NUMBER}"
BUILD_NUMBER="${2:?usage: archive-app-store.sh VERSION BUILD_NUMBER}"
: "${MOUNTLI_ENCRYPTION_EXPORT_COMPLIANCE_CODE:?Set the Apple-issued export compliance value}"
BUILD_DIR="${BUILD_DIR:-$ROOT/.build/app-store}"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cd "$ROOT"
./Scripts/build-bridge.sh
xcodegen generate

xcodebuild archive -project MOUNTLI.xcodeproj -scheme MOUNTLI-iOS -configuration Release \
  -archivePath "$BUILD_DIR/MOUNTLI-iOS.xcarchive" MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  MOUNTLI_ENCRYPTION_EXPORT_COMPLIANCE_CODE="$MOUNTLI_ENCRYPTION_EXPORT_COMPLIANCE_CODE"
xcodebuild -exportArchive -archivePath "$BUILD_DIR/MOUNTLI-iOS.xcarchive" \
  -exportPath "$BUILD_DIR/iOS" -exportOptionsPlist Config/ExportOptions/AppStore.plist

xcodebuild archive -project MOUNTLI.xcodeproj -scheme MOUNTLI-macOS -configuration Release \
  -archivePath "$BUILD_DIR/MOUNTLI-macOS.xcarchive" MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  MOUNTLI_ENCRYPTION_EXPORT_COMPLIANCE_CODE="$MOUNTLI_ENCRYPTION_EXPORT_COMPLIANCE_CODE"
xcodebuild -exportArchive -archivePath "$BUILD_DIR/MOUNTLI-macOS.xcarchive" \
  -exportPath "$BUILD_DIR/macOS" -exportOptionsPlist Config/ExportOptions/AppStore.plist
"$ROOT/Scripts/verify-release.sh" app-store "$BUILD_DIR" "$VERSION"
"$ROOT/Scripts/package-app-store-connect.sh" "$VERSION" "$BUILD_NUMBER"
