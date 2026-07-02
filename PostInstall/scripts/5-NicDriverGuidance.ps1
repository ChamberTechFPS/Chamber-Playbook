#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\Shared.ps1"

[void](Initialize-ChamberLog -Name 'nic-guidance')
Assert-Admin
Set-StepStatus -Step 'NicGuidance' -Status running

Write-Header 'Step 5 - NIC Driver Guidance'

# PCI Vendor ID -> (vendor name, driver URL, notes)
$vendorMap = @{
    '8086' = @{ Name = 'Intel';   Url = 'https://www.intel.com/content/www/us/en/download-center/home.html';             Note = 'Use Intel Driver & Support Assistant for auto-detection.' }
    '10EC' = @{ Name = 'Realtek'; Url = 'https://www.realtek.com/en/component/zoo/category/network-interface-controllers-10-100-1000m-gigabit-ethernet-pcie'; Note = 'Match your specific chipset (e.g. RTL8125, RTL8111).' }
    '14E4' = @{ Name = 'Broadcom';Url = 'https://www.broadcom.com/support/download-search';                              Note = '' }
    '1969' = @{ Name = 'Killer';  Url = 'https://www.killernetworking.com/support/drivers/';                             Note = 'Killer NICs are Intel-owned. Avoid Killer Control Center — drivers only.' }
    '1AF4' = @{ Name = 'Killer';  Url = 'https://www.killernetworking.com/support/drivers/';                             Note = 'Killer NICs are Intel-owned. Avoid Killer Control Center — drivers only.' }
    'E091' = @{ Name = 'Killer';  Url = 'https://www.killernetworking.com/support/drivers/';                             Note = '' }
}

$physicalNics = Get-PnpDevice -Class Net -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.Status -eq 'OK' -and
                    $_.FriendlyName -notmatch 'Virtual|WAN|Loopback|Bluetooth|Wi-Fi Direct|Miniport|VPN|TAP|Kernel Debug'
                }

if (-not $physicalNics) {
    Write-Host '  No physical network adapters detected.' -ForegroundColor Yellow
    Wait-AnyKey '  Press any key to return to the menu...'
    return
}

foreach ($nic in $physicalNics) {
    Write-Host "  Adapter: $($nic.FriendlyName)" -ForegroundColor White

    # Extract PCI vendor ID from InstanceId (format: PCI\VEN_XXXX&DEV_YYYY&...)
    $vendorId = $null
    if ($nic.InstanceId -match 'VEN_([0-9A-Fa-f]{4})') {
        $vendorId = $Matches[1].ToUpper()
    }

    $vendorInfo = if ($vendorId -and $vendorMap.ContainsKey($vendorId)) { $vendorMap[$vendorId] } else { $null }

    if ($vendorInfo) {
        Write-Host "  Vendor: $($vendorInfo.Name) (PCI VEN $vendorId)" -ForegroundColor DarkGray
        if ($vendorInfo.Note) {
            Write-Host "  Note:   $($vendorInfo.Note)" -ForegroundColor DarkGray
        }
        Write-Host "  Driver: $($vendorInfo.Url)" -ForegroundColor Cyan
    } else {
        Write-Host "  Vendor: Unknown (PCI VEN $vendorId)" -ForegroundColor DarkGray
        Write-Host '  Check your motherboard manufacturer for NIC drivers.' -ForegroundColor DarkGray
    }

    # Current interrupt moderation state
    $nicName = $nic.FriendlyName
    try {
        $imProp = Get-NetAdapterAdvancedProperty -Name $nicName -RegistryKeyword 'InterruptModeration' -ErrorAction SilentlyContinue
        if ($imProp) {
            $imEnabled = $imProp.RegistryValue -ne '0'
            $imStatus  = if ($imEnabled) { 'Enabled (default)' } else { 'Disabled' }
            Write-Host "  Interrupt Moderation: $imStatus" -ForegroundColor DarkGray
        }
    } catch {
        # Property may not exist on all NICs
    }

    Write-Host ''
}

