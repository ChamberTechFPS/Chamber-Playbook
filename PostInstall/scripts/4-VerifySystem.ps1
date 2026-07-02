#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\Shared.ps1"

[void](Initialize-ChamberLog -Name 'verify-system')
Assert-Admin
Set-StepStatus -Step 'VerifySystem' -Status running

Write-Header 'Step 4 - Verify System'

Write-Host '  Running read-only checks. No changes will be made.' -ForegroundColor DarkGray
Write-Host ''

$checks = [System.Collections.Generic.List[hashtable]]::new()

function Add-Check {
    param([string]$Status, [string]$Label, [string]$Detail = '')
    $checks.Add(@{ Status = $Status; Label = $Label; Detail = $Detail })
}

function Get-DebloatVerificationTargets {
    return @(
        'Microsoft.OutlookForWindows',
        'microsoft.windowscommunicationsapps',
        'Microsoft.MicrosoftSolitaireCollection',
        'MSTeams',
        'MicrosoftTeams',
        'Microsoft.MicrosoftTeams',
        'Clipchamp.Clipchamp',
        'Microsoft.Copilot',
        'MicrosoftWindows.Client.WebExperience',
        'Microsoft.WidgetsPlatformRuntime',
        'Microsoft.YourPhone',
        'Microsoft.BingNews',
        'Microsoft.BingWeather',
        'Microsoft.BingSearch',
        'Microsoft.BingFinance',
        'Microsoft.BingSports',
        'Microsoft.WindowsFeedbackHub',
        'Microsoft.GetHelp',
        'Microsoft.Getstarted',
        'Microsoft.ZuneVideo',
        'Microsoft.ZuneMusic',
        'Microsoft.WindowsSoundRecorder',
        'MicrosoftCorporationII.MicrosoftFamily',
        'Microsoft.People',
        'Microsoft.Todos',
        'Microsoft.PowerAutomateDesktop',
        'Microsoft.Whiteboard',
        'Microsoft.WindowsMaps',
        'Microsoft.MicrosoftOfficeHub',
        'Microsoft.MicrosoftPowerBIForWindows',
        'SpotifyAB.SpotifyMusic',
        'Microsoft.Windows.DevHome',
        'MicrosoftCorporationII.DevHome',
        'Microsoft.DevHome',
        '7EE7776C.LinkedInforWindows',
        'Microsoft.LinkedIn',
        'Microsoft.SkypeApp',
        'Microsoft.549981C3F5F10',
        'Microsoft.MixedReality.Portal'
    )
}

# --- VBS (Virtualization Based Security) ---
try {
    $vbs = Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName 'Win32_DeviceGuard' -ErrorAction Stop
    # 0 = not running, 1 = enabled not running, 2 = enabled and running
    $vbsStatus = $vbs.VirtualizationBasedSecurityStatus
    if ($vbsStatus -eq 0) {
        Add-Check 'DISABLED' 'VBS' 'Disabled — good for performance'
    } elseif ($vbsStatus -eq 1) {
        Add-Check 'WARN' 'VBS' 'Enabled but not running — reboot may activate it'
    } else {
        Add-Check 'FAIL' 'VBS' 'Running — check playbook ran correctly'
    }
} catch {
    Add-Check 'WARN' 'VBS' 'Could not query DeviceGuard WMI namespace'
}

# --- Secure Boot ---
try {
    $secureBoot = Confirm-SecureBootUEFI
    if ($secureBoot) {
        Add-Check 'PASS' 'Secure Boot' 'Enabled — Vanguard/Valorant compatible'
    } else {
        Add-Check 'WARN' 'Secure Boot' 'Disabled — Riot Vanguard (Valorant) will NOT work'
    }
} catch {
    Add-Check 'INFO' 'Secure Boot' 'Could not determine state (non-UEFI system?)'
}

# --- HAGS (Hardware Accelerated GPU Scheduling) ---
try {
    $hagsVal = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' `
                                 -Name 'HwSchMode' -ErrorAction SilentlyContinue).HwSchMode
    if ($hagsVal -eq 2) {
        Add-Check 'PASS' 'HAGS' 'Enabled (HwSchMode = 2)'
    } elseif ($null -eq $hagsVal) {
        Add-Check 'WARN' 'HAGS' 'Registry key not found — may need GPU driver'
    } else {
        Add-Check 'FAIL' 'HAGS' "Not enabled (HwSchMode = $hagsVal)"
    }
} catch {
    Add-Check 'WARN' 'HAGS' 'Could not read registry'
}

# --- MSI Mode (GPU + NIC) ---
$msiPropsRelPath = 'Device Parameters\Interrupt Management\MessageSignaledInterruptProperties'

$displayDevices = Get-PnpDevice -Class Display -ErrorAction SilentlyContinue |
                  Where-Object { $_.Status -eq 'OK' -and $_.FriendlyName -notmatch 'Microsoft' }
foreach ($dev in $displayDevices) {
    try {
        $msiKey = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($dev.InstanceId)\$msiPropsRelPath"
        $val = (Get-ItemProperty -LiteralPath $msiKey -Name 'MSISupported' -ErrorAction SilentlyContinue).MSISupported
        if ($val -eq 1) {
            Add-Check 'PASS' "MSI [$($dev.FriendlyName)]" 'Enabled'
        } else {
            Add-Check 'WARN' "MSI [$($dev.FriendlyName)]" 'Not enabled — run Step 3'
        }
    } catch {
        Add-Check 'WARN' "MSI [$($dev.FriendlyName)]" 'Could not read registry'
    }
}

