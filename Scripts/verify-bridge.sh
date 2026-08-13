#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FRAMEWORK="$ROOT/Packages/MountliCore/Vendor/RcloneCore.xcframework"
[[ -d "$FRAMEWORK" ]] || { echo "RcloneCore.xcframework is missing" >&2; exit 1; }

python3 - "$FRAMEWORK/Info.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], "rb") as stream:
    info = plistlib.load(stream)
libraries = info.get("AvailableLibraries", [])
platforms = {(item.get("SupportedPlatform"), tuple(sorted(item.get("SupportedArchitectures", []))), item.get("SupportedPlatformVariant")) for item in libraries}
required = {
    ("ios", ("arm64",), None),
    ("ios", ("arm64", "x86_64"), "simulator"),
    ("macos", ("arm64", "x86_64"), None),
}
missing = required - platforms
if missing:
    raise SystemExit(f"XCFramework lacks required platform/architecture slices: {sorted(missing, key=str)}; found {sorted(platforms, key=str)}")
PY

python3 - "$FRAMEWORK" <<'PY'
from pathlib import Path
import subprocess, sys
framework = Path(sys.argv[1])
binaries = [path for path in framework.rglob("RcloneCore") if path.is_file()]
if not binaries:
    raise SystemExit("No RcloneCore binaries found in XCFramework")
for binary in binaries:
    text = subprocess.check_output(["strings", str(binary)], text=True, errors="ignore").lower()
    forbidden = (
        "github.com/rclone/rclone/fs/rc/rcserver",
        "github.com/rclone/rclone/cmd/rcd",
        "github.com/rclone/rclone/cmd/mount",
        "github.com/rclone/rclone/cmd/mount2",
        "github.com/rclone/rclone/cmd/mountlib",
        "bazil.org/fuse",
        "github.com/winfsp",
        "macfuse",
    )
    if any(symbol in text for symbol in forbidden):
        raise SystemExit(f"forbidden RC server, mount, or FUSE package in {binary}")
PY
