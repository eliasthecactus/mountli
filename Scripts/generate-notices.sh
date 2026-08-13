#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:---check}"
[[ "$MODE" == "--check" ]] || {
  echo "Notices are generated during dependency updates; only --check is supported in release verification." >&2
  exit 2
}

"$ROOT/Scripts/verify-licenses.sh"
python3 - "$ROOT/GoBridge" "$ROOT/THIRD_PARTY_NOTICES.txt" <<'PY'
from pathlib import Path
import subprocess, sys

bridge = Path(sys.argv[1])
notices_path = Path(sys.argv[2])
generated = subprocess.check_output(
    ["go-licenses", "report", "./..."],
    cwd=bridge,
    text=True,
).splitlines()
recorded = [
    line
    for line in notices_path.read_text().splitlines()
    if line and not line.startswith("MOUNTLI ") and not line.startswith("This distribution ")
    and line != "Package,License URL,SPDX license"
]
if sorted(generated) != sorted(recorded):
    missing = sorted(set(generated) - set(recorded))
    stale = sorted(set(recorded) - set(generated))
    details = []
    if missing:
        details.append("missing: " + ", ".join(missing))
    if stale:
        details.append("stale: " + ", ".join(stale))
    raise SystemExit("THIRD_PARTY_NOTICES.txt does not match the linked package graph; " + "; ".join(details))
print(f"Third-party notice snapshot matches {len(generated)} linked packages")
PY
