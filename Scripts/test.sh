#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

./Scripts/build-bridge.sh
(
  cd GoBridge
  go test -race ./...
  go vet ./...
)
swift test --package-path Packages/MountliCore
swift test --package-path Packages/MountliFileProvider
xcodegen generate
xcodebuild -project MOUNTLI.xcodeproj -scheme MOUNTLI-macOS -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project MOUNTLI.xcodeproj -scheme MOUNTLI-macOS-Direct -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project MOUNTLI.xcodeproj -scheme MOUNTLI-iOS -configuration Debug -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
