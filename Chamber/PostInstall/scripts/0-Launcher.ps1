#Requires -Version 5.1
param([switch]$SmokeTest)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\Shared.ps1"

[void](Initialize-ChamberLog -Name 'launcher')
if (-not $SmokeTest) {
    Assert-Admin
}

function Get-RunOnceValue {
    param([string]$Name)

    try {
        $runOnceKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
        return (Get-ItemProperty -Path $runOnceKey -Name $Name -ErrorAction SilentlyContinue).$Name
    } catch {
        return $null
    }
}

function Test-SafeBootActive {
    try {
        $bcd = & bcdedit /enum '{current}' 2>&1
        return ($bcd -match 'safeboot')
    } catch {
        Write-ChamberLog "Could not query Safe Mode state: $($_.Exception.Message)" -Level WARN
        return $false
    }
}

function Resolve-DduResumeState {
    if ((Test-StateFlag 'ddu_scheduled') -and -not (Test-StateFlag 'ddu_complete')) {
        $stillSafeBoot = Test-SafeBootActive
        $dduRunOnce = Get-RunOnceValue -Name 'B_ChamberDDU'
        $dduStarted = Test-Path -LiteralPath (Join-Path $script:StateDir 'ddu_started.flag')
        $dduFailed = Test-Path -LiteralPath (Join-Path $script:StateDir 'ddu_failed.flag')

        if ($dduFailed) {
            Clear-StateFlag 'ddu_scheduled'
            Set-StepStatus -Step 'DDU' -Status failed -Detail 'DDU failure marker found.'
            Set-LastFailure -Step 'DDU' -Message 'DDU failure marker found. Export diagnostics for the log.'
        } elseif (-not $stillSafeBoot -and -not $dduRunOnce -and $dduStarted) {
            Set-StateFlag 'ddu_complete'
            Clear-StateFlag 'ddu_scheduled'
            Set-StepStatus -Step 'DDU' -Status complete -Detail 'Safe Mode cleanup appears complete.'
            Write-ChamberLog 'DDU resume state resolved as complete.'
        } elseif (-not $stillSafeBoot -and -not $dduRunOnce -and -not $dduStarted) {
            Clear-StateFlag 'ddu_scheduled'
            Set-StepStatus -Step 'DDU' -Status failed -Detail 'Stale scheduled state found without DDU start marker.'
            Set-LastFailure -Step 'DDU' -Message 'Stale scheduled state cleared; DDU does not appear to have started.'
        } elseif ($stillSafeBoot) {
            Write-ChamberLog 'DDU resume state still shows Safe Mode boot configured.' -Level WARN
        }
    }
}

function Show-Welcome {
    Clear-Host
    Write-Host ''
    Write-Host ('  ' + ('=' * 60)) -ForegroundColor Cyan
    Write-Host '    Chamber  --  Post-Install Setup' -ForegroundColor Cyan
    Write-Host ('  ' + ('=' * 60)) -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  This tool finishes driver cleanup, GPU driver install handoff, latency' -ForegroundColor White
    Write-Host '  tweaks, verification, repairs, optional apps, and diagnostics.' -ForegroundColor White
    Write-Host ''
    Write-Host '  Recommended is guarded automation: Chamber checks the system and walks' -ForegroundColor DarkGray
    Write-Host '  through the risky steps, but still asks before Safe Mode and DDU.' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  Press ENTER from the main menu to run the recommended flow.' -ForegroundColor Green
    Write-Host ''
}

