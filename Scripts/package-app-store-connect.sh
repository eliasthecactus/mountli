#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:?usage: package-app-store-connect.sh VERSION BUILD_NUMBER}"
BUILD_NUMBER="${2:?usage: package-app-store-connect.sh VERSION BUILD_NUMBER}"
BUILD_DIR="${BUILD_DIR:-$ROOT/.build/app-store}"
OUTPUT_DIR="${APP_STORE_UPLOAD_DIR:-$ROOT/.build/app-store-upload}"

[[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || {
  echo "Version must be exact SemVer" >&2
  exit 1
}
[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || {
  echo "Build number must be a positive integer" >&2
  exit 1
}

shopt -s nullglob
ios_packages=("$BUILD_DIR"/iOS/*.ipa)
mac_packages=("$BUILD_DIR"/macOS/*.pkg)
[[ ${#ios_packages[@]} -eq 1 ]] || { echo "Expected exactly one iOS IPA" >&2; exit 1; }
[[ ${#mac_packages[@]} -eq 1 ]] || { echo "Expected exactly one macOS PKG" >&2; exit 1; }

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR/AppStoreMetadata"
cp "${ios_packages[0]}" "$OUTPUT_DIR/MOUNTLI-iOS-$VERSION-$BUILD_NUMBER.ipa"
cp "${mac_packages[0]}" "$OUTPUT_DIR/MOUNTLI-macOS-$VERSION-$BUILD_NUMBER.pkg"
rsync -a --exclude '.DS_Store' --exclude '.gitkeep' "$ROOT/fastlane/metadata/" "$OUTPUT_DIR/AppStoreMetadata/metadata/"
rsync -a --exclude '.DS_Store' --exclude '.gitkeep' "$ROOT/fastlane/screenshots/" "$OUTPUT_DIR/AppStoreMetadata/screenshots/"

cat > "$OUTPUT_DIR/UPLOAD.txt" <<EOF
MOUNTLI $VERSION ($BUILD_NUMBER) — App Store Connect upload bundle

The IPA and PKG are already signed App Store distributions. Do not re-sign or rebuild them.

Automatic route:
  Set the GitHub repository variable APP_STORE_DELIVERY_MODE to upload before creating the release tag.
  The release workflow uploads both products to App Store Connect after archiving.

Manual route on a Mac:
  1. Verify the files: shasum -a 256 -c SHA256SUMS.txt
  2. Install and open Apple's Transporter app from the Mac App Store.
  3. Sign in with an App Store Connect account allowed to upload builds.
  4. Drag both the .ipa and .pkg into Transporter, then choose Deliver.
  5. Wait for both builds to finish processing in App Store Connect before assigning TestFlight groups or a version.

AppStoreMetadata contains the reviewed text, age rating, and screenshots for reference. Transporter uploads binaries, not store metadata. The release workflow's automatic route uploads that metadata through Fastlane.

Apple does not provide Transporter for Windows. From Windows, use the automatic GitHub Actions route rather than modifying these signed files.
EOF

(
  cd "$OUTPUT_DIR"
  shasum -a 256 ./*.ipa ./*.pkg > SHA256SUMS.txt
  shasum -a 256 -c SHA256SUMS.txt
)
