# Changelog

All notable changes to Chamber Playbook are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com); versions follow [SemVer](https://semver.org).

## [Unreleased]

### Added
- Finalize phase now copies the Post-Install Companion to `C:\ChamberTech\PostInstall` and creates a "Chamber Post-Install" Desktop shortcut, so it's easy to find after reboot regardless of where the playbook was originally run from

## [1.1.0] - 2026-07-02

### Added
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
