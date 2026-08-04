# Changelog

All notable changes to Chamber Playbook are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com); versions follow [SemVer](https://semver.org).

## [1.2.3] - 2026-08-04

### Changed
- **Windows Game Mode is now enforced on, unconditionally.** `AllowAutoGameMode` and `AutoGameModeEnabled` are written as `1` with no `option:` gate, and they are written *after* the Game Bar block so no feature-page selection can turn Game Mode back off. Previously the `disable-gamebar` checkbox — which ships **checked by default** — set both to `0`, silently disabling Game Mode on every install that accepted the defaults.
- `disable-gamebar` now does only what its name says: disables the Xbox Game Bar overlay and background DVR recording. Game Mode is no longer bundled into it.
- Dropped the "Not Recommended on Dual CCD CPUs" warning from the `disable-gamebar` label. That caveat existed only because the option used to disable Auto Game Mode; with Game Mode always on, the overlay/DVR toggle is safe on every CPU.

### Added
- Verification hard-fails when Game Mode is off. Since the two values carry no `option:`, `Verify-Chamber.ps1` reports them as `FAIL` rather than an informational optional-skip, so drift gets caught by the post-install check.

## [1.2.2] - 2026-08-04

### Removed
- `bcdedit /set useplatformtick yes` and `bcdedit /set disabledynamictick yes` from the Boot Performance phase (`Configuration/Tasks/2-bcd.yml`). Together these force Windows onto a fixed periodic timer tick instead of letting the kernel use the tickless/dynamic-tick path, which adds timer interrupt overhead on modern hardware without giving games any timer resolution they don't already get by default. The rest of phase 2 (`tscsyncpolicy Enhanced`, `bootux disabled`, `timeout 0`) is unchanged.
- Verification no longer checks these two BCD flags — `verification-manifest.json` was regenerated from the playbook source, so phase 2 now reports 2 BCD flags instead of 4.

### Upgrade notes
- This release only stops *setting* the flags; it does not undo them. On a machine already provisioned by v1.2.1 or earlier, clear them from an elevated Command Prompt and reboot:

  ```
  bcdedit /deletevalue useplatformtick
  bcdedit /deletevalue disabledynamictick
  ```

## [1.2.1] - 2026-07-08

### Fixed
- MMCSS `SystemResponsiveness` was set to `0`, which Windows clamps back up to `20` (per Microsoft's MMCSS docs, values below 10 are clamped to 20) — reserving 20% of CPU for background work, the opposite of the intent. Now set to `10`, the true minimum, for maximum foreground/gaming responsiveness.
- MMCSS `NetworkThrottlingIndex` (0xFFFFFFFF, disables the ~10 packets/ms multimedia throttle) was written under `HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters`, where MMCSS never reads it, so it had no effect. Moved to `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile`.
- Verification no longer reports a false failure for `NtfsDisableLastAccessUpdate` when Windows stamps the value system-managed (`0x80000001`) on large SSD volumes. Last-access updates are disabled in both the user-managed (`1`) and system-managed (`0x80000001`) states, so the verifier now compares only the enable/disable bit and ignores the Windows-owned system-managed flag.

## [1.1.1] - 2026-07-06

### Changed
- NTFS last-access updates are now disabled via `fsutil behavior set disablelastaccess 1` instead of a raw `NtfsDisableLastAccessUpdate` registry write, so NTFS picks it up immediately and the setting is stamped user-managed (Windows won't revert it to the system-managed default). Verification still checks the same registry value; the manifest generator derives it from the fsutil command.

## [1.1.0] - 2026-07-02

### Added
- Finalize phase now copies the Post-Install Companion to `C:\ChamberTech\PostInstall` and creates a "Chamber Post-Install" Desktop shortcut, so it's easy to find after reboot regardless of where the playbook was originally run from
- Windows 11 25H2 (build 26200) listed as supported in README (already supported in `playbook.conf`)
- Manifest-driven system verification: `tools/generate_verification_manifest.py` generates `PostInstall/Verify/verification-manifest.json` from the playbook YAML; Step 4 verification now checks all 80 registry tweaks, 20 services, BCD flags, hosts entries, and debloat targets against actual system state
- `-ClientReport` switch on verification: bundles results, logs, and system info into a Desktop zip for support
- JSON verification results saved to `C:\ProgramData\ChamberPostInstall\logs`
- GitHub Actions release pipeline: packages `Chamber.apbx` on tag push with SHA256 checksums
- Issue templates, contributing guide, license

### Changed
- Verification treats conditional tweaks (Xbox removal, VBS, Game Bar) as informational rather than failures, since option selections vary per install
- Post-Install simplified to Verify + Drivers only; the old guided launcher (DDU cleanup, MSI mode, repair/revert, optional apps flow) is retired in favor of manual driver installation plus the manifest-driven verifier. The retired scripts remain available on the `full-postinstall` branch.

### Fixed
- Release workflow's manifest-staleness check compared the full JSON including a `generatedUtc` timestamp that changes on every regeneration, so it would fail even when the manifest content was current. Now diffs with that field excluded.

### Known issues
- This release was packaged and archive-verified locally but has not completed a fresh-VM install + Post-Install verification pass before tagging.

## [1.0.0] - 2026-07-02

### Added
- Initial release: 10-phase optimization (power, BCD, services, registry, privacy, debloat, security, UI, network, finalize)
- Post-Install companion (`PostInstall/START-HERE.bat`): guided DDU driver cleanup, MSI mode, verification, repair/revert, optional apps, diagnostics
- Feature pages: security options, Xbox/gaming services, OLED safety, browser choice
- Anti-cheat safe: Secure Boot stays enabled; Vanguard/EAC/BattlEye compatible

### Upgrade path
- v1.0.0 is designed for fresh installs of Windows 11 22H2–25H2. No in-place upgrade path from other playbooks.
