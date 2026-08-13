#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${MOUNTLI_SMOKE_APP:?Set MOUNTLI_SMOKE_APP to the signed archived MOUNTLI.app}"
DRIVER="${MOUNTLI_SMOKE_DRIVER:?Set MOUNTLI_SMOKE_DRIVER to the protected signed File Provider smoke driver}"
: "${MOUNTLI_TEST_WEBDAV_URL:?Set protected WebDAV fixture URL}"
: "${MOUNTLI_TEST_WEBDAV_USERNAME:?Set protected WebDAV fixture username}"
: "${MOUNTLI_TEST_WEBDAV_PASSWORD:?Set protected WebDAV fixture password}"

[[ -d "$APP" ]] || { echo "Signed smoke app does not exist: $APP" >&2; exit 1; }
[[ -x "$DRIVER" ]] || { echo "Signed smoke driver is not executable: $DRIVER" >&2; exit 1; }
codesign --verify --deep --strict --verbose=2 "$APP"

APP_ID="$(codesign -d --entitlements :- "$APP" 2>/dev/null | plutil -extract com.apple.application-identifier raw -)"
[[ "$APP_ID" == *.ch.benavo.mountli ]] || { echo "Unexpected signed host identifier: $APP_ID" >&2; exit 1; }
for extension in \
  "$APP/Contents/PlugIns/MountliFileProviderExtension.appex" \
  "$APP/Contents/PlugIns/MountliRecovery.appex"; do
  [[ -d "$extension" ]] || { echo "Missing embedded extension: $extension" >&2; exit 1; }
  codesign --verify --strict --verbose=2 "$extension"
done

cleanup() {
  "$DRIVER" cleanup --app "$APP" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

"$DRIVER" run \
  --app "$APP" \
  --webdav-url "$MOUNTLI_TEST_WEBDAV_URL" \
  --webdav-username "$MOUNTLI_TEST_WEBDAV_USERNAME" \
  --webdav-password-stdin <<EOF
$MOUNTLI_TEST_WEBDAV_PASSWORD
EOF
