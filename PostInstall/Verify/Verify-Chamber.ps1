#Requires -Version 5.1
<#
Chamber - Verify System (standalone, read-only)

Checks every tweak the playbook applies against actual system state, using
Verify\verification-manifest.json (generated from the playbook YAML by
tools/generate_verification_manifest.py), plus hardware checks the playbook
can't control (Secure Boot, VBS, HAGS, MSI mode).

Makes zero changes. Params:
  -Detailed      Show every individual check, not just problems
  -ClientReport  Zip results + system info onto the Desktop for support
#>
[CmdletBinding()]
param(
    [switch]$Detailed,
    [switch]$ClientReport
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Inline helpers (no dependencies) --------------------------------------
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host ''
    Write-Host '  This script needs Administrator. Right-click START-HERE.bat > Run as administrator.' -ForegroundColor Red
    Write-Host ''
    exit 2
}

function Write-Result {
    param([string]$Status, [string]$Label, [string]$Detail = '')
    $color = switch ($Status) {
        'PASS'     { 'Green' }
        'FAIL'     { 'Red' }
        'WARN'     { 'Yellow' }
        'DISABLED' { 'DarkGray' }
        default    { 'Cyan' }
    }
    Write-Host ("  [{0,-8}] {1}" -f $Status, $Label) -ForegroundColor $color
    if ($Detail) { Write-Host ("             {0}" -f $Detail) -ForegroundColor DarkGray }
}

$checks = [System.Collections.Generic.List[hashtable]]::new()
function Add-Check {
    param([string]$Status, [string]$Category, [string]$Label, [string]$Detail = '')
    $checks.Add(@{ Status = $Status; Category = $Category; Label = $Label; Detail = $Detail })
}

Write-Host ''
Write-Host ('=' * 60) -ForegroundColor DarkMagenta
Write-Host '  CHAMBER - SYSTEM VERIFICATION' -ForegroundColor Magenta
Write-Host ('=' * 60) -ForegroundColor DarkMagenta
Write-Host '  Read-only. No changes will be made.' -ForegroundColor DarkGray
Write-Host ''

# --- Load manifest ----------------------------------------------------------
$manifestPath = Join-Path $PSScriptRoot 'verification-manifest.json'
$manifest = $null
if (Test-Path -LiteralPath $manifestPath) {
    try {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        Write-Host "  Manifest generated: $($manifest.generatedUtc)" -ForegroundColor DarkGray
        Write-Host ''
    } catch {
        Add-Check 'WARN' 'Manifest' 'Manifest load' "Could not parse manifest: $($_.Exception.Message)"
    }
} else {
    Add-Check 'WARN' 'Manifest' 'Manifest load' 'verification-manifest.json missing - hardware checks only'
}

