#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\Shared.ps1"

[void](Initialize-ChamberLog -Name 'repair-revert')
Assert-Admin
Set-StepStatus -Step 'RepairRevert' -Status running

function Invoke-RepairStep {
    param(
        [string]$Label,
        [scriptblock]$Action
    )

    try {
        & $Action
        Write-Result -Status PASS -Label $Label
    } catch {
        Write-Result -Status FAIL -Label $Label -Detail $_.Exception.Message
    }
}

function Remove-RegistryValueIfPresent {
    param(
        [string]$Path,
        [string]$Name
    )

    if (Test-Path -LiteralPath $Path) {
        $prop = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue
        if ($null -ne $prop) {
            Remove-ItemProperty -LiteralPath $Path -Name $Name -Force
        }
    }
}

function Set-ServiceStartupSafe {
    param(
        [string]$Name,
        [ValidateSet('Automatic','Manual','Disabled')][string]$StartupType,
        [switch]$Start
    )

    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) { throw "Service not found: $Name" }
    Set-Service -Name $Name -StartupType $StartupType
    if ($Start) {
        Start-Service -Name $Name -ErrorAction SilentlyContinue
    }
}

function Invoke-StoreWingetXboxRepair {
    & (Join-Path $PSScriptRoot '6-RestoreUpdatesAndStore.ps1')
}

function Invoke-DefenderRestore {
    Write-Header 'Restore Defender / Windows Security'
    Backup-ChamberRegistry -Label 'restore-defender'

    Invoke-RepairStep 'Remove Defender policy' {
        Remove-RegistryValueIfPresent -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender' -Name 'DisableAntiSpyware'
        Remove-RegistryValueIfPresent -Path 'HKLM:\SOFTWARE\Microsoft\Windows Defender' -Name 'DisableAntiVirus'
        Remove-RegistryValueIfPresent -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection' -Name 'DisableRealtimeMonitoring'
    }
    Invoke-RepairStep 'Enable Defender preference' {
        if (Get-Command Set-MpPreference -ErrorAction SilentlyContinue) {
            Set-MpPreference -DisableRealtimeMonitoring $false -ErrorAction SilentlyContinue
        }
    }
    foreach ($svc in @('WinDefend','WdNisSvc','SecurityHealthService','wscsvc')) {
        Invoke-RepairStep "Restore $svc" {
            Set-ServiceStartupSafe -Name $svc -StartupType Automatic -Start
        }
    }
    Write-Host ''
    Write-Host '  Restart Windows, then open Windows Security to confirm protection is active.' -ForegroundColor Yellow
    Write-SectionComplete 'Restore Defender / Windows Security'
}

function Invoke-VbsGameCompatibilityRestore {
    Write-Header 'Restore VBS / HVCI / Hypervisor'
    Backup-ChamberRegistry -Label 'restore-vbs-hvci'

    Invoke-RepairStep 'Enable hypervisor boot' {
        $output = & bcdedit /set hypervisorlaunchtype auto 2>&1
        if ($LASTEXITCODE -ne 0) { throw $output }
    }
    Invoke-RepairStep 'Restore VBS policy' {
        New-Item -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard' -Force | Out-Null
        Set-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard' -Name 'EnableVirtualizationBasedSecurity' -Value 1 -Type DWord
        Set-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard' -Name 'RequirePlatformSecurityFeatures' -Value 1 -Type DWord
    }
    Invoke-RepairStep 'Restore HVCI policy' {
        $path = 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity'
        New-Item -Path $path -Force | Out-Null
        Set-ItemProperty -LiteralPath $path -Name 'Enabled' -Value 1 -Type DWord
    }
    Write-Host ''
    Write-Host '  Restart required. This helps WSL2, Docker, Windows Sandbox, and memory-integrity use cases.' -ForegroundColor Yellow
    Write-SectionComplete 'Restore VBS / HVCI / Hypervisor'
}

