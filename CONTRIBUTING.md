# Contributing

By participating, you agree to follow `CODE_OF_CONDUCT.md`.

1. Discuss substantial behavior or architecture changes in an issue first.
2. Branch from `main`; keep history linear and commits signed.
3. Use the pinned tools: `make bootstrap`.
4. Regenerate derived files with `make generate`; never hand-edit `MOUNTLI.xcodeproj` or `RcloneCore.xcframework`.
5. Run the focused checks for changed code and the relevant `make test-*` command.
6. Do not add telemetry, hosted relays, paid features, runtime plugins, macFUSE, broad filesystem access, plaintext credentials, or a second File Provider cache.

Every behavior change needs a test of its observable contract. Security-sensitive changes should state threat-model implications. Provider names and marks remain property of their owners.
