#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NOTICES="$ROOT/THIRD_PARTY_NOTICES.txt"
LICENSES="$ROOT/ThirdPartyLicenses"

[[ -s "$ROOT/LICENSE" ]] || { echo "MIT LICENSE is missing" >&2; exit 1; }
[[ -s "$NOTICES" ]] || { echo "THIRD_PARTY_NOTICES.txt is missing" >&2; exit 1; }
[[ -d "$LICENSES" ]] || { echo "ThirdPartyLicenses is missing" >&2; exit 1; }
grep -Fq 'rclone v1.75.0' "$NOTICES" || { echo "notices do not identify pinned rclone" >&2; exit 1; }
grep -Fq 'Sparkle 2.9.5' "$NOTICES" || { echo "notices do not identify pinned Sparkle" >&2; exit 1; }

python3 - "$LICENSES" <<'PY'
from pathlib import Path
import sys
files = [path for path in Path(sys.argv[1]).rglob("*") if path.is_file() and path.name != ".DS_Store" and path.stat().st_size]
if len(files) < 10:
    raise SystemExit("ThirdPartyLicenses is unexpectedly incomplete")
print(f"Found {len(files)} bundled third-party license files")
PY

command -v go-licenses >/dev/null || {
  echo "go-licenses is required; run make bootstrap" >&2
  exit 1
}
(
  cd "$ROOT/GoBridge"
  go-licenses check ./... \
    --allowed_licenses=Apache-2.0,BSD-2-Clause,BSD-3-Clause,CC0-1.0,ISC,LGPL-3.0,MIT,MPL-2.0,Unlicense
)