function Show-StatusSummary {
    $state = Get-ChamberState
    $gpuName = Get-GpuName
    $winget = Get-WingetHealth

    Write-Host "  GPU:    $gpuName" -ForegroundColor DarkGray
    Write-Host "  winget: $(if ($winget.Available) { $winget.Version } else { 'missing or not registered' })" -ForegroundColor DarkGray

    if ($state.LastFailure) {
        Write-Host "  Last failure: $($state.LastFailure.Step) - $($state.LastFailure.Message)" -ForegroundColor Yellow
    }

    if ((Test-StateFlag 'ddu_complete') -and -not (Test-StateFlag 'driver_installed')) {
        Write-Host ''
        $savedInstaller = Get-PendingGpuDriverInstaller
        if ($savedInstaller) {
            Write-Host "  NOTE: DDU appears complete. Saved GPU installer: $($savedInstaller.Name)" -ForegroundColor Yellow
        } else {
            Write-Host '  NOTE: DDU appears complete. Run Recommended to locate and launch the GPU driver installer.' -ForegroundColor Yellow
        }
    }

    if (Test-StateFlag 'ddu_scheduled') {
        Write-Host ''
        Write-Host '  NOTE: DDU is scheduled or mid-resume. Use Diagnostics if this seems stuck.' -ForegroundColor Yellow
    }
}

function Show-MainMenu {
    Write-Header 'Main Menu'
    Show-StatusSummary
    Write-Host ''
    Write-Host '  [1]  Run Recommended' -ForegroundColor Cyan
    Write-Host '  [2]  Drivers / DDU' -ForegroundColor White
    Write-Host '  [3]  Repair / Revert Common Uses' -ForegroundColor White
    Write-Host '  [4]  Optional Apps' -ForegroundColor White
    Write-Host '  [5]  Diagnostics / Export Error Report' -ForegroundColor White
    Write-Host '  [6]  Advanced Individual Steps' -ForegroundColor DarkGray
    Write-Host '  [Q]  Quit' -ForegroundColor DarkGray
    Write-Host ''
}

function Invoke-Step {
    param([string]$Number)

    $scriptMap = @{
        '1' = @{ File = '1-PrepareDrivers.ps1'; Step = 'PrepareDrivers' }
        '2' = @{ File = '2-SafeModeDDU.ps1'; Step = 'DDU' }
        '3' = @{ File = '3-EnableMSIMode.ps1'; Step = 'MSIMode' }
        '4' = @{ File = '4-VerifySystem.ps1'; Step = 'VerifySystem' }
        '5' = @{ File = '5-NicDriverGuidance.ps1'; Step = 'NicGuidance' }
        '6' = @{ File = '6-RestoreUpdatesAndStore.ps1'; Step = 'RestoreUpdatesStore' }
        '7' = @{ File = '7-InstallOptionalApps.ps1'; Step = 'OptionalApps' }
        '8' = @{ File = '8-RepairAndRevert.ps1'; Step = 'RepairRevert' }
    }
    if (-not $scriptMap.ContainsKey($Number)) { return }

    $stepInfo = $scriptMap[$Number]
    $scriptPath = Join-Path $PSScriptRoot $stepInfo.File
    try {
        Set-StepStatus -Step $stepInfo.Step -Status running
        & $scriptPath
        $state = Get-ChamberState
        $current = $state.Steps.PSObject.Properties[$stepInfo.Step]
        if (-not $current -or $current.Value.Status -ne 'failed') {
            Set-StepStatus -Step $stepInfo.Step -Status complete
        }
    } catch {
        Set-StepStatus -Step $stepInfo.Step -Status failed -Detail $_.Exception.Message
        Set-LastFailure -Step $stepInfo.Step -Message $_.Exception.Message
        Write-Host ''
        Write-Host "  ERROR in $($stepInfo.Step): $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "  Exception type: $($_.Exception.GetType().FullName)" -ForegroundColor DarkGray
        if ($_.ScriptStackTrace) {
            Write-Host ''
            Write-Host '  Stack trace:' -ForegroundColor DarkGray
            $_.ScriptStackTrace -split "`n" | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
        }
        Write-Host ''
        Wait-AnyKey '  Press any key to return to menu...'
    }
}

function Invoke-PreflightScreen {
    Write-Header 'Preflight'
    [void](Invoke-ChamberPreflight)
    Write-Host ''
    Write-Host "  Logs and state are saved under $script:StateDir" -ForegroundColor DarkGray
    Write-Host ''
}

