#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\Shared.ps1"

[void](Initialize-ChamberLog -Name 'safe-mode-ddu')
Assert-Admin
Set-StepStatus -Step 'DDU' -Status running

Write-Header 'Step 2 - Clean Driver Install (DDU + Safe Mode)'

if (Test-StateFlag 'ddu_complete') {
    Write-Host '  DDU is already marked complete.' -ForegroundColor Green
    Write-Host ''
    Wait-AnyKey '  Press any key to return to the menu...'
    return
}

if (Test-StateFlag 'ddu_scheduled') {
    Write-Host '  DDU is already scheduled or mid-resume.' -ForegroundColor Yellow
    Write-Host '  If the machine has already returned to normal mode, run the launcher again' -ForegroundColor DarkGray
    Write-Host '  so it can resolve the resume state.' -ForegroundColor DarkGray
    Write-Host ''
    Wait-AnyKey '  Press any key to return to the menu...'
    return
}

$vendor = Get-GpuVendor
$dduExe = $null

$dduPathFile = Join-Path $script:StateDir 'ddu_path.txt'
if (Test-Path -LiteralPath $dduPathFile) {
    $saved = [System.IO.File]::ReadAllText($dduPathFile).Trim()
    if (Test-Path -LiteralPath $saved) { $dduExe = $saved }
}

if (-not $dduExe) {
    $toolsDir = Join-Path $PSScriptRoot '..\tools'
    $stagedDdu = Join-Path $toolsDir 'Display Driver Uninstaller.exe'
    if (Test-Path -LiteralPath $stagedDdu) {
        $dduExe = $stagedDdu
    }
}

if (-not $dduExe) {
    Write-Host '  DDU executable not found automatically.' -ForegroundColor Yellow
    Write-Host '  Please enter the full path to "Display Driver Uninstaller.exe",' -ForegroundColor White
    Write-Host '  or press Enter to open the download page and abort this step.' -ForegroundColor White
    Write-Host ''
    $manualPath = Read-Host '  DDU path'
    if (-not $manualPath) {
        Start-Process 'https://www.wagnardsoft.com/display-driver-uninstaller-DDU-'
        Write-Host '  Download DDU, re-run Step 1, then re-run this step.' -ForegroundColor Yellow
        Write-Host ''
        Wait-AnyKey '  Press any key to return to the menu...'
        Set-StepStatus -Step 'DDU' -Status skipped -Detail 'DDU executable missing.'
        return
    }
    if (-not (Test-Path -LiteralPath $manualPath)) {
        Write-Host "  File not found: $manualPath" -ForegroundColor Red
        Wait-AnyKey '  Press any key to return to the menu...'
        Set-StepStatus -Step 'DDU' -Status failed -Detail 'Manual DDU path not found.'
        return
    }
    $dduExe = $manualPath
}

Write-Host "  DDU found: $dduExe" -ForegroundColor Green
Write-Host ''

$dduCleanArg = switch ($vendor) {
    'NVIDIA' { '-CleanNvidia' }
    'AMD'    { '-CleanAmd' }
    'Intel'  { '-CleanIntel' }
    default  { $null }
}

if (-not $dduCleanArg) {
    Write-Host '  Could not determine GPU vendor for DDU. Cannot proceed automatically.' -ForegroundColor Red
    Write-Host '  Run DDU manually in Safe Mode.' -ForegroundColor Yellow
    Set-StepStatus -Step 'DDU' -Status failed -Detail 'Unknown GPU vendor.'
    Wait-AnyKey '  Press any key to return to the menu...'
    return
}

Write-Host '  What will happen:' -ForegroundColor White
Write-Host '    1. Chamber will create backups where possible' -ForegroundColor DarkGray
Write-Host '    2. This PC will reboot into Safe Mode' -ForegroundColor DarkGray
Write-Host "    3. DDU will silently remove $vendor display drivers" -ForegroundColor DarkGray
Write-Host '    4. DDU will restart Windows back to normal mode' -ForegroundColor DarkGray
Write-Host '    5. Re-run START-HERE.bat; Chamber will launch the saved GPU driver installer' -ForegroundColor DarkGray
Write-Host ''
Write-Host '  IMPORTANT: Save any open work before continuing.' -ForegroundColor Yellow
Write-Host ''

if (-not (Confirm-Continue '  Proceed with Safe Mode reboot?')) {
    Write-Host '  Aborted.' -ForegroundColor DarkGray
    Write-Host ''
    Set-StepStatus -Step 'DDU' -Status skipped -Detail 'User cancelled before reboot.'
    Wait-AnyKey '  Press any key to return to the menu...'
    return
}