function Invoke-GameBarXboxRestore {
    Write-Header 'Restore Game Bar / Game DVR'
    Backup-ChamberRegistry -Label 'restore-gamebar'

    Invoke-RepairStep 'Restore GameDVR user values' {
        New-Item -Path 'HKCU:\System\GameConfigStore' -Force | Out-Null
        Set-ItemProperty -LiteralPath 'HKCU:\System\GameConfigStore' -Name 'GameDVR_Enabled' -Value 1 -Type DWord
        New-Item -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR' -Force | Out-Null
        Set-ItemProperty -LiteralPath 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR' -Name 'AppCaptureEnabled' -Value 1 -Type DWord
    }
    Invoke-RepairStep 'Restore Game Bar values' {
        New-Item -Path 'HKCU:\SOFTWARE\Microsoft\GameBar' -Force | Out-Null
        Set-ItemProperty -LiteralPath 'HKCU:\SOFTWARE\Microsoft\GameBar' -Name 'UseNexusForGameBarEnabled' -Value 1 -Type DWord
        Set-ItemProperty -LiteralPath 'HKCU:\SOFTWARE\Microsoft\GameBar' -Name 'AllowAutoGameMode' -Value 1 -Type DWord
        Set-ItemProperty -LiteralPath 'HKCU:\SOFTWARE\Microsoft\GameBar' -Name 'AutoGameModeEnabled' -Value 1 -Type DWord
    }
    Invoke-RepairStep 'Clear GameDVR machine policy' {
        Remove-RegistryValueIfPresent -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' -Name 'AllowGameDVR'
    }
    foreach ($svc in @('XblAuthManager','XblGameSave','XboxNetApiSvc','XboxGipSvc','GamingServices')) {
        Invoke-RepairStep "Restore $svc" {
            Set-ServiceStartupSafe -Name $svc -StartupType Manual
        }
    }
    Write-Host ''
    Write-Host '  If Xbox app or Game Bar was removed, reinstall it from Microsoft Store after this repair.' -ForegroundColor Yellow
    Write-SectionComplete 'Restore Game Bar / Game DVR'
}

function Invoke-NormalDesktopPowerRestore {
    Write-Header 'Restore Normal Desktop / Laptop Behavior'
    Backup-ChamberRegistry -Label 'restore-desktop-behavior'

    if (-not (Confirm-Continue '  Restore default power schemes and sleep behavior?')) {
        Write-Host '  Skipped power restore.' -ForegroundColor DarkGray
    } else {
        Invoke-RepairStep 'Restore default power schemes' {
            $output = & powercfg -restoredefaultschemes 2>&1
            if ($LASTEXITCODE -ne 0) { throw $output }
        }
        Invoke-RepairStep 'Activate Balanced plan' {
            $output = & powercfg /setactive 381b4222-f694-41f0-9685-ff5bb260df2e 2>&1
            if ($LASTEXITCODE -ne 0) { throw $output }
        }
        Invoke-RepairStep 'Restore sleep/monitor timers' {
            & powercfg -h on | Out-Null
            & powercfg -change -monitor-timeout-ac 10 | Out-Null
            & powercfg -change -monitor-timeout-dc 5 | Out-Null
            & powercfg -change -standby-timeout-ac 30 | Out-Null
            & powercfg -change -standby-timeout-dc 15 | Out-Null
        }
    }

    foreach ($svc in @(
        @{ Name = 'WSearch'; Startup = 'Automatic' },
        @{ Name = 'SysMain'; Startup = 'Automatic' },
        @{ Name = 'PcaSvc';  Startup = 'Manual' }
    )) {
        Invoke-RepairStep "Restore $($svc.Name)" {
            Set-ServiceStartupSafe -Name $svc.Name -StartupType $svc.Startup
        }
    }
    Write-SectionComplete 'Restore Normal Desktop / Laptop Behavior'
}

function Invoke-HostsTelemetryCleanup {
    Write-Header 'Clean Hosts / Telemetry Blocks'
    Backup-ChamberRegistry -Label 'cleanup-telemetry-blocks'
    Backup-ChamberHostsFile -Label 'cleanup-telemetry-blocks' | Out-Null

    $entries = @(
        'vortex.data.microsoft.com',
        'settings-win.data.microsoft.com',
        'telemetry.microsoft.com',
        'watson.telemetry.microsoft.com',
        'statsfe2.ws.microsoft.com',
        'statsfe1.ws1.microsoft.com'
    )

    Invoke-RepairStep 'Remove Chamber hosts entries' {
        $hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
        if (-not (Test-Path -LiteralPath $hostsPath)) { throw 'hosts file not found' }
        $lines = [System.Collections.Generic.List[string]]::new()
        foreach ($line in [System.IO.File]::ReadAllLines($hostsPath)) {
            $matched = $false
            foreach ($entry in $entries) {
                if ($line -match [regex]::Escape($entry)) {
                    $matched = $true
                    break
                }
            }
            if (-not $matched) { $lines.Add($line) }
        }
        [System.IO.File]::WriteAllLines($hostsPath, $lines, [System.Text.Encoding]::ASCII)
    }

    foreach ($exe in @('CompatTelRunner.exe','AggregatorHost.exe','DeviceCensus.exe')) {
        Invoke-RepairStep "Clear IFEO $exe" {
            $path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$exe"
            Remove-RegistryValueIfPresent -Path $path -Name 'Debugger'
        }
    }
    Write-SectionComplete 'Clean Hosts / Telemetry Blocks'
}

