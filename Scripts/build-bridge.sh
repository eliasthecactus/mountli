#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GO_BRIDGE="$ROOT/GoBridge"
OUTPUT="$ROOT/Packages/MountliCore/Vendor/RcloneCore.xcframework"
TOOLS="$ROOT/.build-tools/bin"
GOMOBILE_VERSION="v0.0.0-20260709172247-6129f5bee9d5"

mkdir -p "$TOOLS" "$(dirname "$OUTPUT")"
rm -rf "$OUTPUT"

export GOBIN="$TOOLS"
export PATH="$TOOLS:$PATH"
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-0}"
export CGO_ENABLED=1

cd "$GO_BRIDGE"
go install "golang.org/x/mobile/cmd/gomobile@$GOMOBILE_VERSION"
go install "golang.org/x/mobile/cmd/gobind@$GOMOBILE_VERSION"
"$TOOLS/gomobile" init
"$TOOLS/gomobile" bind \
  -target=ios,iossimulator,macos \
  -iosversion=18.0 \
  -macosversion=15.0 \
  -trimpath \
  -ldflags="-s -w -buildid= -X github.com/rclone/rclone/fs.VersionSuffix=MOUNTLI" \
  -o "$OUTPUT" \
  ./mountli

touch -h -t 197001010000 "$OUTPUT" 2>/dev/null || true
