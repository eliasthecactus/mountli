# App Review Notes

MOUNTLI is a replicated File Provider utility. Its host and extensions require exact App IDs, a shared App Group, and matching distribution profiles. The production targets do not claim the development-only FileProvider Testing Mode entitlement; the standard File Provider extension is reviewed with the app.

## Supplied review path

The production review build uses a least-privilege read/write WebDAV demo owned for review. Reviewers do not need their own server or MOUNTLI account.

1. Launch MOUNTLI and choose **Remotes → Add Remote → WebDAV**.
2. Copy the server URL, username, and password from the App Review sign-in fields/notes. The values are injected by the protected `production` environment (`APP_REVIEW_WEBDAV_USERNAME`, `APP_REVIEW_WEBDAV_PASSWORD`, and `APP_REVIEW_NOTES`); they are never committed to source or printed by a workflow.
3. Keep the vendor set to **Other**, accept the default TLS verification, save the remote, and run **Test Connection**.
4. Choose **Mounts → Add Mount**, select the supplied `review-fixture` directory as root, name it **MOUNTLI Review**, and add it to Files/Finder.
5. In Files/Finder, open `Welcome.txt`, duplicate it, edit the duplicate, rename it, create a folder, move the file into it, download it again, and delete the copy. The original fixture remains available for the next reviewer.
6. Return to MOUNTLI. **Activity** shows the completed operations; **Issues** explains any network/authentication recovery.

Attach the current short screen capture to App Review metadata. It must show adding the File Provider location in Files/Finder and completing the create/edit/rename/delete path; this is required whenever the File Provider control is not discoverable from the review build alone.

## Fixture operations

- Before submission, run the protected fixture reset job, verify read/write access with the release candidate, and confirm the account can access only `review-fixture`.
- Never place personal/customer data or release secrets in the fixture.
- After review, reset non-sensitive content and rotate/revoke the password. Rotate immediately after suspected disclosure or when review completes.
- App Store/TestFlight promotion is blocked when any review contact field, fixture credential, real screenshot set, or signed entitlement/profile capture is absent.

## Privacy declarations

MOUNTLI collects no data for benavo.ch: no account, analytics, advertising, telemetry, hosted relay, or automatic diagnostic upload. The app connects directly to user-selected storage providers. Configuration is encrypted on device. Apple may locally materialize decrypted content through File Provider.

The source-of-truth declaration is `Config/AppPrivacy.json`; `make validate-privacy` verifies it against the bundled privacy manifest and App Store metadata. App Store Connect’s detailed App Privacy answers have no documented API and therefore must be set manually to **Data Not Collected** and checked against this file before submission. User-initiated diagnostics remain on device until the user explicitly exports them. Storage providers and Apple process data under their own policies.

## Encryption export

MOUNTLI uses Apple CryptoKit for local configuration protection; rclone v1.75.0 for TLS, SSH, provider authentication, and user-configured Crypt; and Sparkle 2.9.5 in the direct Mac channel for EdDSA update verification. `Config/EncryptionExport.json` intentionally records a conservative pending `ITSAppUsesNonExemptEncryption = true` classification. Before the first TestFlight or App Store upload, submit the encryption questionnaire/documentation to Apple or obtain qualified export review, set the record to `approved` with reviewer/date, and store Apple’s issued compliance code only in the protected production environment. `make validate-encryption-export` checks all six product plists; release preflight additionally rejects a pending review or missing/placeholder code. Never switch the Boolean to `false` without documenting the completed exemption determination.

## Reviewer contact

mail@benavo.ch
