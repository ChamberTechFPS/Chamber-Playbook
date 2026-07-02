================================================================
  Chamber — Executables Folder
================================================================

Place the following installers in this folder BEFORE packaging
the playbook into .apbx format:

1. DirectX End-User Runtime
   - Download from Microsoft:
     https://www.microsoft.com/en-us/download/details.aspx?id=35
   - Extract the downloaded package
   - Place the extracted folder here as: DirectX/DXSETUP.exe
   - Final path: Executables/DirectX/DXSETUP.exe

2. Visual C++ Redistributables All-in-One
   - Download the "Visual C++ Redistributable Runtimes All-in-One"
     package (covers 2005, 2008, 2010, 2012, 2013, 2015-2022)
   - Rename or repackage as: vcredist_all.exe
   - Final path: Executables/vcredist_all.exe

IMPORTANT: If these files are not present, the playbook will
skip their installation and continue normally. Game launchers
and optional tools are installed via winget and do NOT need
to be placed here.

================================================================
