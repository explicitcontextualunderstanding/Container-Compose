# Fork Progress and Roadmap

We are leveraging `apple/container` v0.10.0 features to enhance `container-compose`.

## Completed Changes
- [x] **Standardized Argument Construction**: Refactored `ComposeUp.swift` to use a centralized `makeRunArgs` helper for consistent flag mapping.
- [x] **Entrypoint Positioning**: Fixed `--entrypoint` placement to ensure it's passed in the correct position relative to the image name.
- [x] **Shared Utilities**: Extracted `streamCommand` and `deriveProjectName` into `Helper Functions.swift` for cross-command use.
- [x] **Service Property Restoration**: Restored `runtime`, `init`, and `init_image` support in `Service.swift`.
- [x] **Checkpoint Subcommand**: Added a new `checkpoint` subcommand that utilizes `container commit` to save the state of a running service.
- [x] **Verification**: Added `ComposeUpMappingTests` to validate correct flag generation for `entrypoint`, `init`, and `restart` policies.

## Planned Changes
- [x] **Restart Policy Mapping**: Finalized mapping of Compose `restart:` keys to engine `--restart` flags.
- [x] **Advanced Init Support**: Enhanced `init: true` and `--init-image` selection logic.
- [x] **Network/Volume Sync**: Improved synchronization of top-level network and volume definitions with the container engine.

---
*Last Updated: 2026-02-28*
*Release Version: 0.10.0*