function New-RemovedAppRestoreTarget {
    param(
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][string[]]$AppxNames,
        [Parameter(Mandatory)][string]$StoreSearch,
        [switch]$XboxOnly
    )

    [pscustomobject]@{
        DisplayName = $DisplayName
        AppxNames   = $AppxNames
        StoreSearch = $StoreSearch
        XboxOnly    = [bool]$XboxOnly
    }
}

function Get-RemovedAppRestoreCatalog {
    return @(
        New-RemovedAppRestoreTarget -DisplayName 'Outlook / Mail and Calendar' -AppxNames @('Microsoft.OutlookForWindows', 'microsoft.windowscommunicationsapps') -StoreSearch 'Outlook for Windows'
        New-RemovedAppRestoreTarget -DisplayName 'Solitaire and casual games' -AppxNames @('Microsoft.MicrosoftSolitaireCollection') -StoreSearch 'Microsoft Solitaire Collection'
        New-RemovedAppRestoreTarget -DisplayName 'Microsoft Teams consumer app' -AppxNames @('MSTeams', 'MicrosoftTeams', 'Microsoft.MicrosoftTeams') -StoreSearch 'Microsoft Teams'
        New-RemovedAppRestoreTarget -DisplayName 'Clipchamp' -AppxNames @('Clipchamp.Clipchamp') -StoreSearch 'Clipchamp'
        New-RemovedAppRestoreTarget -DisplayName 'Microsoft Copilot app' -AppxNames @('Microsoft.Copilot') -StoreSearch 'Microsoft Copilot'
        New-RemovedAppRestoreTarget -DisplayName 'Widgets and web experience' -AppxNames @('MicrosoftWindows.Client.WebExperience', 'Microsoft.WidgetsPlatformRuntime') -StoreSearch 'Windows Web Experience Pack'
        New-RemovedAppRestoreTarget -DisplayName 'Phone Link' -AppxNames @('Microsoft.YourPhone') -StoreSearch 'Phone Link'
        New-RemovedAppRestoreTarget -DisplayName 'Bing and MSN apps' -AppxNames @('Microsoft.BingNews', 'Microsoft.BingWeather', 'Microsoft.BingSearch', 'Microsoft.BingFinance', 'Microsoft.BingSports') -StoreSearch 'MSN apps'
        New-RemovedAppRestoreTarget -DisplayName 'Feedback Hub / Get Help / Tips' -AppxNames @('Microsoft.WindowsFeedbackHub', 'Microsoft.GetHelp', 'Microsoft.Getstarted') -StoreSearch 'Feedback Hub'
        New-RemovedAppRestoreTarget -DisplayName 'Media apps' -AppxNames @('Microsoft.ZuneVideo', 'Microsoft.ZuneMusic', 'Microsoft.WindowsSoundRecorder') -StoreSearch 'Microsoft Media Player'
        New-RemovedAppRestoreTarget -DisplayName 'Family, People, and To Do' -AppxNames @('MicrosoftCorporationII.MicrosoftFamily', 'Microsoft.People', 'Microsoft.Todos') -StoreSearch 'Microsoft To Do'
        New-RemovedAppRestoreTarget -DisplayName 'Power Automate / Whiteboard / Maps' -AppxNames @('Microsoft.PowerAutomateDesktop', 'Microsoft.Whiteboard', 'Microsoft.WindowsMaps') -StoreSearch 'Microsoft Whiteboard'
        New-RemovedAppRestoreTarget -DisplayName 'Office hub and Power BI' -AppxNames @('Microsoft.MicrosoftOfficeHub', 'Microsoft.MicrosoftPowerBIForWindows') -StoreSearch 'Microsoft 365 Copilot'
        New-RemovedAppRestoreTarget -DisplayName 'Spotify' -AppxNames @('SpotifyAB.SpotifyMusic') -StoreSearch 'Spotify'
        New-RemovedAppRestoreTarget -DisplayName 'Dev Home' -AppxNames @('Microsoft.Windows.DevHome', 'MicrosoftCorporationII.DevHome', 'Microsoft.DevHome') -StoreSearch 'Dev Home'
        New-RemovedAppRestoreTarget -DisplayName 'LinkedIn and Skype' -AppxNames @('7EE7776C.LinkedInforWindows', 'Microsoft.LinkedIn', 'Microsoft.SkypeApp') -StoreSearch 'Skype'
        New-RemovedAppRestoreTarget -DisplayName 'Cortana and Mixed Reality Portal' -AppxNames @('Microsoft.549981C3F5F10', 'Microsoft.MixedReality.Portal') -StoreSearch 'Mixed Reality Portal'
        New-RemovedAppRestoreTarget -DisplayName 'Xbox app / Game Pass app' -AppxNames @('Microsoft.GamingApp', 'Microsoft.XboxApp') -StoreSearch 'Xbox' -XboxOnly
        New-RemovedAppRestoreTarget -DisplayName 'Xbox overlays and identity providers' -AppxNames @('Microsoft.XboxGameOverlay', 'Microsoft.XboxGamingOverlay', 'Microsoft.XboxIdentityProvider', 'Microsoft.XboxSpeechToTextOverlay') -StoreSearch 'Xbox Game Bar' -XboxOnly
    )
}

