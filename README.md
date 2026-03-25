# macos-update-clean-4-opencore

Shell scripts to:

- disable Apple-native macOS update checks, downloads, and user-facing notifications
- clean local update metadata that can interfere with OpenCore Legacy Patcher post-install patching
- verify whether the machine is still carrying update residue
- restore the Apple-native update chain if needed later

This repo exists for a narrow use case: keep a Mac stable on its current macOS build, reduce update-related state being written back locally, and prepare a cleaner environment for OpenCore Legacy Patcher root patching.

## What This Repo Does

`disable_macos_updates.sh`

- turns off scheduled `softwareupdate` checks
- disables update-related system and user `launchd` jobs
- writes a managed update-domain blocklist into `/etc/hosts`
- clears user-facing Software Update notification state where possible

`clean_oclp_update_pollution.sh`

- disables the OCLP staged-update watchers tied to `Preflight.plist` and `Update.plist`
- removes cached update metadata from `/Library/Updates` and `AssetsV2`
- clears Software Update recommendation and notification residue
- freezes several key cache directories with `uchg` so the same metadata is harder to recreate

`check_oclp_update_cleanliness.sh`

- performs a read-only validation pass
- checks for staged update files
- checks for version/build metadata that does not match the current system
- checks whether Apple update jobs and OCLP staged-update watchers are still disabled
- checks whether the key cache directories are frozen

`restore_macos_updates.sh`

- re-enables Apple-native update services
- removes the managed `/etc/hosts` block
- removes the `uchg` freeze from the hardened cache directories

## Verified Scope

- The scripts do not hardcode `15.7.4` or a single fixed build into the main execution flow.
- The cleanup and validation scripts read the current system `ProductVersion` and `BuildVersion` dynamically, then treat that as the clean baseline.
- The current behavior was validated on `macOS 15.7.4 (24G517)`.
- They are most likely to keep working on nearby macOS versions that still use the same Apple Software Update paths, plist keys, and `launchd` labels.
- If Apple changes those paths or labels in a future macOS release, the scripts will need adjustment.

## Quick Start

Run the full disable + cleanup + validation flow:

```bash
sudo zsh ./disable_macos_updates.sh
sudo zsh ./clean_oclp_update_pollution.sh
zsh ./check_oclp_update_cleanliness.sh
```

If the checker reports clean state, proceed with your OpenCore Legacy Patcher post-install work.

To restore normal Apple update behavior later:

```bash
sudo zsh ./restore_macos_updates.sh
```

## Dry Run

The mutating scripts support `--dry-run`:

```bash
sudo zsh ./disable_macos_updates.sh --dry-run
sudo zsh ./clean_oclp_update_pollution.sh --dry-run
sudo zsh ./restore_macos_updates.sh --dry-run
```

The checker is already read-only, so `--dry-run` there is informational only:

```bash
zsh ./check_oclp_update_cleanliness.sh --dry-run
```

## Example Workflow

Example for a machine that should stay on the current build and be prepared for OpenCore patching:

```bash
git clone https://github.com/RichardCao/macos-update-clean-4-opencore.git
cd macos-update-clean-4-opencore
sudo zsh ./disable_macos_updates.sh
sudo zsh ./clean_oclp_update_pollution.sh
zsh ./check_oclp_update_cleanliness.sh
```

Expected outcome:

- Apple-native update agents are disabled
- common update metadata files are removed
- key update cache directories are frozen with `uchg`
- the checker reports no obvious update pollution blocking OCLP post-install root patching

## Notes

- These scripts are intentionally aggressive. They modify `launchctl` state, `/etc/hosts`, update-related plist state, and filesystem flags.
- The hosts blocklist is a defense-in-depth layer, not the primary control.
- The `uchg` freeze is also a hardening layer, not a guarantee against every future Apple behavior change.
- `System Settings` can keep a Software Update badge even after the real update state is gone. If the checker is clean, that badge is usually UI residue rather than active update pollution.
- `restore_macos_updates.sh` restores service paths and writeability, but it does not reconstruct update cache files that were intentionally deleted earlier.

## License

MIT. See [LICENSE](./LICENSE).
