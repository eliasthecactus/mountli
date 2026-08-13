#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="${1:-$ROOT/.build/sbom}"
mkdir -p "$OUTPUT"
OUTPUT="$(cd "$OUTPUT" && pwd)"
VERSION="${VERSION:-$(python3 -c 'import re,sys; text=open(sys.argv[1], encoding="utf-8").read(); match=re.search(r"^MARKETING_VERSION\s*=\s*(\S+)", text, re.M); print(match.group(1) if match else "")' "$ROOT/Config/Base.xcconfig")}"
[[ -n "$VERSION" ]] || { echo "Unable to determine MARKETING_VERSION" >&2; exit 1; }

command -v cyclonedx-gomod >/dev/null || {
  echo "cyclonedx-gomod is required; run make bootstrap" >&2
  exit 1
}
command -v syft >/dev/null || {
  echo "syft is required; run make bootstrap" >&2
  exit 1
}

(
  cd "$ROOT/GoBridge"
  cyclonedx-gomod mod -json -noserial -output "$OUTPUT/mountli-go.cdx.json"
)
(
  cd "$ROOT"
  syft "dir:." \
    --source-name MOUNTLI \
    --source-version "$VERSION" \
    --exclude "./.build/**" \
    --exclude "./.bundle/**" \
    --exclude "./Packages/MountliCore/Vendor/**" \
    -o "cyclonedx-json=$OUTPUT/mountli-source.cdx.json"
)

for sbom in "$OUTPUT"/*.cdx.json; do
  python3 - "$sbom" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, encoding="utf-8") as stream:
    document = json.load(stream)
if document.get("bomFormat") != "CycloneDX" or not document.get("specVersion"):
    raise SystemExit(f"invalid CycloneDX SBOM: {path}")
document.pop("serialNumber", None)
metadata = document.get("metadata")
if isinstance(metadata, dict):
    metadata.pop("timestamp", None)
components = document.get("components")
if isinstance(components, list):
    components.sort(key=lambda item: (
        item.get("purl", ""),
        item.get("name", ""),
        item.get("version", ""),
        item.get("bom-ref", ""),
    ))
dependencies = document.get("dependencies")
if isinstance(dependencies, list):
    dependencies.sort(key=lambda item: item.get("ref", ""))
    for dependency in dependencies:
        if isinstance(dependency.get("dependsOn"), list):
            dependency["dependsOn"].sort()
with open(path, "w", encoding="utf-8") as stream:
    json.dump(document, stream, indent=2, sort_keys=True, ensure_ascii=False)
    stream.write("\n")
PY
done