function Invoke-Recommended {
    Write-Header 'Run Recommended'
    Invoke-PreflightScreen

    if (-not (Test-StateFlag 'chamber_restore_point_attempted')) {
        [void](New-ChamberRestorePoint -Description 'Chamber Post-Install')
        Set-StateFlag 'chamber_restore_point_attempted'
    }

    if (-not (Test-StateFlag 'chamber_registry_backed_up')) {
        Backup-ChamberRegistry -Label 'recommended'
        Set-StateFlag 'chamber_registry_backed_up'
    }

    if (Test-StateFlag 'ddu_complete') {
        Write-Host '  DDU cleanup is marked complete. Skipping driver prep and DDU.' -ForegroundColor Green
        if (-not (Test-StateFlag 'driver_installed')) {
            Write-Host ''
            Write-Host '  Next: install the fresh GPU driver, then Chamber can finish MSI, verification, and NIC setup.' -ForegroundColor Yellow
            if (-not (Invoke-PendingGpuDriverInstaller -AllowPrompt)) {
                Write-Host ''
                Write-Host '  GPU driver install is still pending. Run Recommended again after the driver installer is ready.' -ForegroundColor Yellow
                Write-Host ''
                Wait-AnyKey '  Press any key to return to menu...'
                return
            }
        }
        foreach ($step in @('3','4','5')) { Invoke-Step $step }
    } else {
        Invoke-Step '1'
        Invoke-Step '2'
        Write-Host ''
        Write-Host '  DDU is now scheduled. The PC should reboot to Safe Mode and back.' -ForegroundColor Cyan
        Write-Host '  After it returns to normal mode, rerun this launcher. Chamber will offer' -ForegroundColor White
        Write-Host '  to launch the saved GPU driver installer and continue the setup.' -ForegroundColor White
        Write-Host ''
        Wait-AnyKey '  Press any key to exit the launcher...'
        return
    }

    Write-Host ''
    Write-Host ('  ' + ('=' * 58)) -ForegroundColor Cyan
    Write-Host '    Recommended flow complete.' -ForegroundColor Cyan
    Write-Host ('  ' + ('=' * 58)) -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  Optional apps and repair profiles remain available from the main menu.' -ForegroundColor Green
    Write-Host ''
    Wait-AnyKey '  Press any key to return to menu...'
}

function Invoke-GpuDriverInstallerMenu {
    Write-Header 'GPU Driver Installer'
    if (Invoke-PendingGpuDriverInstaller -AllowPrompt) {
        Write-Host ''
        Write-Host '  GPU driver marked installed. Run Recommended to finish MSI, verification, and NIC setup.' -ForegroundColor Green
    } else {
        Write-Host ''
        Write-Host '  No GPU driver was installed. Download the driver, then run this again.' -ForegroundColor Yellow
    }
    Write-Host ''
    Wait-AnyKey '  Press any key to return to menu...'
}

function Invoke-DriversMenu {
    while ($true) {
        Write-Header 'Drivers / DDU'
        Write-Host '  [1]  Prepare GPU Drivers (download + stage DDU)' -ForegroundColor White
        Write-Host '  [2]  Clean GPU Driver Install via DDU (Safe Mode)' -ForegroundColor White
        Write-Host '  [3]  Find / Run Downloaded GPU Driver Installer' -ForegroundColor White
        Write-Host '  [4]  Mark GPU Driver Installed' -ForegroundColor White
        Write-Host '  [B]  Back' -ForegroundColor DarkGray
        Write-Host ''
        Write-Host '  Choice: ' -NoNewline
        $choice = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        Write-Host $choice.Character
        $key = $choice.Character.ToString().ToUpper()

        switch ($key) {
            '1' { Invoke-Step '1' }
            '2' { Invoke-Step '2' }
            '3' { Invoke-GpuDriverInstallerMenu }
            '4' { Set-StateFlag 'driver_installed'; Clear-PendingValue -Name 'GpuDriverInstaller'; Write-SectionComplete 'GPU driver installed marker' }
            'B' { return }
        }
    }
}

function Invoke-DiagnosticsScreen {
    Write-Header 'Diagnostics / Export Error Report'
    Invoke-PreflightScreen
    $zip = Export-ChamberDiagnostics
    Write-Host "  Diagnostic report created:" -ForegroundColor Green
    Write-Host "  $zip" -ForegroundColor White
    Write-Host ''
    Write-Host '  Attach this zip when reporting an issue.' -ForegroundColor DarkGray
    Write-Host ''
    Wait-AnyKey
}