function ConvertTo-PsRegPath {
    param([string]$AmePath)
    return ($AmePath -replace '^HKLM\\', 'HKLM:\' -replace '^HKCU\\', 'HKCU:\' `
                     -replace '^HKCR\\', 'Registry::HKEY_CLASSES_ROOT\' -replace '^HKU\\', 'Registry::HKEY_USERS\')
}

# --- Registry ---------------------------------------------------------------
if ($manifest) {
    $regFail = 0; $regPass = 0; $optSkipped = 0
    foreach ($entry in $manifest.registryValues) {
        $isOptional = [bool]($entry.PSObject.Properties.Name -contains 'option')
        $psPath = ConvertTo-PsRegPath $entry.path
        $actual = '<not set>'
        $match = $false
        try {
            $item = Get-ItemProperty -LiteralPath $psPath -Name $entry.value -ErrorAction Stop
            $actual = [string]$item.($entry.value)
            if ($entry.type -match 'REG_DWORD|REG_QWORD') {
                $match = ($actual -eq [string]([int64]$entry.data))
            } else {
                $match = ($actual -eq [string]$entry.data)
            }
        } catch { }
        $label = "$($entry.path)\$($entry.value)"
        if ($match) {
            $regPass++
            if ($Detailed) { Add-Check 'PASS' 'Registry' $label "= $($entry.data)" }
        } elseif ($isOptional) {
            $optSkipped++
            if ($Detailed) { Add-Check 'INFO' 'Registry' $label "optional [$($entry.option)] not applied (actual: $actual)" }
        } else {
            $regFail++
            Add-Check 'FAIL' 'Registry' $label "expected $($entry.data) [$($entry.type)], actual: $actual (from $($entry.source))"
        }
    }
    Add-Check ($(if ($regFail -eq 0) { 'PASS' } else { 'FAIL' })) 'Registry' 'Registry tweaks' `
        "$regPass/$(@($manifest.registryValues).Count) applied, $regFail failed, $optSkipped optional not applied"

    # --- Services -----------------------------------------------------------
    $svcFail = 0; $svcPass = 0; $svcOpt = 0
    foreach ($svc in $manifest.services) {
        $isOptional = [bool]($svc.PSObject.Properties.Name -contains 'option')
        $startKey = "HKLM:\SYSTEM\CurrentControlSet\Services\$($svc.name)"
        $actual = $null
        if (Test-Path -LiteralPath $startKey) {
            $actual = (Get-ItemProperty -LiteralPath $startKey -Name 'Start' -ErrorAction SilentlyContinue).Start
        }
        if ($null -eq $actual) {
            if ($isOptional) { $svcOpt++; if ($Detailed) { Add-Check 'INFO' 'Services' $svc.name "optional [$($svc.option)] - service not present" } }
            else { Add-Check 'WARN' 'Services' $svc.name 'service key not found (removed or renamed on this build?)' }
        } elseif ($actual -eq $svc.startup) {
            $svcPass++
            if ($Detailed) { Add-Check 'PASS' 'Services' $svc.name "startup = $actual" }
        } elseif ($isOptional) {
            $svcOpt++
            if ($Detailed) { Add-Check 'INFO' 'Services' $svc.name "optional [$($svc.option)] not applied (startup = $actual)" }
        } else {
            $svcFail++
            Add-Check 'FAIL' 'Services' $svc.name "expected startup $($svc.startup), actual $actual (from $($svc.source))"
        }
    }
    Add-Check ($(if ($svcFail -eq 0) { 'PASS' } else { 'FAIL' })) 'Services' 'Service startup types' `
        "$svcPass/$(@($manifest.services).Count) as configured, $svcFail mismatched, $svcOpt optional"

    # --- BCD ------------------------------------------------------------
    try {
        $bcdOut = (& bcdedit /enum '{current}' 2>&1) -join "`n"
        foreach ($flag in $manifest.bcd.flags) {
            $pattern = "(?im)^\s*$([regex]::Escape($flag.flag))\s+(\S+)"
            if ($bcdOut -match $pattern) {
                $actual = $Matches[1]
                if ($actual -ieq $flag.expected) { Add-Check 'PASS' 'BCD' $flag.flag "= $actual" }
                else { Add-Check ($(if ($flag.tolerant) { 'WARN' } else { 'FAIL' })) 'BCD' $flag.flag "expected $($flag.expected), actual $actual" }
            } else {
                Add-Check ($(if ($flag.tolerant) { 'WARN' } else { 'FAIL' })) 'BCD' $flag.flag 'not present (unsupported on this hardware?)'
            }
        }
        if ($null -ne $manifest.bcd.timeout) {
            $bootMgr = (& bcdedit /enum '{bootmgr}' 2>&1) -join "`n"
            if ($bootMgr -match '(?im)^\s*timeout\s+(\d+)') {
                $t = [int]$Matches[1]
                Add-Check ($(if ($t -eq $manifest.bcd.timeout) { 'PASS' } else { 'WARN' })) 'BCD' 'Boot timeout' "= $t (expected $($manifest.bcd.timeout))"
            }
        }
    } catch {
        Add-Check 'WARN' 'BCD' 'BCD flags' "Could not run bcdedit: $($_.Exception.Message)"
    }

    # --- Hosts telemetry blocks ----------------------------------------------
    try {
        $hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
        $hostsText = if (Test-Path -LiteralPath $hostsPath) { Get-Content -LiteralPath $hostsPath -Raw } else { '' }
        $missing = @($manifest.hostsEntries | Where-Object { $hostsText -notmatch [regex]::Escape($_) })
        if ($missing.Count -eq 0) { Add-Check 'PASS' 'Privacy' 'Hosts telemetry blocks' "$(@($manifest.hostsEntries).Count) entries present" }
        else { Add-Check 'FAIL' 'Privacy' 'Hosts telemetry blocks' "$($missing.Count) missing: $($missing -join ', ')" }
    } catch {
        Add-Check 'WARN' 'Privacy' 'Hosts telemetry blocks' 'Could not read hosts file'
    }

    # --- Debloat --------------------------------------------------------------
    try {
        $provisionedNames = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Select-Object -ExpandProperty DisplayName)
        $leftovers = [System.Collections.Generic.List[string]]::new()
        foreach ($name in $manifest.debloat.balanced) {
            $installed = @(Get-AppxPackage -AllUsers -Name $name -ErrorAction SilentlyContinue)
            if ($installed.Count -gt 0 -or ($provisionedNames -contains $name)) { $leftovers.Add($name) }
        }
        if ($leftovers.Count -eq 0) {
            Add-Check 'PASS' 'Debloat' 'Balanced debloat' "all $(@($manifest.debloat.balanced).Count) target packages absent"
        } else {
            $sample = @($leftovers | Select-Object -First 6) -join ', '
            $suffix = if ($leftovers.Count -gt 6) { ", +$($leftovers.Count - 6) more" } else { '' }
            Add-Check 'WARN' 'Debloat' 'Balanced debloat' "$($leftovers.Count) still present: $sample$suffix"
        }
        $xboxPresent = @($manifest.debloat.xbox | Where-Object {
            @(Get-AppxPackage -AllUsers -Name $_ -ErrorAction SilentlyContinue).Count -gt 0
        })
        if ($xboxPresent.Count -gt 0) { Add-Check 'INFO' 'Debloat' 'Xbox packages' "present - expected unless 'Remove Xbox Services' was selected" }
        else { Add-Check 'INFO' 'Debloat' 'Xbox packages' 'removed (Remove Xbox Services was selected)' }
    } catch {
        Add-Check 'WARN' 'Debloat' 'AppX state' 'Could not query AppX package state'
    }
}

