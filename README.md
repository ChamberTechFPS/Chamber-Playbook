# Chamber Playbook

**One-click competitive gaming optimization for Windows 11.**

Chamber Playbook is an [AME Wizard](https://ameliorated.io) playbook that turns a fresh Windows 11 install into a competition-ready gaming machine. It applies performance tweaks, strips out bloatware, locks down telemetry, and configures the system the way competitive players actually want it — all in one guided pass.

> ⚠️ **Anti-cheat safe:** Chamber Playbook keeps **Secure Boot ON** and is compatible with Vanguard, Easy Anti-Cheat, and BattlEye. See [Anti-Cheat Compatibility](#anti-cheat-compatibility).

---

## Table of Contents

- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [What It Does](#what-it-does)
- [Post-Install Companion](#post-install-companion)
- [Windows App Removal (Debloat)](#windows-app-removal-debloat)
- [Anti-Cheat Compatibility](#anti-cheat-compatibility)
- [Transparency & Verifying Downloads](#transparency--verifying-downloads)
- [Disclaimer](#disclaimer)

---

## Features

- 🚀 **Performance-first** — Ultimate Performance power plan, timer/BCD tuning, service trimming, and registry latency tweaks
- 🧹 **Balanced debloat** — removes consumer inbox apps while preserving the Store, winget, and Windows Security
- 🔒 **Privacy hardening** — blocks telemetry at the registry, firewall, and hosts level
- 🎮 **Competitor-focused UI** — dark mode, clean taskbar, classic context menu, file extensions on
- 🛡️ **Anti-cheat friendly** — Secure Boot stays on; no changes that trip Vanguard, EAC, or BattlEye
- 🔧 **Post-install companion** — organized driver install folders and full system verification
- ✅ **Verifiable** — every tweak is checked against actual system state by the built-in verification tool
- ♻️ **Reversible** — removed apps reinstall from the Microsoft Store anytime

---

## Requirements

| Requirement         | Details                                                          |
| ------------------- | ---------------------------------------------------------------- |
| **OS**              | Fresh Windows 11 install — 22H2, 23H2, 24H2, or 25H2             |
| **Windows Updates** | Install all pending updates *before* running                     |
| **Antivirus**       | Uninstall any third-party AV first (Defender is handled for you) |
| **Internet**        | Required for winget-based app installs                           |
| **AME Wizard**      | Download from [ameliorated.io](https://ameliorated.io)           |

> 25H2 (build 26200) validated on live hardware and client systems; fresh-install VM regression testing runs before each release.

---

## Installation

1. Download the latest `Chamber.apbx` from the [**Releases**](https://github.com/ChamberTechFPS/Chamber-Playbook/releases) page.
2. Download and open **AME Wizard** from [ameliorated.io](https://ameliorated.io).
3. Drag `Chamber.apbx` into AME Wizard.
4. Follow the on-screen options and let it run.
5. After reboot, run the **Post-Install Companion** (`PostInstall\START-HERE.bat`) to finish driver setup and verify everything applied.

> 💡 Chamber Playbook is designed for a clean install. Running it on a heavily customized system may produce mixed results.

---

## What It Does

| #  | Phase      | Description                                                                          |
| --- | ---------- | ------------------------------------------------------------------------------------ |
| 1  | Power Plan | Ultimate Performance plan; disables all sleep/hibernate                              |
| 2  | BCD Tweaks | Timer precision, fast boot, TSC sync                                                 |
| 3  | Services   | Disables 15+ background services (telemetry, indexing, etc.)                         |
| 4  | Registry   | MMCSS priority, mouse accel off, memory mgmt, network TCP                            |
| 5  | Privacy    | Blocks telemetry at registry + firewall + hosts level                                |
| 6  | Debloat    | Removes balanced inbox bloat (installed + provisioned AppX)                          |
| 7  | Security   | VBS/HVCI off, Smart App Control off, optional Defender/Update                        |
| 8  | UI Config  | Dark mode, clean taskbar, Explorer to This PC, classic context menu, file extensions |
| 9  | Network    | IFEO process priority demotions, TCP optimization                                    |
| 10 | Finalize   | DirectX, C++ Redists, and browser choice                                             |

---

## Post-Install Companion

Chamber ships with a simple post-install folder — run `PostInstall\START-HERE.bat` after the playbook finishes:

```
PostInstall/
├── START-HERE.bat       Menu: verify system, create support report, open drivers
├── Drivers/
│   ├── Chipset/         Install FIRST (AMD/Intel links inside), then reboot
│   ├── NVIDIA/          Drop your driver here — NVCleanstall recommended
│   └── AMD/             Driver-only install recommended
├── Tools/               DDU, HWiNFO, CapFrameX download links
└── Verify/              Manifest-driven verification
```

Verification is read-only and checks **every tweak the playbook applies** — all registry values, service states, BCD flags, hosts entries, and debloat targets — against actual system state, plus Secure Boot, VBS, HAGS, and MSI mode. The manifest is generated directly from the playbook source, so checks never drift from what the playbook actually does. Results save as JSON; option 2 creates a `ChamberReport` zip on the Desktop for support.

---

## Windows App Removal (Debloat)

The debloat phase removes both installed and provisioned copies of common consumer inbox apps where present:

> Outlook/Mail, Solitaire, Teams, Clipchamp, Copilot, Widgets, Phone Link, Bing/MSN apps, Feedback Hub/Get Help/Tips, media apps, Family/People/To Do, Power Automate, Whiteboard, Maps, Office hub, Power BI, Spotify, Dev Home, LinkedIn, Skype, Cortana, and Mixed Reality Portal.

- **Xbox** app, Game Pass app, overlays, and identity packages are removed **only** when *Remove Xbox Services* is selected in AME Wizard.
- Chamber Playbook **preserves**: Microsoft Store, App Installer/winget, Windows Security, Calculator, Notepad, Snipping Tool, Photos, Paint, Quick Assist, and Xbox/Game Pass (unless Xbox removal is selected).

Removed apps can be reinstalled at any time from the Microsoft Store, which Chamber Playbook preserves.

---

## Anti-Cheat Compatibility

| Anti-Cheat                          | Status  | Notes                                          |
| ----------------------------------- | ------- | ---------------------------------------------- |
| **Vanguard** (Valorant)             | ✅ Works | Keep **Secure Boot ON** — Vanguard requires it |
| **Easy Anti-Cheat** (Fortnite, CoD) | ✅ Works | Compatible with all Chamber Playbook settings  |
| **BattlEye**                        | ✅ Works | No changes needed                              |

> ❗ **Do NOT disable Secure Boot.** Multiple anti-cheats now require it, and Chamber Playbook is built to keep it enabled.

---

## Transparency & Verifying Downloads

- An `.apbx` is a renamed 7z archive (password `malte` — an AME Wizard convention to avoid antivirus false flags, not a secret). Open it with 7-Zip and read every file: it's plain-text YAML and PowerShell.
- Every release is built by [GitHub Actions](.github/workflows/release.yml) directly from this repository — no hand-built binaries.
- Each release includes `SHA256SUMS.txt` with checksums for the `.apbx` and every bundled script. Verify with `Get-FileHash Chamber.apbx` in PowerShell.
- Playbook actions execute via AME Wizard's open-source [TrustedUninstaller](https://github.com/Ameliorated-LLC/trusted-uninstaller-cli) backend.

---

## Disclaimer

Chamber Playbook makes significant changes to Windows. Use it on a **fresh install** and at your own risk. Always understand what a tweak does before applying it to a system you depend on.

## License

Chamber Playbook is licensed under [CC BY-NC-SA 4.0](LICENSE) — free to use, share, and adapt with attribution; commercial redistribution requires permission from ChamberTech LLC.

---

**Chamber Playbook — built for competitors.**
Part of the [ChamberTech](https://x.com/ChamberTech_) ecosystem · [YouTube](https://youtube.com/@ChamberTech) · Discord early access
