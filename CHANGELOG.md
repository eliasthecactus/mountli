# Changelog

Notable changes use [Keep a Changelog](https://keepachangelog.com/) categories. Public releases follow Semantic Versioning: incompatible vault, managed-policy, or automation contract changes increment the major version; backward-compatible features increment the minor version; fixes and dependency-only security updates increment the patch version. App Store build numbers increase independently and never reset.

The first production release is `1.0.0`. Until its signed tag is published, release content remains under **Unreleased**.

## [Unreleased]

### Added

- Native iPhone, iPad, and Mac hosts with replicated File Provider extensions.
- Complete rclone v1.75.2 backend catalog, dynamic configuration, OAuth, Crypt stacking, and encrypted import/export.
- Encrypted versioned vault, persistent SQLite operation journal, stable File Provider identities, conflict handling, network policies, managed policy, and manual diagnostics.
- Persistent Mac menu-bar status, direct Sparkle channel, App Store channel, CI, security scanning, and release automation.

### Changed

- Release archives now include a checksum-verified App Store Connect upload bundle for deferred Transporter or automated delivery.
- Overview is a dashboard with a status summary, the next setup step, clickable counts, and per-location cards.
- Add Mount checks the connection automatically and preselects the only remote.
- Onboarding has a page indicator, Skip, and confirms added remotes and enabled alerts.
- Go 1.26.9 and rclone v1.75.2, which also picks up the fixed `golang.org/x/net`.
- The app is now called Mountli.
- Add and Edit Remote use a compact layout with Continue in the toolbar and a labelled name field.
- The accent color matches the brand emerald, so sidebar selections stay readable.

### Fixed

- Add Remote and error sheets scroll within constrained windows, recurring empty states stay centered, and concurrent vault writers merge non-overlapping changes instead of surfacing revision churn.
- Errors from rclone and the File Provider layer show what went wrong instead of `MountliCore.BridgeFailure error 1`.
- No "encrypted vault was not found" sheet at launch, and background polling no longer re-presents errors every few seconds.
- Mount and remote rows open their detail views on Mac and iPad.
- Errors inside Add Mount, Import, and Export sheets are shown instead of silently dropped.
- Issue actions on iPhone no longer all fire from a single tap.
- Renaming a mount updates its name in Finder and Files; duplicate mount names are rejected.
- Deleting a remote asks for confirmation.
- The menu bar icon is drawn at menu bar size instead of the mark's full 256 pt.
- Background refresh scheduling failures no longer appear as an unknown File Provider issue; orphaned locations can be removed.

[Unreleased]: https://github.com/eliasthecactus/mountli/commits/main
