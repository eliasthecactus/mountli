#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT/MOUNTLI.xcodeproj"
[[ -f "$PROJECT/project.pbxproj" ]] || {
  echo "MOUNTLI.xcodeproj is not checked in; run make generate and commit it" >&2
  exit 1
}
command -v xcodegen >/dev/null || {
  echo "xcodegen 2.46.0 is required; run make bootstrap" >&2
  exit 1
}
XCODEGEN_VERSION="$(xcodegen version)"
[[ "$XCODEGEN_VERSION" == "Version: 2.46.0" || "$XCODEGEN_VERSION" == "2.46.0" ]] || {
  echo "xcodegen 2.46.0 is required, found $XCODEGEN_VERSION" >&2
  exit 1
}

TEMP="$(mktemp -d "${TMPDIR:-/tmp}/mountli-generated.XXXXXX")"
trap 'rm -rf "$TEMP"' EXIT
rsync -a \
  --exclude '.git/' \
  --exclude '.build/' \
  --exclude '.build-cache/' \
  --exclude '.bundle/' \
  --exclude 'DerivedData/' \
  "$ROOT/" "$TEMP/"
(
  cd "$TEMP"
  xcodegen generate
)

diff -u "$PROJECT/project.pbxproj" "$TEMP/MOUNTLI.xcodeproj/project.pbxproj"
diff -ru "$PROJECT/xcshareddata/xcschemes" "$TEMP/MOUNTLI.xcodeproj/xcshareddata/xcschemes"
"$ROOT/Scripts/generate-notices.sh" --check
"$ROOT/Scripts/generate-provider-snapshots.py" --check
"$ROOT/Scripts/validate-managed-config.py"
