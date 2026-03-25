# Release Notes

## v0.1.0

Initial public release.

Included in this release:

- `disable_macos_updates.sh`
  Disables Apple-native macOS update checks, related `launchd` jobs, App Store auto-update settings, and writes a managed update-domain hosts blocklist.

- `clean_oclp_update_pollution.sh`
  Removes staged update files and cached update metadata that can interfere with OpenCore Legacy Patcher post-install root patching, then hardens key cache directories with `uchg`.

- `check_oclp_update_cleanliness.sh`
  Performs a read-only validation pass for update residue, mismatched version/build metadata, disabled jobs, disabled OCLP staged-update watchers, and frozen cache directories.

- `restore_macos_updates.sh`
  Re-enables Apple-native update behavior by restoring jobs, removing the managed hosts block, and clearing `uchg` flags on the hardened cache directories.

Validation baseline:

- Tested and iterated on `macOS 15.7.4 (24G517)`

Known limitation:

- `System Settings` may continue showing a Software Update badge even when the real update state has already been cleaned. In that situation, rely on `check_oclp_update_cleanliness.sh` rather than the sidebar badge alone.