function Invoke-AdvancedMenu {
    while ($true) {
        Write-Header 'Advanced Individual Steps'
        Write-Host '  [1]  Prepare GPU Drivers' -ForegroundColor White
        Write-Host '  [2]  DDU Safe Mode Cleanup' -ForegroundColor White
        Write-Host '  [3]  Enable MSI Interrupt Mode' -ForegroundColor White
        Write-Host '  [4]  Verify System' -ForegroundColor White
        Write-Host '  [5]  NIC Driver Guidance' -ForegroundColor White
        Write-Host '  [6]  Restore Windows Update + Store downloads' -ForegroundColor White
        Write-Host '  [7]  Install Optional Apps' -ForegroundColor White
        Write-Host '  [8]  Repair / Revert Common Uses' -ForegroundColor White
        Write-Host '  [9]  Find / Run Downloaded GPU Driver Installer' -ForegroundColor White
        Write-Host '  [B]  Back' -ForegroundColor DarkGray
        Write-Host ''
        Write-Host '  Choice: ' -NoNewline
        $choice = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        Write-Host $choice.Character
        $key = $choice.Character.ToString().ToUpper()

        if ($key -eq 'B') { return }
        if ($key -match '^[1-8]$') { Invoke-Step $key }
        if ($key -eq '9') { Invoke-GpuDriverInstallerMenu }
    }
}

if ($SmokeTest) {
    Write-Header 'Launcher Smoke Test'
    $summary = Invoke-ChamberPreflight -Quiet
    Write-Result -Status PASS -Label 'Preflight' -Detail "$($summary.OSCaption) build $($summary.OSBuild)"
    Write-Result -Status ($(if ($summary.WingetAvailable) { 'PASS' } else { 'WARN' })) -Label 'winget' -Detail ($(if ($summary.WingetAvailable) { $summary.WingetVersion } else { 'Missing or not registered' }))
    Write-Result -Status ($(if ($summary.DduStaged) { 'PASS' } else { 'INFO' })) -Label 'DDU staged' -Detail ($(if ($summary.DduStaged) { 'Found' } else { 'Not staged' }))

    $vendors = @($summary.GPUs | Where-Object { $_.Vendor -ne 'Unknown' } | Select-Object -ExpandProperty Vendor -Unique)
    $driverCandidates = @(Find-GpuDriverInstallerCandidates -Vendors $vendors | Select-Object -First 3)
    Write-Result -Status INFO -Label 'GPU installers' -Detail "$($driverCandidates.Count) likely candidate(s) found"

    $diagnostics = Export-ChamberDiagnostics
    Write-Result -Status PASS -Label 'Diagnostics' -Detail $diagnostics
    Set-StepStatus -Step 'LauncherSmokeTest' -Status complete -Detail 'Smoke test completed without destructive actions.'
    Write-Host ''
    Write-Host '  Smoke test complete. No menu action was selected.' -ForegroundColor Green
    exit 0
}

Resolve-DduResumeState

$isFirstRun = -not ((Test-StateFlag 'ddu_complete') -or (Test-StateFlag 'driver_installed') -or (Test-StateFlag 'ddu_scheduled'))
if ($isFirstRun) { Show-Welcome }

while ($true) {
    Show-MainMenu
    Write-Host '  Choice [Enter = Recommended, or 1-6/Q]: ' -NoNewline
    $choice = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    Write-Host $choice.Character
    $key = if ($choice.VirtualKeyCode -eq 13) { '1' } else { $choice.Character.ToString().ToUpper() }

    switch ($key) {
        '1' { Invoke-Recommended }
        '2' { Invoke-DriversMenu }
        '3' { Invoke-Step '8' }
        '4' { Invoke-Step '7' }
        '5' { Invoke-DiagnosticsScreen }
        '6' { Invoke-AdvancedMenu }
        'Q' { exit 0 }
    }
}
