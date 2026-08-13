#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
[[ -f MOUNTLI.xcodeproj/project.pbxproj ]] || { echo "Run make generate first" >&2; exit 1; }

action=(xcodebuild -project MOUNTLI.xcodeproj -derivedDataPath "$ROOT/.build/ui")
"${action[@]}" -scheme MOUNTLI-macOS -configuration Debug \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO build

mac_app="$ROOT/.build/ui/Build/Products/Debug/MOUNTLI.app/Contents/MacOS/MOUNTLI"
mac_log="$ROOT/.build/ui/macos-smoke.log"
"$mac_app" -AppleLanguages '(en)' -AppleLocale en_US >"$mac_log" 2>&1 &
mac_pid=$!
sleep 2
if ! kill -0 "$mac_pid" 2>/dev/null; then
  wait "$mac_pid"
  echo "macOS app exited during launch smoke" >&2
  exit 1
fi
kill "$mac_pid"
wait "$mac_pid" 2>/dev/null || true

"${action[@]}" -scheme MOUNTLI-macOS-Direct -configuration Release \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO build
ios_destination="${MOUNTLI_IOS_SIMULATOR_DESTINATION:-}"
if [[ -z "$ios_destination" ]]; then
  ios_udid="$(xcrun simctl list devices available --json | python3 -c 'import json,sys; data=json.load(sys.stdin)["devices"]; devices=[d for runtime in sorted(data, reverse=True) if "iOS" in runtime for d in data[runtime] if d.get("isAvailable", True)]; preferred=[d for d in devices if d.get("state") == "Booted"] or [d for d in devices if d["name"].startswith("iPhone")] or devices; print(preferred[0]["udid"] if preferred else "")')"
  [[ -n "$ios_udid" ]] || { echo "No available iOS simulator" >&2; exit 1; }
  ios_destination="platform=iOS Simulator,id=$ios_udid"
fi
"${action[@]}" -scheme MOUNTLI-iOS -configuration Debug \
  -destination "$ios_destination" CODE_SIGNING_ALLOWED=NO test

# Generic-device Release builds prove every embedded extension participates in the graph.
"${action[@]}" -scheme MOUNTLI-iOS -configuration Release \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
