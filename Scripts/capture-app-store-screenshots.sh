#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="$ROOT/.build/app-store-screenshots"
OUTPUT="$ROOT/fastlane/screenshots/en-US"
RUNTIME="${MOUNTLI_SCREENSHOT_RUNTIME:-com.apple.CoreSimulator.SimRuntime.iOS-26-5}"
mkdir -p "$OUTPUT"
rm -rf "$DERIVED"
mkdir -p "$DERIVED"
cd "$ROOT"

./Scripts/build-bridge.sh
xcodegen generate

simulators=()
cleanup() {
  for udid in "${simulators[@]:-}"; do
    [[ -n "$udid" ]] || continue
    xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
    xcrun simctl delete "$udid" >/dev/null 2>&1 || true
  done
}
trap cleanup EXIT INT TERM

export_attachment() {
  local result="$1" attachments="$2" destination="$3" height="$4" width="$5"
  rm -rf "$attachments"
  xcrun xcresulttool export attachments --path "$result" --output-path "$attachments"
  local candidates=("$attachments"/*.png)
  [[ -f "${candidates[0]}" ]] || { echo "No PNG screenshot attachment exported from $result" >&2; return 1; }
  sips --resampleHeightWidth "$height" "$width" "${candidates[0]}" --out "$destination" >/dev/null
}

capture_simulator() {
  local name="$1" device_type="$2" destination="$3" height="$4" width="$5"
  local udid
  udid="$(xcrun simctl create "MOUNTLI $name Screenshot $$" "$device_type" "$RUNTIME")"
  simulators+=("$udid")
  xcrun simctl boot "$udid"
  xcrun simctl bootstatus "$udid" -b
  xcrun simctl ui "$udid" appearance light
  xcrun simctl status_bar "$udid" override --time 9:41 --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4

  local result="$DERIVED/$name.xcresult"
  MOUNTLI_CAPTURE_SCREENSHOTS=1 xcodebuild test \
    -project MOUNTLI.xcodeproj \
    -scheme MOUNTLI-iOS \
    -configuration Debug \
    -derivedDataPath "$DERIVED/DerivedData" \
    -destination "platform=iOS Simulator,id=$udid" \
    -only-testing:MountliUITests-iOS/MountliUITests/testCaptureAppStoreScreenshot \
    -resultBundlePath "$result" \
    CODE_SIGNING_ALLOWED=NO
  export_attachment "$result" "$DERIVED/$name-attachments" "$OUTPUT/$destination" "$height" "$width"
  xcrun simctl shutdown "$udid"
  xcrun simctl delete "$udid"
}

capture_simulator \
  iPhone \
  com.apple.CoreSimulator.SimDeviceType.iPhone-11-Pro-Max \
  iPhone-01-Welcome.png \
  2688 1242
capture_simulator \
  iPad \
  com.apple.CoreSimulator.SimDeviceType.iPad-Pro--12-9-inch---3rd-generation- \
  iPad-01-Welcome.png \
  2732 2048

mac_result="$DERIVED/Mac.xcresult"
xcodebuild build-for-testing \
  -project MOUNTLI.xcodeproj \
  -scheme MOUNTLI-macOS \
  -configuration Debug \
  -derivedDataPath "$DERIVED/DerivedData" \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:MountliUITests-macOS/MountliUITests/testCaptureAppStoreScreenshot \
  CODE_SIGNING_ALLOWED=NO
run_macos_capture() {
  MOUNTLI_CAPTURE_SCREENSHOTS=1 xcodebuild test-without-building \
    -project MOUNTLI.xcodeproj \
    -scheme MOUNTLI-macOS \
    -configuration Debug \
    -derivedDataPath "$DERIVED/DerivedData" \
    -destination 'platform=macOS,arch=arm64' \
    -only-testing:MountliUITests-macOS/MountliUITests/testCaptureAppStoreScreenshot \
    -resultBundlePath "$mac_result" \
    CODE_SIGNING_ALLOWED=NO
}
if ! run_macos_capture; then
  echo "Retrying macOS UI capture after XCTest runner bootstrap failure" >&2
  rm -rf "$mac_result"
  run_macos_capture
fi
export_attachment "$mac_result" "$DERIVED/Mac-attachments" "$OUTPUT/Mac-01-Welcome.png" 900 1440

"$ROOT/Scripts/verify-app-store-assets.sh"
