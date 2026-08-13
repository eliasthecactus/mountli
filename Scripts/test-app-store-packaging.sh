#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP="$(mktemp -d "${TMPDIR:-/tmp}/mountli-app-store-package.XXXXXX")"
trap 'rm -rf "$TEMP"' EXIT
mkdir -p "$TEMP/source/iOS" "$TEMP/source/macOS"
printf 'signed iOS fixture' > "$TEMP/source/iOS/MOUNTLI.ipa"
printf 'signed macOS fixture' > "$TEMP/source/macOS/MOUNTLI.pkg"

BUILD_DIR="$TEMP/source" APP_STORE_UPLOAD_DIR="$TEMP/upload" \
  "$ROOT/Scripts/package-app-store-connect.sh" 1.2.3 42

[[ -s "$TEMP/upload/MOUNTLI-iOS-1.2.3-42.ipa" ]]
[[ -s "$TEMP/upload/MOUNTLI-macOS-1.2.3-42.pkg" ]]
[[ -s "$TEMP/upload/AppStoreMetadata/metadata/en-US/description.txt" ]]
[[ -s "$TEMP/upload/AppStoreMetadata/screenshots/en-US/iPhone-01-Welcome.png" ]]
[[ -s "$TEMP/upload/UPLOAD.txt" ]]
[[ ! -e "$TEMP/upload/AppStoreMetadata/metadata/.DS_Store" ]]
(
  cd "$TEMP/upload"
  shasum -a 256 -c SHA256SUMS.txt
)
