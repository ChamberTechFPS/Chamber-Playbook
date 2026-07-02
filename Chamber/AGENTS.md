# Repository Guidelines

## Project Structure & Module Organization
`Configuration/main.yml` is entry point for AME Wizard and runs numbered phase files in `Configuration/Tasks/`. Keep task files ordered and named with numeric prefixes such as `1-power.yml` and `10-finalize.yml`. Store optional bundled installers and helper scripts in `Executables/`. Root files `playbook.conf` and `Chamber.apbx` are packaging artifacts.

## Build, Test, and Development Commands
Package from parent directory with `7z a -p"malte" -mhe=on "Chamber.apbx" "./Chamber/*" "-xr!*.apbx"`. End-to-end validation happens by loading `Chamber.apbx` into AME Wizard on a fresh Windows 11 install.

## Coding Style & Naming Conventions
YAML uses two-space indentation and one action per block. Keep status labels short and phase-specific. Preserve numeric ordering when adding new tasks. PowerShell should match existing scripts: `#Requires -Version 5.1`, `Set-StrictMode -Version Latest`, `$ErrorActionPreference = 'Stop'`, and approved Verb-Noun function names such as `Get-GpuVendor` or `Write-Header`. Prefer explicit paths and fail-fast behavior over silent recovery.

## Testing Guidelines
No automated test suite is checked in. Validate changes in an isolated VM or sacrificial fresh Windows 11 install. For task YAML, test only affected phase first, then full playbook run. For PowerShell, run elevated and verify both success path and skip/fallback path. Changes under `10-finalize.yml` must be tested with and without internet, `winget`, and optional `Executables/DirectX` or `vcredist_all.exe` payloads.

## Commit & Pull Request Guidelines
Local workspace has no `.git` metadata, so no commit history is available to mirror. Use short imperative subjects like `Add winget connectivity warning` or `Split OLED safety script`. PRs should list touched phases/scripts, Windows version tested (`22H2`, `23H2`, or `24H2`), VM vs. bare-metal coverage, and any user-visible menu or installer changes. Include rollback notes for registry, BCD, service, privacy, or security edits.

## Safety & Configuration Notes
This repository changes boot settings, services, registry, telemetry blocks, and optional security features. Test on non-production machines first. Do not add third-party installers to source control unless redistribution is allowed; place them in `Executables/` only for packaging and local release builds.
