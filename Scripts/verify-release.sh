#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHANNEL="${1:?usage: verify-release.sh app-store|direct ARTIFACT_DIR VERSION [ARCHIVE]}"
ARTIFACT_DIR="${2:?artifact directory required}"
VERSION="${3:?version required}"
ARCHIVE="${4:-}"
[[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || {
  echo "Version must be exact SemVer" >&2
  exit 1
}
: "${MOUNTLI_ENCRYPTION_EXPORT_COMPLIANCE_CODE:?Export compliance value is required for release verification}"

verify_archive() {
  local archive="$1" expected_host="$2" expected_provider="$3" expected_ui="$4"
  local app="$archive/Products/Applications/MOUNTLI.app"
  [[ -d "$app" ]] || { echo "Archived MOUNTLI.app missing from $archive" >&2; return 1; }
  codesign --verify --deep --strict --verbose=2 "$app"
  python3 - "$app" "$VERSION" "$MOUNTLI_ENCRYPTION_EXPORT_COMPLIANCE_CODE" \
    "$expected_host" "$expected_provider" "$expected_ui" <<'PY'
from pathlib import Path
import json, plistlib, sys
app = Path(sys.argv[1])
version, compliance, host_id, provider_id, ui_id = sys.argv[2:]
info = plistlib.loads((app / "Contents/Info.plist" if (app / "Contents").is_dir() else app / "Info.plist").read_bytes())
if info.get("CFBundleIdentifier") != host_id:
    raise SystemExit(f"host bundle id mismatch: {info.get('CFBundleIdentifier')}")
if info.get("CFBundleShortVersionString") != version:
    raise SystemExit(f"archive version mismatch: {info.get('CFBundleShortVersionString')}")
if info.get("ITSAppUsesNonExemptEncryption") is not True:
    raise SystemExit("ITSAppUsesNonExemptEncryption must be true for the reviewed classification")
if info.get("ITSEncryptionExportComplianceCode") != compliance:
    raise SystemExit("archive does not contain the production export-compliance code")

plugin_root = app / "Contents/PlugIns" if (app / "Contents").is_dir() else app / "PlugIns"
plugins = list(plugin_root.glob("*.appex"))
ids = {}
for plugin in plugins:
    plugin_info_path = plugin / "Contents/Info.plist" if (plugin / "Contents").is_dir() else plugin / "Info.plist"
    plugin_info = plistlib.loads(plugin_info_path.read_bytes())
    ids[plugin_info.get("CFBundleIdentifier")] = plugin
    if plugin_info.get("ITSAppUsesNonExemptEncryption") is not True:
        raise SystemExit(f"extension encryption classification missing from {plugin}")
    if plugin_info.get("ITSEncryptionExportComplianceCode") != compliance:
        raise SystemExit(f"extension export-compliance code missing from {plugin}")
for expected in (provider_id, ui_id):
    if expected not in ids:
        raise SystemExit(f"embedded extension is missing approved identifier {expected}; found {sorted(ids)}")

bundles = [app, *plugins]
for bundle in bundles:
    resources = bundle / "Contents/Resources" if (bundle / "Contents").is_dir() else bundle
    manifest_path = resources / "PrivacyInfo.xcprivacy"
    if not manifest_path.is_file():
        raise SystemExit(f"privacy manifest missing from executable bundle {bundle}")
    manifest = plistlib.loads(manifest_path.read_bytes())
    if manifest.get("NSPrivacyTracking") is not False or manifest.get("NSPrivacyCollectedDataTypes") != []:
        raise SystemExit(f"privacy declaration is not Data Not Collected in {bundle}")
    reasons = {
        item.get("NSPrivacyAccessedAPIType"): set(item.get("NSPrivacyAccessedAPITypeReasons", []))
        for item in manifest.get("NSPrivacyAccessedAPITypes", [])
    }
    if "CA92.1" not in reasons.get("NSPrivacyAccessedAPICategoryUserDefaults", set()):
        raise SystemExit(f"UserDefaults required reason missing from {bundle}")
    if "C617.1" not in reasons.get("NSPrivacyAccessedAPICategoryFileTimestamp", set()):
        raise SystemExit(f"file timestamp required reason missing from {bundle}")

host_resources = app / "Contents/Resources" if (app / "Contents").is_dir() else app
for name in ("LICENSE", "THIRD_PARTY_NOTICES.txt", "ThirdPartyLicenses"):
    if not (host_resources / name).exists():
        raise SystemExit(f"bundled legal artifact missing: {name}")
PY
}

case "$CHANNEL" in
  app-store)
    verify_archive "$ARTIFACT_DIR/MOUNTLI-iOS.xcarchive" \
      ch.benavo.mountli ch.benavo.mountli.fileprovider.ios ch.benavo.mountli.fileproviderui.ios
    verify_archive "$ARTIFACT_DIR/MOUNTLI-macOS.xcarchive" \
      ch.benavo.mountli ch.benavo.mountli.fileprovider.macos ch.benavo.mountli.fileproviderui.macos
    compgen -G "$ARTIFACT_DIR/iOS/*.ipa" >/dev/null || { echo "iOS IPA missing" >&2; exit 1; }
    compgen -G "$ARTIFACT_DIR/macOS/*.pkg" >/dev/null || { echo "macOS installer package missing" >&2; exit 1; }
    ;;
  direct)
    [[ -n "$ARCHIVE" ]] || { echo "Direct archive path is required" >&2; exit 1; }
    verify_archive "$ARCHIVE" \
      ch.benavo.mountli ch.benavo.mountli.fileprovider.macos ch.benavo.mountli.fileproviderui.macos
    for artifact in \
      "MOUNTLI-$VERSION.zip" "MOUNTLI-$VERSION.dmg" appcast.xml SHA256SUMS \
      LICENSE THIRD_PARTY_NOTICES.txt ThirdPartyLicenses.tar.gz \
      mountli-go.cdx.json mountli-source.cdx.json notarization-zip.txt notarization-dmg.txt; do
      [[ -s "$ARTIFACT_DIR/$artifact" ]] || { echo "Required direct artifact missing: $artifact" >&2; exit 1; }
    done
    grep -Fq "sparkle:version" "$ARTIFACT_DIR/appcast.xml"
    grep -Fq "sparkle:edSignature" "$ARTIFACT_DIR/appcast.xml"
    grep -Fq "MOUNTLI-$VERSION.zip" "$ARTIFACT_DIR/appcast.xml"
    (cd "$ARTIFACT_DIR" && shasum -a 256 -c SHA256SUMS)
    python3 - "$ARTIFACT_DIR" <<'PY'
from pathlib import Path
import json, sys
for path in Path(sys.argv[1]).glob("*.cdx.json"):
    document = json.loads(path.read_text())
    if document.get("bomFormat") != "CycloneDX" or not document.get("components"):
        raise SystemExit(f"invalid or empty CycloneDX SBOM: {path}")
PY
    ;;
  *)
    echo "Unknown release channel: $CHANNEL" >&2
    exit 2
    ;;
esac
