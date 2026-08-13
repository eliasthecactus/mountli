# Changelog

Notable changes use [Keep a Changelog](https://keepachangelog.com/) categories. Public releases follow Semantic Versioning: incompatible vault, managed-policy, or automation contract changes increment the major version; backward-compatible features increment the minor version; fixes and dependency-only security updates increment the patch version. App Store build numbers increase independently and never reset.

The first production release is `1.0.0`. Until its signed tag is published, release content remains under **Unreleased**.

## [Unreleased]

### Added

- Native iPhone, iPad, and Mac hosts with replicated File Provider extensions.
- Complete rclone v1.75.0 backend catalog, dynamic configuration, OAuth, Crypt stacking, and encrypted import/export.
- Encrypted versioned vault, persistent SQLite operation journal, stable File Provider identities, conflict handling, network policies, managed policy, and manual diagnostics.
- Persistent Mac menu-bar status, direct Sparkle channel, App Store channel, CI, security scanning, and release automation.

### Changed

- Release archives now include a checksum-verified App Store Connect upload bundle for deferred Transporter or automated delivery.

### Fixed

- Add Remote and error sheets scroll within constrained windows, recurring empty states stay centered, and concurrent vault writers merge non-overlapping changes instead of surfacing revision churn.

[Unreleased]: https://github.com/eliasthecactus/mountli/commits/main
