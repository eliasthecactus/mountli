#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Credential-free engine integration: crypt over memory plus authenticated,
# certificate-validated WebDAV/TLS and host-key-validated SFTP/SSH loopback fixtures.
(
 cd GoBridge
 go test -race ./mountli -run '^(TestMemoryCryptRoundTrip|TestLoopbackWebDAVRoundTrip|TestLoopbackSFTPRoundTrip)$' -count=1
)

# Cross-package integration contracts run against temporary app-group databases and files.
swift test --package-path Packages/MountliCore --filter bridgeCatalogAndConfigurationEnvelopeDecode
swift test --package-path Packages/MountliCore --filter sqliteMigratesReconcilesAndKeepsIdentityAcrossRename
swift test --package-path Packages/MountliFileProvider --filter protectedStagesPreserveSparseOffsetsAndOnlyCleanInactiveFiles

# Optional live fixtures are explicit, bounded, and never silently skipped in protected CI.
if [[ "${MOUNTLI_REQUIRE_NETWORK_FIXTURES:-0}" == "1" ]]; then
  : "${MOUNTLI_TEST_WEBDAV_URL:?Set MOUNTLI_TEST_WEBDAV_URL in the protected fixture environment}"
  : "${MOUNTLI_TEST_WEBDAV_USERNAME:?Set MOUNTLI_TEST_WEBDAV_USERNAME}"
  : "${MOUNTLI_TEST_WEBDAV_PASSWORD:?Set MOUNTLI_TEST_WEBDAV_PASSWORD}"
  : "${MOUNTLI_TEST_SFTP_HOST:?Set MOUNTLI_TEST_SFTP_HOST}"
  : "${MOUNTLI_TEST_SFTP_USERNAME:?Set MOUNTLI_TEST_SFTP_USERNAME}"
  : "${MOUNTLI_TEST_SFTP_PRIVATE_KEY_BASE64:?Set MOUNTLI_TEST_SFTP_PRIVATE_KEY_BASE64}"
  [[ -x "${MOUNTLI_NETWORK_FIXTURE_DRIVER:-}" ]] || {
    echo "MOUNTLI_NETWORK_FIXTURE_DRIVER must name the reviewed executable fixture driver" >&2
    exit 1
  }
  "$MOUNTLI_NETWORK_FIXTURE_DRIVER"
fi
