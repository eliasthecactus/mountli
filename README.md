# MOUNTLI

**Rclone in Finder & Files.**

MOUNTLI is a free native app for iPhone, iPad, and Mac that exposes configured rclone remotes as Apple File Provider locations. Apple manages local materialization; MOUNTLI talks directly to storage providers. There is no MOUNTLI account, hosted relay, analytics, advertising, subscription, or paid tier.

## Status

MOUNTLI is under active development. The source architecture targets Swift 6, Xcode 26.6, iOS/iPadOS 18+, macOS 15+, Go 1.26, and rclone v1.75.2. Distribution builds require Apple signing, registered App IDs and App Group, and matching provisioning profiles; the production targets do not use the development-only FileProvider Testing Mode entitlement.

## Architecture

- `GoBridge/`: gomobile-safe rclone bridge with every statically compiled upstream backend.
- `Packages/MountliCore/`: domain, vault, policy, diagnostics, state, and bridge boundaries.
- `Packages/MountliFileProvider/`: replicated File Provider implementation.
- `App/`: shared SwiftUI host, platform entry points, File Provider extensions, and native assets.
- `Documentation/`: threat model, managed deployment, App Review, and release runbooks.

MOUNTLI intentionally does not use macFUSE, an rclone subprocess, the rclone RC server, runtime plugins, or a second VFS cache.

## Build

Prerequisites: Xcode 26.6 and [mise](https://mise.jdx.dev/). XcodeGen, Go, Ruby, gomobile, and release gems are pinned by the repository.

```sh
make bootstrap
make bridge
make generate
make test
```

Generated binary artifacts, including `RcloneCore.xcframework`, are not committed.

The `MOUNTLI-macOS` and `MOUNTLI-iOS` schemes are App Store products. `MOUNTLI-macOS-Direct` is a separately identified Developer ID product with Sparkle 2.9.5 updates. Signed distribution additionally requires exact App Group-enabled profiles and the scoped secrets listed in `Documentation/Release.md`. Every production tag packages upload-ready iOS IPA and Mac App Store PKG files as a private Actions artifact; the repository delivery-mode variable selects automatic App Store Connect upload or deferred Transporter upload.

## Security and privacy

Configuration is encrypted locally. File contents and credentials go directly between the device and storage providers selected by the user. Apple may materialize decrypted content in its protected File Provider cache. See [SECURITY.md](SECURITY.md), the [threat model](Documentation/ThreatModel.md), and the [benavo privacy policy](https://benavo.ch/privacy).

## License

MOUNTLI is MIT licensed. Embedded rclone and its dependencies retain their respective licenses; see `THIRD_PARTY_NOTICES.txt`.
