# Release Runbook

## Protected production prerequisites

The `production` GitHub environment requires approval and must contain only:

- `APPLE_DISTRIBUTION_CERTIFICATE_BASE64`, `APPLE_DISTRIBUTION_CERTIFICATE_PASSWORD`
- `DEVELOPER_ID_CERTIFICATE_BASE64`, `DEVELOPER_ID_CERTIFICATE_PASSWORD`
- `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_CONTENT` (base64 `.p8` for Fastlane)
- `ASC_API_PRIVATE_KEY_PEM` (the same least-privilege App Store Connect key as raw PEM for Apple’s profile-download action)
- `NOTARY_KEY_BASE64`, `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID`
- `SPARKLE_PRIVATE_KEY`
- `MOUNTLI_ENCRYPTION_EXPORT_COMPLIANCE_CODE` after the approved classification recorded in `Config/EncryptionExport.json`; placeholders and empty values fail
- Repository variable `RELEASE_SIGNING_PUBLIC_KEY_BASE64`, the public key trusted for release-tag verification
- App Review contact secrets, `APP_REVIEW_WEBDAV_URL`, `APP_REVIEW_WEBDAV_USERNAME`, `APP_REVIEW_WEBDAV_PASSWORD`, and `APP_REVIEW_CAPTURE_URL`

Create exact App Store and Developer ID provisioning profiles for the host `ch.benavo.mountli`, macOS extensions `ch.benavo.mountli.fileprovider.macos` and `ch.benavo.mountli.fileproviderui.macos`, and iOS extensions `ch.benavo.mountli.fileprovider.ios` and `ch.benavo.mountli.fileproviderui.ios`. The workflow downloads each identifier/profile type independently. Set `DIRECT_MAC_ENABLED=true` only after Apple approves the Developer ID File Provider entitlement and all three Developer ID profiles exist; otherwise the direct job is intentionally skipped and no DMG/appcast is claimed.

Use separate least-privilege App Store Connect and notarization keys. Rotate API keys, fixture credentials, and certificates on suspected disclosure or Apple expiry. Keep the Sparkle key encrypted offline; rotation requires a higher-version signed release.

## Gate

1. Update `CHANGELOG.md`, canonical `MARKETING_VERSION`, rclone pin, notices/licenses, privacy answers, App Review notes, real iPhone/iPad/Mac screenshots, and support compatibility text.
2. Run the named local contracts: `make verify-generated verify-bridge test-go test-swift test-integration test-ui validate-privacy validate-encryption-export verify-licenses`.
3. Complete the signed File Provider smoke and 24-hour soak on protected fixtures; no workflow substitutes an unsigned compile for this evidence.
4. Create an annotated, trusted-key-signed `vMAJOR.MINOR.PATCH` tag on protected `main`. There is no manual production trigger.
5. The workflow verifies exact SemVer/version equality, tag signature and commit, main ancestry, generated artifacts, quality/security matrices, privacy manifests, legal resources, export compliance, exact profiles, signatures, entitlements, notarization, appcast signature, checksums, and SBOMs.
6. A GitHub Release is created as a draft. Required assets and provenance attestations are uploaded and re-listed. Only then is the draft published. A direct DMG/ZIP/appcast is attached only when the Developer ID channel gate succeeds.
7. TestFlight and App Store phased promotion remain separate manual approvals after real-device Files/Finder validation.

## Rollback

App Store builds cannot be rolled back; stop phased release and submit a patch. For direct distribution, remove the bad appcast item and publish a higher-version signed patch. Never reuse a version or replace an already published signed artifact.
