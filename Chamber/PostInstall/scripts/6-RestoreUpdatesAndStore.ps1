#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\Shared.ps1"

[void](Initialize-ChamberLog -Name 'restore-updates-store')
Assert-Admin
Set-StepStatus -Step 'RestoreUpdatesStore' -Status running

Write-Header 'Restore Windows Update, Store, winget and Xbox Services'

Write-Host '  Re-enables services and clears update policies that can break' -ForegroundColor DarkGray
Write-Host '  Microsoft Store, winget, Xbox app, and Game Pass downloads.' -ForegroundColor DarkGray
Write-Host ''

Backup-ChamberRegistry -Label 'restore-updates-store'

$results = [System.Collections.Generic.List[pscustomobject]]::new()

function Invoke-RestoreStep {
    param(
        [string]$Label,
        [scriptblock]$Action
    )
    try {
        & $Action
        Write-Result -Status PASS -Label $Label
        $results.Add([pscustomobject]@{ Label = $Label; Ok = $true })
    } catch {
        Write-Result -Status FAIL -Label $Label -Detail $_.Exception.Message
        $results.Add([pscustomobject]@{ Label = $Label; Ok = $false })
    }
}

$services = [System.Collections.Generic.List[hashtable]]@(
    @{ Name = 'DoSvc';        StartupType = 'Manual';    Start = $true  },
    @{ Name = 'wuauserv';     StartupType = 'Manual';    Start = $true  },
    @{ Name = 'UsoSvc';       StartupType = 'Automatic'; Start = $false },
    @{ Name = 'BITS';         StartupType = 'Manual';    Start = $false },
    @{ Name = 'WaaSMedicSvc'; StartupType = 'Manual';    Start = $false },
    @{ Name = 'InstallService'; StartupType = 'Manual';  Start = $false },
    @{ Name = 'ClipSVC';      StartupType = 'Manual';    Start = $false },
    @{ Name = 'XblAuthManager'; StartupType = 'Manual';  Start = $false },
    @{ Name = 'XblGameSave';    StartupType = 'Manual';  Start = $false },
    @{ Name = 'XboxNetApiSvc';  StartupType = 'Manual';  Start = $false },
    @{ Name = 'XboxGipSvc';     StartupType = 'Manual';  Start = $false },
    @{ Name = 'GamingServices'; StartupType = 'Manual';  Start = $false }
)

foreach ($svc in $services) {
    Invoke-RestoreStep "Restore $($svc.Name)" {
        $existing = Get-Service -Name $svc.Name -ErrorAction SilentlyContinue
        if ($null -eq $existing) {
            throw 'Service not found'
        }
        Set-Service -Name $svc.Name -StartupType $svc.StartupType
        if ($svc.Start) {
            Start-Service -Name $svc.Name -ErrorAction SilentlyContinue
        }
    }
}

Invoke-RestoreStep 'Clear WU policy values' {
    $policyKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
    if (Test-Path -LiteralPath $policyKey) {
        foreach ($name in @('NoAutoUpdate', 'AUOptions')) {
            $prop = Get-ItemProperty -LiteralPath $policyKey -Name $name -ErrorAction SilentlyContinue
            if ($null -ne $prop) {
                Remove-ItemProperty -LiteralPath $policyKey -Name $name -Force
            }
        }
    }
}

Invoke-RestoreStep 'Register App Installer' {
    $winget = Get-WingetHealth
    if ($winget.Available) { return }
    if (-not $winget.AppInstallerPresent) {
        throw 'App Installer package is missing. Install/update App Installer from Microsoft Store.'
    }
    Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe
}

Invoke-RestoreStep 'Reset winget sources' {
    $wingetPath = Resolve-WingetCommand
    if (-not $wingetPath) {
        throw 'winget still not available'
    }
    $output = & $wingetPath source reset --force --accept-source-agreements 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "winget source reset failed: $output"
    }
}

Invoke-RestoreStep 'Reset Microsoft Store cache' {
    $wsreset = Join-Path $env:SystemRoot 'System32\wsreset.exe'
    if (-not (Test-Path -LiteralPath $wsreset)) {
        throw 'wsreset.exe not found'
    }
    Start-Process -FilePath $wsreset -WindowStyle Hidden -ErrorAction SilentlyContinue | Out-Null
}

Invoke-RestoreStep 'Re-register Microsoft Store' {
    $store = Get-AppxPackage -AllUsers -Name 'Microsoft.WindowsStore' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $store) {
        throw 'Microsoft Store package not found for any user'
    }
    $manifest = Join-Path $store.InstallLocation 'AppxManifest.xml'
    if (-not (Test-Path -LiteralPath $manifest)) {
        throw 'Store AppxManifest.xml not found'
    }
    Add-AppxPackage -DisableDevelopmentMode -Register $manifest
}

Write-Host ''
$failed = @($results | Where-Object { -not $_.Ok })
if ($failed.Count -eq 0) {
    Write-Host '  All repair steps completed. Restart, then retry Store, winget, Xbox, or Game Pass.' -ForegroundColor Green
    Set-StepStatus -Step 'RestoreUpdatesStore' -Status complete -Detail 'All repair steps completed.'
} else {
    Write-Host "  $($failed.Count) step(s) failed. Review the [FAIL] lines above." -ForegroundColor Yellow
    Write-Host '  Use Diagnostics / Export Error Report from the launcher if you need help.' -ForegroundColor DarkGray
    Set-StepStatus -Step 'RestoreUpdatesStore' -Status failed -Detail "$($failed.Count) repair step(s) failed."
}
Write-Host ''

Write-SectionComplete 'Step 6 - Restore Windows Update and Store'
return