$nicDevices = Get-PnpDevice -Class Net -ErrorAction SilentlyContinue |
              Where-Object {
                  $_.Status -eq 'OK' -and
                  $_.FriendlyName -notmatch 'Virtual|WAN|Loopback|Bluetooth|Wi-Fi Direct|Miniport|VPN|TAP|Kernel Debug'
              }
foreach ($dev in $nicDevices) {
    try {
        $msiKey = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($dev.InstanceId)\$msiPropsRelPath"
        $val = (Get-ItemProperty -LiteralPath $msiKey -Name 'MSISupported' -ErrorAction SilentlyContinue).MSISupported
        if ($val -eq 1) {
            Add-Check 'PASS' "MSI [$($dev.FriendlyName)]" 'Enabled'
        } else {
            Add-Check 'WARN' "MSI [$($dev.FriendlyName)]" 'Not enabled — run Step 3'
        }
    } catch {
        Add-Check 'WARN' "MSI [$($dev.FriendlyName)]" 'Could not read registry'
    }
}

# --- Power Plan ---
try {
    $powerOutput = & powercfg /getactivescheme 2>&1
    $chamberGuid = '11111111-1111-1111-1111-111111111111'
    if ($powerOutput -match $chamberGuid) {
        Add-Check 'PASS' 'Power Plan' 'Chamber Ultimate Performance active'
    } elseif ($powerOutput -match 'e9a42b02') {
        Add-Check 'PASS' 'Power Plan' 'Ultimate Performance active'
    } else {
        $planName = if ($powerOutput -match '\((.+)\)') { $Matches[1] } else { $powerOutput }
        Add-Check 'WARN' 'Power Plan' "Active plan: $planName"
    }
} catch {
    Add-Check 'WARN' 'Power Plan' 'Could not query active scheme'
}

# --- Process Count ---
try {
    $processCount = @(Get-Process -ErrorAction Stop).Count
    Add-Check 'INFO' 'Process Count' "$processCount running processes"
} catch {
    Add-Check 'WARN' 'Process Count' 'Could not query running processes'
}

# --- Defender / Windows Security ---
try {
    $defenderService = Get-Service -Name 'WinDefend' -ErrorAction SilentlyContinue
    if (-not $defenderService) {
        Add-Check 'DISABLED' 'Defender' 'WinDefend service not present'
    } elseif ($defenderService.Status -ne 'Running') {
        Add-Check 'DISABLED' 'Defender' "Service status: $($defenderService.Status)"
    } else {
        $mpStatus = $null
        if (Get-Command Get-MpComputerStatus -ErrorAction SilentlyContinue) {
            $mpStatus = Get-MpComputerStatus -ErrorAction SilentlyContinue
        }

        if ($mpStatus -and $mpStatus.RealTimeProtectionEnabled) {
            Add-Check 'PASS' 'Defender' 'Running with real-time protection enabled'
        } else {
            Add-Check 'INFO' 'Defender' 'Service running; real-time protection state unavailable or disabled'
        }
    }
} catch {
    Add-Check 'WARN' 'Defender' 'Could not query Defender state'
}

# --- Debloat leftovers ---
try {
    $provisionedNames = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Select-Object -ExpandProperty DisplayName)
    $leftovers = [System.Collections.Generic.List[string]]::new()

    foreach ($name in (Get-DebloatVerificationTargets)) {
        $installed = @(Get-AppxPackage -AllUsers -Name $name -ErrorAction SilentlyContinue)
        $isProvisioned = $provisionedNames -contains $name
        if ($installed.Count -gt 0 -or $isProvisioned) {
            $leftovers.Add($name)
        }
    }

    if ($leftovers.Count -eq 0) {
        Add-Check 'PASS' 'Debloat' 'Balanced bloat targets removed'
    } else {
        $sample = @($leftovers | Select-Object -First 6) -join ', '
        $suffix = if ($leftovers.Count -gt 6) { ", +$($leftovers.Count - 6) more" } else { '' }
        Add-Check 'WARN' 'Debloat' "$($leftovers.Count) target package(s) still present: $sample$suffix"
    }
} catch {
    Add-Check 'WARN' 'Debloat' 'Could not query AppX package state'
}

# --- Explorer defaults ---
try {
    $advancedPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    $launchTo = (Get-ItemProperty -LiteralPath $advancedPath -Name 'LaunchTo' -ErrorAction SilentlyContinue).LaunchTo
    if ($launchTo -eq 1) {
        Add-Check 'PASS' 'Explorer Launch' 'Opens to This PC'
    } else {
        Add-Check 'WARN' 'Explorer Launch' "LaunchTo value: $launchTo"
    }
} catch {
    Add-Check 'WARN' 'Explorer Launch' 'Could not read Explorer LaunchTo setting'
}

# --- Classic context menu ---
try {
    $classicMenuPath = 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32'
    if (Test-Path -LiteralPath $classicMenuPath) {
        Add-Check 'PASS' 'Context Menu' 'Classic right-click menu key present'
    } else {
        Add-Check 'WARN' 'Context Menu' 'Classic menu registry key missing'
    }
} catch {
    Add-Check 'WARN' 'Context Menu' 'Could not query classic menu setting'
}

# --- Output ---
Write-Host ('=' * 60) -ForegroundColor DarkCyan
Write-Host '  System Check Results' -ForegroundColor Cyan
Write-Host ('=' * 60) -ForegroundColor DarkCyan
Write-Host ''

foreach ($c in $checks) {
    Write-Result -Status $c.Status -Label $c.Label -Detail $c.Detail
}

Write-Host ''
Set-StepStatus -Step 'VerifySystem' -Status complete -Detail 'Verification checks finished.'
Write-SectionComplete 'Step 4 - System Verification'