function Show-RemovedAppReference {
    Write-Host '  Balanced removal targets:' -ForegroundColor Cyan
    foreach ($target in (Get-RemovedAppRestoreCatalog | Where-Object { -not $_.XboxOnly })) {
        Write-Host "    - $($target.DisplayName)" -ForegroundColor White
    }

    Write-Host ''
    Write-Host '  Xbox targets are removed only if Remove Xbox Services was selected:' -ForegroundColor Cyan
    foreach ($target in (Get-RemovedAppRestoreCatalog | Where-Object { $_.XboxOnly })) {
        Write-Host "    - $($target.DisplayName)" -ForegroundColor White
    }

    Write-Host ''
    Write-Host '  Preserved by default:' -ForegroundColor Cyan
    foreach ($item in @(
        'Microsoft Store',
        'App Installer / winget',
        'Windows Security',
        'Calculator',
        'Notepad',
        'Snipping Tool',
        'Photos',
        'Paint',
        'Quick Assist',
        'Xbox and Game Pass unless Remove Xbox Services was selected'
    )) {
        Write-Host "    - $item" -ForegroundColor White
    }
}

function Register-RemovedAppTarget {
    param([Parameter(Mandatory)]$Target)

    $registered = 0
    $seen = @{}

    foreach ($pkgName in $Target.AppxNames) {
        $packages = @(Get-AppxPackage -AllUsers -Name $pkgName -ErrorAction SilentlyContinue)
        foreach ($pkg in $packages) {
            if ($seen.ContainsKey($pkg.PackageFullName)) { continue }
            $seen[$pkg.PackageFullName] = $true

            $manifest = Join-Path $pkg.InstallLocation 'AppxManifest.xml'
            if (-not (Test-Path -LiteralPath $manifest)) {
                Write-Result -Status WARN -Label $pkg.Name -Detail 'Manifest not found'
                continue
            }

            try {
                Add-AppxPackage -DisableDevelopmentMode -Register $manifest -ErrorAction Stop
                Write-Result -Status PASS -Label $pkg.Name -Detail 'Re-registered from disk'
                $registered++
            } catch {
                Write-Result -Status FAIL -Label $pkg.Name -Detail $_.Exception.Message
            }
        }
    }

    return $registered
}

function Open-StoreSearchForRemovedApp {
    param([Parameter(Mandatory)]$Target)

    $query = [uri]::EscapeDataString($Target.StoreSearch)
    $storeUri = "ms-windows-store://search/?query=$query"
    try {
        Start-Process $storeUri -ErrorAction Stop
        Write-Host "  Opened Microsoft Store search for: $($Target.StoreSearch)" -ForegroundColor Green
    } catch {
        Write-Host "  Could not open Microsoft Store automatically." -ForegroundColor Yellow
        Write-Host "  Search the Store for: $($Target.StoreSearch)" -ForegroundColor White
    }
}

