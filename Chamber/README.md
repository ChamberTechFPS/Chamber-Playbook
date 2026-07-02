# Chamber — Professional Gaming PC Setup

Chamber is an AME Wizard playbook that transforms a fresh Windows 11 install into a competition-ready gaming machine in one click. It applies performance optimizations, removes bloatware, configures privacy settings, and installs all gaming software.

---

## Prerequisites

- **Fresh Windows 11 installation** (22H2, 23H2, or 24H2 supported)
- **No pending Windows Updates** — install all updates first, then run the playbook
- **No third-party antivirus** — uninstall any AV before running (Windows Defender is handled by the playbook)
- **Internet connection** — required for winget-based app installations
- **AME Wizard** — download from ameliorated.io

---

## Adding DirectX & C++ Installers

Before packaging, place these files in the `Executables/` folder:

1. **DirectX End-User Runtime**
   - Download from Microsoft (DirectX End-User Runtime Web Installer)
   - Extract and place as `Executables/DirectX/DXSETUP.exe`

2. **Visual C++ Redistributables All-in-One**
   - Download a VC++ Redist all-in-one package (covers 2005–2022)
   - Place as `Executables/vcredist_all.exe`

> If these files are absent, the playbook skips them and continues normally.

---

## Packaging into .apbx

### Option 1: 7-Zip CLI (Recommended)
```
7z a -p"malte" -mhe=on "Chamber.apbx" "./Chamber/*" "-xr!*.apbx"
```

### Option 2: PowerShell + 7-Zip GUI
```powershell
# First create a zip
Compress-Archive -Path "Chamber/*" -DestinationPath "Chamber.zip"
# Remove any existing .apbx artifact from the ZIP before converting
# Then open in 7-Zip, set password to "malte", save as Chamber.apbx
```

### Option 3: 7-Zip GUI
1. Select all files inside the `Chamber/` folder
2. Right-click > 7-Zip > Add to archive
3. Archive format: **7z**
4. Encryption password: **malte**
5. Check "Encrypt file names"
6. Change the output filename extension to `.apbx`

---

## Balanced Windows App Removal
The debloat phase removes both installed and provisioned copies of obvious consumer inbox apps where present:

- Outlook/Mail, Solitaire, Teams, Clipchamp, Copilot, Widgets, Phone Link, Bing/MSN apps, Feedback Hub/Get Help/Tips, media apps, Family/People/To Do, Power Automate, Whiteboard, Maps, Office hub, Power BI, Spotify, Dev Home, LinkedIn, Skype, Cortana, and Mixed Reality Portal.
- Xbox app, Game Pass app, Xbox overlays, and Xbox identity packages are removed only when **Remove Xbox Services** is selected in AME Wizard.
- Chamber preserves Microsoft Store, App Installer/winget, Windows Security, Calculator, Notepad, Snipping Tool, Photos, Paint, Quick Assist, and Xbox/Game Pass unless Xbox removal is selected.

Removed apps can be reinstalled at any time from the Microsoft Store, which Chamber preserves.

## Anti-Cheat Compatibility
- **Vanguard (Valorant)**: Works. Keep **Secure Boot ON** — Vanguard requires it
- **Easy Anti-Cheat (Fortnite, CoD)**: Works with all Chamber settings
- **BattlEye**: Works normally
- **IMPORTANT**: Do **NOT** disable Secure Boot — multiple anti-cheats now require it

---

## What's Inside

| Phase | Description |
|-------|-------------|
| 1. Power Plan | Ultimate Performance plan, disable all sleep/hibernate |
| 2. BCD Tweaks | Timer precision, fast boot, TSC sync |
| 3. Services | Disable 15+ background services (telemetry, indexing, etc.) |
| 4. Registry | MMCSS priority, mouse accel off, memory mgmt, network TCP |
| 5. Privacy | Block telemetry at registry + firewall + hosts level |
| 6. Debloat | Remove balanced inbox bloat from installed and provisioned AppX packages |
| 7. Security | VBS/HVCI off, Smart App Control off, optional Defender/Update |
| 8. UI Config | Dark mode, clean taskbar, Explorer to This PC, classic context menu, file extensions |
| 9. Network | IFEO process priority demotions, TCP optimization |
| 10. Finalize | DirectX, C++ Redists, and browser choice |

---

**Chamber — Built for competitors.**