if (-not (Test-StateFlag 'chamber_registry_backed_up')) {
    Backup-ChamberRegistry -Label 'ddu'
    Set-StateFlag 'chamber_registry_backed_up'
}
if (-not (Test-StateFlag 'chamber_restore_point_attempted')) {
    [void](New-ChamberRestorePoint -Description 'Chamber DDU Cleanup')
    Set-StateFlag 'chamber_restore_point_attempted'
}

Ensure-StateDir
$runnerPath = Join-Path $script:StateDir 'Run-DduCleanup.ps1'
$dduLogDir = $script:LogDir
$runner = @"
Set-StrictMode -Version Latest
`$ErrorActionPreference = 'Stop'
`$stateDir = '$($script:StateDir.Replace("'", "''"))'
`$logDir = '$($dduLogDir.Replace("'", "''"))'
if (-not (Test-Path -LiteralPath `$logDir)) { [void](New-Item -ItemType Directory -Path `$logDir -Force) }
`$log = Join-Path `$logDir ("{0}-ddu-runonce.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
function Write-RunLog([string]`$Message) { [System.IO.File]::AppendAllText(`$log, "[`$(Get-Date -Format o)] `$Message`r`n") }
Write-RunLog 'DDU RunOnce started.'
[System.IO.File]::WriteAllText((Join-Path `$stateDir 'ddu_started.flag'), (Get-Date).ToString('o'))
try {
    & '$($dduExe.Replace("'", "''"))' -Silent -Restart -NoSafeModeMsg -logging $dduCleanArg
    `$exitCode = `$LASTEXITCODE
    Write-RunLog "DDU exited with code `$exitCode."
    if (`$exitCode -eq 0) {
        [System.IO.File]::WriteAllText((Join-Path `$stateDir 'ddu_complete.flag'), (Get-Date).ToString('o'))
        if (Test-Path -LiteralPath (Join-Path `$stateDir 'ddu_scheduled.flag')) {
            Remove-Item -LiteralPath (Join-Path `$stateDir 'ddu_scheduled.flag') -Force -ErrorAction SilentlyContinue
        }
    } else {
        [System.IO.File]::WriteAllText((Join-Path `$stateDir 'ddu_failed.flag'), "Exit `$exitCode at `$((Get-Date).ToString('o'))")
    }
} catch {
    Write-RunLog "DDU failed: `$(`$_.Exception.Message)"
    [System.IO.File]::WriteAllText((Join-Path `$stateDir 'ddu_failed.flag'), `$_.Exception.Message)
    throw
}
"@
[System.IO.File]::WriteAllText($runnerPath, $runner, [System.Text.Encoding]::UTF8)
Write-ChamberLog "DDU runner written to $runnerPath"

$runOnceKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'

Set-ItemProperty -Path $runOnceKey -Name 'A_ChamberSafeModeExit' `
    -Value 'cmd.exe /c bcdedit /deletevalue {current} safeboot' `
    -Type String

Set-ItemProperty -Path $runOnceKey -Name 'B_ChamberDDU' `
    -Value "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$runnerPath`"" `
    -Type String

$bcdeditResult = & bcdedit /set '{current}' safeboot minimal 2>&1
if ($LASTEXITCODE -ne 0) {
    Remove-ItemProperty -Path $runOnceKey -Name 'A_ChamberSafeModeExit' -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $runOnceKey -Name 'B_ChamberDDU' -ErrorAction SilentlyContinue
    Set-StepStatus -Step 'DDU' -Status failed -Detail "bcdedit failed: $bcdeditResult"
    throw "bcdedit failed (exit $LASTEXITCODE): $bcdeditResult"
}

Set-StateFlag 'ddu_scheduled'
Set-StepStatus -Step 'DDU' -Status pending -Detail 'Safe Mode cleanup scheduled.'

Write-Host ''
Write-Host '  Rebooting into Safe Mode in 15 seconds...' -ForegroundColor Cyan
Write-Host '  After DDU finishes, re-run START-HERE.bat to install the GPU driver and continue setup.' -ForegroundColor White
Write-Host ''

Start-Sleep -Seconds 3
& shutdown.exe /r /t 15 /c "Chamber: Rebooting to Safe Mode for DDU clean driver install..."
if ($LASTEXITCODE -ne 0) {
    Remove-ItemProperty -Path $runOnceKey -Name 'A_ChamberSafeModeExit' -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $runOnceKey -Name 'B_ChamberDDU' -ErrorAction SilentlyContinue
    & bcdedit /deletevalue '{current}' safeboot 2>&1 | Out-Null
    Clear-StateFlag 'ddu_scheduled'
    Set-StepStatus -Step 'DDU' -Status failed -Detail 'shutdown.exe failed and changes were rolled back.'
    throw "shutdown.exe failed (exit $LASTEXITCODE). All changes rolled back. Try rebooting manually."
}