# --- Hardware checks ---------------------------------------------------------
try {
    $vbs = Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName 'Win32_DeviceGuard' -ErrorAction Stop
    switch ($vbs.VirtualizationBasedSecurityStatus) {
        0 { Add-Check 'DISABLED' 'Hardware' 'VBS' 'Disabled - good for performance' }
        1 { Add-Check 'WARN' 'Hardware' 'VBS' 'Enabled but not running - reboot may activate it' }
        default { Add-Check 'INFO' 'Hardware' 'VBS' 'Running - expected unless "Disable VBS/HVCI" was selected' }
    }
} catch { Add-Check 'WARN' 'Hardware' 'VBS' 'Could not query DeviceGuard' }

try {
    if (Confirm-SecureBootUEFI) { Add-Check 'PASS' 'Hardware' 'Secure Boot' 'Enabled - Vanguard/Valorant compatible' }
    else { Add-Check 'WARN' 'Hardware' 'Secure Boot' 'Disabled - Riot Vanguard (Valorant) will NOT work' }
} catch { Add-Check 'INFO' 'Hardware' 'Secure Boot' 'Could not determine (non-UEFI system?)' }

try {
    $hagsVal = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name 'HwSchMode' -ErrorAction SilentlyContinue).HwSchMode
    if ($hagsVal -eq 2) { Add-Check 'PASS' 'Hardware' 'HAGS' 'Enabled (HwSchMode = 2)' }
    elseif ($null -eq $hagsVal) { Add-Check 'WARN' 'Hardware' 'HAGS' 'Key not found - install GPU driver first' }
    else { Add-Check 'FAIL' 'Hardware' 'HAGS' "Not enabled (HwSchMode = $hagsVal)" }
} catch { Add-Check 'WARN' 'Hardware' 'HAGS' 'Could not read registry' }

$msiPropsRelPath = 'Device Parameters\Interrupt Management\MessageSignaledInterruptProperties'
$msiDevices = @()
$msiDevices += @(Get-PnpDevice -Class Display -ErrorAction SilentlyContinue |
                 Where-Object { $_.Status -eq 'OK' -and $_.FriendlyName -notmatch 'Microsoft' })
$msiDevices += @(Get-PnpDevice -Class Net -ErrorAction SilentlyContinue |
                 Where-Object {
                     $_.Status -eq 'OK' -and
                     $_.FriendlyName -notmatch 'Virtual|WAN|Loopback|Bluetooth|Wi-Fi Direct|Miniport|VPN|TAP|Kernel Debug'
                 })
foreach ($dev in $msiDevices) {
    try {
        $msiKey = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($dev.InstanceId)\$msiPropsRelPath"
        $val = (Get-ItemProperty -LiteralPath $msiKey -Name 'MSISupported' -ErrorAction SilentlyContinue).MSISupported
        if ($val -eq 1) { Add-Check 'PASS' 'Hardware' "MSI [$($dev.FriendlyName)]" 'Enabled' }
        else { Add-Check 'INFO' 'Hardware' "MSI [$($dev.FriendlyName)]" 'Not in MSI mode' }
    } catch { Add-Check 'WARN' 'Hardware' "MSI [$($dev.FriendlyName)]" 'Could not read registry' }
}