function Invoke-RemovedAppRestoreTarget {
    param(
        [Parameter(Mandatory)]$Target,
        [switch]$AllowStorePrompt
    )

    Write-Host ''
    Write-Host "  Restore target: $($Target.DisplayName)" -ForegroundColor Cyan
    $registered = Register-RemovedAppTarget -Target $Target

    if ($registered -gt 0) {
        Write-Host "  Re-registered $registered package instance(s)." -ForegroundColor Green
        return
    }

    Write-Host '  No package copy was found on disk for re-registration.' -ForegroundColor Yellow
    Write-Host '  If this app was fully removed, reinstalling from Microsoft Store is required.' -ForegroundColor DarkGray

    if ($AllowStorePrompt -and (Confirm-Continue '  Open a Microsoft Store search for this app?')) {
        Open-StoreSearchForRemovedApp -Target $Target
    } else {
        Write-Host "  Store search term: $($Target.StoreSearch)" -ForegroundColor DarkGray
    }
}

function Invoke-RemovedAppGuidance {
    while ($true) {
        $catalog = @(Get-RemovedAppRestoreCatalog)
        Write-Header 'Restore Removed Windows Apps'
        Write-Host '  Re-register apps still present on disk, or open Store search for a selected app.' -ForegroundColor DarkGray
        Write-Host '  This does not reinstall Store, winget, Windows Security, Calculator, Notepad, Photos, Paint, or Quick Assist because Chamber preserves them by default.' -ForegroundColor DarkGray
        Write-Host ''

        for ($i = 0; $i -lt $catalog.Count; $i++) {
            $label = if ($catalog[$i].XboxOnly) { "$($catalog[$i].DisplayName) (Xbox option only)" } else { $catalog[$i].DisplayName }
            Write-Host ("  [{0}]  {1}" -f ($i + 1), $label) -ForegroundColor White
        }

        Write-Host '  [A]  Re-register all package copies still present on disk' -ForegroundColor Cyan
        Write-Host '  [L]  Show removed and preserved app lists' -ForegroundColor DarkGray
        Write-Host '  [B]  Back' -ForegroundColor DarkGray
        Write-Host ''

        $choice = (Read-Host '  Choice').Trim().ToUpper()
        if ($choice -eq 'B') { return }
        if ($choice -eq 'L') {
            Write-Header 'Removed and Preserved Apps'
            Show-RemovedAppReference
            Write-Host ''
            Wait-AnyKey
            continue
        }
        if ($choice -eq 'A') {
            foreach ($target in $catalog) {
                Invoke-RemovedAppRestoreTarget -Target $target
            }
            Write-Host ''
            Wait-AnyKey
            continue
        }

        [int]$index = 0
        if ([int]::TryParse($choice, [ref]$index) -and $index -ge 1 -and $index -le $catalog.Count) {
            Invoke-RemovedAppRestoreTarget -Target $catalog[$index - 1] -AllowStorePrompt
            Write-Host ''
            Wait-AnyKey
        }
    }
}

while ($true) {
    Write-Header 'Repair / Revert Common Uses'
    Write-Host '  [1]  Store / winget / Xbox downloads' -ForegroundColor White
    Write-Host '  [2]  Defender / Windows Security' -ForegroundColor White
    Write-Host '  [3]  VBS / HVCI / Hypervisor compatibility' -ForegroundColor White
    Write-Host '  [4]  Game Bar / Game DVR / Xbox services' -ForegroundColor White
    Write-Host '  [5]  Normal desktop power, sleep, Search and SysMain' -ForegroundColor White
    Write-Host '  [6]  Hosts / telemetry block cleanup' -ForegroundColor White
    Write-Host '  [7]  Restore removed Windows apps' -ForegroundColor White
    Write-Host '  [B]  Back' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  Choice: ' -NoNewline
    $choice = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    Write-Host $choice.Character
    $key = $choice.Character.ToString().ToUpper()

    switch ($key) {
        '1' { Invoke-StoreWingetXboxRepair }
        '2' { Invoke-DefenderRestore }
        '3' { Invoke-VbsGameCompatibilityRestore }
        '4' { Invoke-GameBarXboxRestore }
        '5' { Invoke-NormalDesktopPowerRestore }
        '6' { Invoke-HostsTelemetryCleanup }
        '7' { Invoke-RemovedAppGuidance }
        'B' { Set-StepStatus -Step 'RepairRevert' -Status complete -Detail 'Repair menu closed.'; return }
    }
}
