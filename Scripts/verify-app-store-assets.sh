#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCREENSHOTS="$ROOT/fastlane/screenshots/en-US"
[[ -d "$SCREENSHOTS" ]] || {
  echo "Versioned App Store screenshots are missing: fastlane/screenshots/en-US" >&2
  exit 1
}

python3 - "$ROOT" <<'PY'
from pathlib import Path
import json
import struct
import sys

root = Path(sys.argv[1])
screenshots = root / "fastlane/screenshots/en-US"
required_sizes = {
    "iPhone": (1242, 2688),
    "iPad": (2048, 2732),
    "Mac": (1440, 900),
}
for prefix, expected_size in required_sizes.items():
    files = [path for path in screenshots.glob(f"{prefix}-*.png") if path.stat().st_size > 10_000]
    if not files:
        raise SystemExit(f"missing non-placeholder {prefix} PNG screenshot fixture")
    for path in files:
        with path.open("rb") as stream:
            if stream.read(8) != b"\x89PNG\r\n\x1a\n":
                raise SystemExit(f"invalid PNG signature: {path}")
            length = struct.unpack(">I", stream.read(4))[0]
            if stream.read(4) != b"IHDR" or length != 13:
                raise SystemExit(f"invalid PNG IHDR: {path}")
            width, height = struct.unpack(">II", stream.read(8))
        if (width, height) != expected_size:
            raise SystemExit(f"{path.name} is {width}x{height}; expected {expected_size[0]}x{expected_size[1]}")

metadata = root / "fastlane/metadata/en-US"
expected_text = {
    "name.txt": "MOUNTLI",
    "subtitle.txt": "Rclone in Finder & Files",
    "privacy_url.txt": "https://benavo.ch/privacy",
    "support_url.txt": "https://benavo.ch/apps/mountli",
}
for name, expected in expected_text.items():
    actual = (metadata / name).read_text(encoding="utf-8").strip()
    if actual != expected:
        raise SystemExit(f"{name} must equal {expected!r}, found {actual!r}")
for name in ("description.txt", "keywords.txt", "release_notes.txt"):
    if not (metadata / name).read_text(encoding="utf-8").strip():
        raise SystemExit(f"required App Store metadata is empty: {name}")

rating = json.loads((root / "fastlane/metadata/age_rating.json").read_text(encoding="utf-8"))
for key, value in rating.items():
    if isinstance(value, str) and value != "NONE":
        raise SystemExit(f"age rating field {key} must be NONE for the 4+ declaration")
    if isinstance(value, bool) and value:
        raise SystemExit(f"age rating field {key} must be false for the 4+ declaration")
PY