try {
    $powerOutput = & powercfg /getactivescheme 2>&1
    if ($powerOutput -match '11111111-1111-1111-1111-111111111111') { Add-Check 'PASS' 'Power' 'Power Plan' 'Chamber Ultimate Performance active' }
    elseif ($powerOutput -match 'e9a42b02') { Add-Check 'PASS' 'Power' 'Power Plan' 'Ultimate Performance active' }
    else {
        $planName = if ($powerOutput -match '\((.+)\)') { $Matches[1] } else { [string]$powerOutput }
        Add-Check 'WARN' 'Power' 'Power Plan' "Active plan: $planName"
    }
} catch { Add-Check 'WARN' 'Power' 'Power Plan' 'Could not query active scheme' }

try {
    $defenderService = Get-Service -Name 'WinDefend' -ErrorAction SilentlyContinue
    if (-not $defenderService) { Add-Check 'DISABLED' 'Security' 'Defender' 'WinDefend service not present' }
    elseif ($defenderService.Status -ne 'Running') { Add-Check 'DISABLED' 'Security' 'Defender' "Service status: $($defenderService.Status)" }
    else { Add-Check 'INFO' 'Security' 'Defender' 'Running' }
} catch { Add-Check 'WARN' 'Security' 'Defender' 'Could not query Defender state' }

try { Add-Check 'INFO' 'Stats' 'Process Count' "$(@(Get-Process).Count) running processes" } catch { }

# --- Output -------------------------------------------------------------------
Write-Host ''
foreach ($c in $checks) { Write-Result -Status $c.Status -Label $c.Label -Detail $c.Detail }

$failCount = @($checks | Where-Object { $_.Status -eq 'FAIL' }).Count
$warnCount = @($checks | Where-Object { $_.Status -eq 'WARN' }).Count
Write-Host ''
Write-Host "  Summary: $(@($checks).Count) checks - $failCount failed, $warnCount warnings" `
    -ForegroundColor $(if ($failCount -gt 0) { 'Red' } elseif ($warnCount -gt 0) { 'Yellow' } else { 'Green' })

# --- JSON export + optional client report -------------------------------------
try {
    $logDir = Join-Path $env:ProgramData 'ChamberPostInstall\logs'
    if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $jsonPath = Join-Path $logDir "verify-$stamp.json"

    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $ver = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
    $report = [ordered]@{
        timestamp    = (Get-Date).ToString('o')
        computerName = $env:COMPUTERNAME
        os           = [ordered]@{
            caption        = if ($os) { $os.Caption } else { $null }
            build          = if ($ver) { "$($ver.CurrentBuildNumber).$($ver.UBR)" } else { $null }
            displayVersion = if ($ver) { $ver.DisplayVersion } else { $null }
        }
        cpu          = (Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Name)
        gpu          = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
        manifestGeneratedUtc = if ($manifest) { $manifest.generatedUtc } else { $null }
        summary      = [ordered]@{ total = @($checks).Count; failed = $failCount; warnings = $warnCount }
        checks       = $checks
    }
    $report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
    Write-Host "  Results saved: $jsonPath" -ForegroundColor DarkGray

    if ($ClientReport) {
        $desktop = [Environment]::GetFolderPath('Desktop')
        $bundleDir = Join-Path $env:TEMP "ChamberReport-$stamp"
        New-Item -ItemType Directory -Path $bundleDir -Force | Out-Null
        Copy-Item -LiteralPath $jsonPath -Destination $bundleDir
        Get-ChildItem -LiteralPath $logDir -Filter '*.json' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 5 |
            Copy-Item -Destination $bundleDir -ErrorAction SilentlyContinue
        $zipPath = Join-Path $desktop "ChamberReport-$stamp.zip"
        Compress-Archive -Path (Join-Path $bundleDir '*') -DestinationPath $zipPath -Force
        Remove-Item -LiteralPath $bundleDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host ''
        Write-Host "  Client report created: $zipPath" -ForegroundColor Green
        Write-Host '  Send this zip to ChamberTech support.' -ForegroundColor White
    }
} catch {
    Write-Host "  WARN: Could not write results: $($_.Exception.Message)" -ForegroundColor Yellow
}

Write-Host ''
