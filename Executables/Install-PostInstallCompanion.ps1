#Requires -Version 5.1
<#
Copies the PostInstall companion folder to C:\ChamberTech\PostInstall and drops
a desktop shortcut to it, so it survives even if the user ran the playbook from
a USB drive or a temp download folder that won't be there after reboot.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$sourceDir = Join-Path $PSScriptRoot '..\PostInstall'
$destDir   = 'C:\ChamberTech\PostInstall'

if (-not (Test-Path $sourceDir)) {
    Write-Host "[WARN] PostInstall source not found at $sourceDir - skipping install."
    exit 0
}

robocopy $sourceDir $destDir /MIR /NFL /NDL /NJH /NJS | Out-Null
if ($LASTEXITCODE -ge 8) {
    Write-Host "[WARN] robocopy failed (exit $LASTEXITCODE) copying PostInstall to $destDir"
    exit 0
}

$desktop  = [Environment]::GetFolderPath('Desktop')
$shortcut = Join-Path $desktop 'Chamber Post-Install.lnk'

$shell = New-Object -ComObject WScript.Shell
$lnk = $shell.CreateShortcut($shortcut)
$lnk.TargetPath = $destDir
$lnk.WorkingDirectory = $destDir
$lnk.IconLocation = "$env:SystemRoot\System32\shell32.dll,3"
$lnk.Description = 'Chamber Post-Install - drivers and verification'
$lnk.Save()

Write-Host "Post-Install companion copied to $destDir and shortcut added to Desktop."
