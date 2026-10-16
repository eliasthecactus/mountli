# Threat Model

## Protected assets

- rclone credentials, OAuth refresh tokens, Crypt passwords, private keys, and known-hosts data
- decrypted user content materialized by Apple File Provider
- remote integrity, stable item identity, and configuration revision history
- release signing, notarization, Sparkle, and App Store Connect keys

## Trust boundaries

Mountli trusts the signed host and extensions, the Apple operating system and Keychain, the pinned rclone bridge, and storage providers explicitly configured by the user. Provider networks, remote content, imported configuration files, OAuth pages, filenames, and managed preferences are untrusted. Mountli operates no server and treats GitHub and App Store Connect as distribution infrastructure—not runtime data processors.

## Controls

- AES-GCM vault encryption with a non-synchronizing Keychain key and compare-and-swap revisions
- app-group sharing limited to the host and extensions; sandbox and network-client entitlements only
- no plaintext rclone config on disk; bridge config storage remains in memory
- private key and known-host imports copied into protected app-group storage with mode `0600`
- stable opaque File Provider identifiers; remote versions checked before and after downloads and before writes
- SQLite transactions, migrations, integrity checks, operation journaling, startup recovery, and bounded journal retention
- network-policy admission using `NWPathMonitor`; managed-policy values are validated and fail closed where required
- path-token logging and user-initiated, scrubbed diagnostics with no automatic upload
- device-owner authentication before exporting credentials
- signed tags, protected branches, CodeQL, dependency review, `govulncheck`, pinned bridge inputs, notarization, and Sparkle EdDSA signatures

## Known residual risks

A compromised operating system or unlocked user account can access materialized content. A configured provider can observe network metadata and content it stores. Backend API behavior may change outside Mountli’s control. Apple File Provider decides cache eviction and may retain protected local materialization. Security-scoped local folders depend on Apple sandbox behavior. rclone and transitive dependencies increase supply-chain and attack surface; monthly updates and weekly scans reduce but do not remove this risk.

## Security invariants

Credentials and raw paths never enter logs, analytics, issue reports, or diagnostics. Remote content never traverses a Mountli-operated service. Every remote mutation is version-checked where the backend exposes versions, journaled, cancellable, and mapped to a specific File Provider error. Update payloads are accepted only after Apple code-signing/notarization checks and Sparkle signature verification.
