# Managed Deployment

MOUNTLI reads restriction-only values from `com.apple.configuration.managed`. Unknown or malformed values are ignored and produce a policy Issue rather than silently broadening access. Managed policy never accepts credentials, remote definitions, or resource-file contents.

Machine-readable deployment artifacts are checked in:

- `Config/ManagedAppConfig.schema.json` defines all supported keys, types, defaults, and bounds.
- `Config/ManagedProfiles/MOUNTLI-iOS.mobileconfig` is an example iOS/iPadOS managed app configuration payload.
- `Config/ManagedProfiles/MOUNTLI-macOS.mobileconfig` is an example macOS managed-preferences payload for `ch.benavo.mountli`.

Replace the example organization, UUIDs, support URL, and restrictions in a copy before signing and deploying through MDM. Do not deploy the sample unchanged.

## Policy keys

| Key | Type | Default | Effect |
| --- | --- | --- | --- |
| `PolicyVersion` | integer, exactly `1` | `1` | Selects this policy contract. |
| `AllowedBackendTypes` | unique backend-name array | all | Restricts creation and use to names in the pinned rclone catalog. |
| `AllowConfigImport` | Boolean | `true` | Enables rclone configuration import. |
| `AllowConfigExport` | Boolean | `true` | Enables authenticated export. |
| `AllowInsecureTLS` | Boolean | `false` | Permits the warned skip-verification setting. |
| `ForceReadOnly` | Boolean | `false` | Blocks new remote mutations while retaining cached and dirty data. |
| `AllowCellular` | Boolean | `true` | Allows remote work over cellular connections. |
| `MaximumConcurrentTransfers` | integer | platform default | Clamped to 1–4 on iOS/iPadOS and 1–8 on macOS. |
| `SupportURL` | absolute HTTPS URL | MOUNTLI support | Replaces the organization support destination. |

Policy wins over user settings. When a policy newly disallows a backend or forces read-only mode, MOUNTLI keeps cached content readable and preserves queued/dirty items for administrator resolution; it does not delete data.

## Validation

Run `make validate-managed-config`. The validator checks the JSON Schema, both plist payload shapes, platform transfer bounds, HTTPS support URL, and sample backend names against the exact rclone catalog resolved by `GoBridge/go.mod`.