# Open driver pages
Write-Host ''
$openPages = $physicalNics | ForEach-Object {
    if ($_.InstanceId -match 'VEN_([0-9A-Fa-f]{4})') {
        $vendorId = $Matches[1].ToUpper()
        if ($vendorMap.ContainsKey($vendorId)) {
            $vendorMap[$vendorId].Url
        }
    }
} | Where-Object { $_ } | Select-Object -Unique

if ($openPages) {
    if (Confirm-Continue '  Open NIC driver download page(s) in browser?') {
        foreach ($url in $openPages) { Start-Process $url }
    }
    Write-Host ''
}

# Interrupt moderation tweak offer
$nicNames = $physicalNics.FriendlyName
$imTargets = $nicNames | Where-Object {
    try {
        $p = Get-NetAdapterAdvancedProperty -Name $_ -RegistryKeyword 'InterruptModeration' -ErrorAction SilentlyContinue
        $p -and $p.RegistryValue -ne '0'
    } catch { $false }
}

if ($imTargets) {
    Write-Host '  Disabling Interrupt Moderation reduces latency at the cost of slightly higher CPU usage.' -ForegroundColor DarkGray
    Write-Host ''
    if (Confirm-Continue '  Disable Interrupt Moderation on detected adapters?') {
        Backup-ChamberRegistry -Label 'nic-interrupt-moderation'
        foreach ($name in $imTargets) {
            try {
                Set-NetAdapterAdvancedProperty -Name $name -RegistryKeyword 'InterruptModeration' -RegistryValue '0'
                Write-Result -Status 'PASS' -Label $name -Detail 'Interrupt Moderation disabled'
            } catch {
                Write-Result -Status 'FAIL' -Label $name -Detail $_.Exception.Message
            }
        }
        Write-Host ''
        Write-Host '  A reboot is required for NIC changes to take effect.' -ForegroundColor Yellow
    }
}

# Chipset driver guidance
Write-Host ''
Write-Host '  Chipset Drivers:' -ForegroundColor White
$chipsetPages = [System.Collections.Generic.List[string]]::new()
try {
    $cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Select-Object -First 1
    $cpuName = [string]$cpu.Name
    Write-Host "    CPU detected: $cpuName" -ForegroundColor DarkGray
    if ($cpuName -match 'AMD') {
        $chipsetPages.Add('https://www.amd.com/en/support/download/drivers.html')
        Write-Host '    AMD chipset drivers: AMD support page' -ForegroundColor DarkGray
    } elseif ($cpuName -match 'Intel') {
        $chipsetPages.Add('https://www.intel.com/content/www/us/en/support/detect.html')
        Write-Host '    Intel chipset/device scan: Intel Driver & Support Assistant' -ForegroundColor DarkGray
    } else {
        Write-Host '    Check motherboard or laptop support page for chipset drivers.' -ForegroundColor DarkGray
    }
} catch {
    Write-Host '    Could not detect CPU vendor. Check motherboard or laptop support page for chipset drivers.' -ForegroundColor DarkGray
}

try {
    $board = Get-CimInstance -ClassName Win32_BaseBoard -ErrorAction Stop | Select-Object -First 1
    if ($board.Manufacturer -or $board.Product) {
        Write-Host "    Board detected: $($board.Manufacturer) $($board.Product)" -ForegroundColor DarkGray
    }
} catch { }

if ($chipsetPages.Count -gt 0) {
    Write-Host ''
    if (Confirm-Continue '  Open chipset/device driver page now?') {
        foreach ($url in $chipsetPages) {
            Start-Process $url
            Write-ChamberLog "Opened chipset/device driver page: $url"
        }
    }
}

Write-Host ''
Write-Host '  Optional Windows driver page:' -ForegroundColor White
Write-Host '    Settings > Windows Update > Advanced options > Optional updates' -ForegroundColor DarkGray
if (Confirm-Continue '  Open Windows Optional Updates settings now?') {
    Start-Process 'ms-settings:windowsupdate-optionalupdates'
}

Set-StepStatus -Step 'NicGuidance' -Status complete -Detail 'NIC guidance finished.'
Write-SectionComplete 'Step 5 - NIC Driver Guidance'
