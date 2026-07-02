#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\Shared.ps1"

[void](Initialize-ChamberLog -Name 'msi-mode')
Assert-Admin
Set-StepStatus -Step 'MSIMode' -Status running

Write-Header 'Step 3 - Enable MSI Interrupt Mode'

Write-Host '  MSI (Message Signaled Interrupts) reduces interrupt latency for GPU and NIC.' -ForegroundColor DarkGray
Write-Host ''
Backup-ChamberRegistry -Label 'msi-mode'

$msiPropsPath = 'Device Parameters\Interrupt Management\MessageSignaledInterruptProperties'
$results = [System.Collections.Generic.List[hashtable]]::new()

function Set-MsiMode {
    param(
        [string]$InstanceId,
        [string]$FriendlyName,
        [string]$DeviceClass  # 'GPU' or 'NIC'
    )

    $enumBase = "HKLM:\SYSTEM\CurrentControlSet\Enum\$InstanceId"
    $msiKey   = "$enumBase\$msiPropsPath"

    $result = @{ Name = $FriendlyName; Class = $DeviceClass; Status = 'FAIL'; Detail = '' }

    try {
        # Create the full key path if it does not exist
        if (-not (Test-Path -LiteralPath $msiKey)) {
            [void](New-Item -Path $msiKey -Force)
        }

        $current = (Get-ItemProperty -LiteralPath $msiKey -Name 'MSISupported' -ErrorAction SilentlyContinue).MSISupported

        if ($current -eq 1) {
            $result.Status = 'PASS'
            $result.Detail = 'Already enabled'
        } else {
            Set-ItemProperty -LiteralPath $msiKey -Name 'MSISupported' -Value 1 -Type DWord

            # Limit to 1 MSI vector on NICs for lower latency
            if ($DeviceClass -eq 'NIC') {
                Set-ItemProperty -LiteralPath $msiKey -Name 'MessageNumberLimit' -Value 1 -Type DWord
            }

            $result.Status = 'PASS'
            $result.Detail = 'Enabled'
        }
    } catch {
        $result.Status = 'FAIL'
        $result.Detail = $_.Exception.Message
    }

    return $result
}

# --- GPU ---
Write-Host '  Scanning display adapters...' -ForegroundColor DarkGray
$gpuDevices = Get-PnpDevice -Class Display -ErrorAction SilentlyContinue |
              Where-Object { $_.Status -eq 'OK' -and $_.FriendlyName -notmatch 'Microsoft' }

if ($gpuDevices) {
    foreach ($dev in $gpuDevices) {
        $r = Set-MsiMode -InstanceId $dev.InstanceId -FriendlyName $dev.FriendlyName -DeviceClass 'GPU'
        $results.Add($r)
    }
} else {
    Write-Host '  No GPU devices found.' -ForegroundColor Yellow
}

# --- NIC ---
Write-Host '  Scanning network adapters...' -ForegroundColor DarkGray
$nicDevices = Get-PnpDevice -Class Net -ErrorAction SilentlyContinue |
              Where-Object {
                  $_.Status -eq 'OK' -and
                  $_.FriendlyName -notmatch 'Virtual|WAN|Loopback|Bluetooth|Wi-Fi Direct|Miniport|VPN|TAP|Kernel Debug'
              }

if ($nicDevices) {
    foreach ($dev in $nicDevices) {
        $r = Set-MsiMode -InstanceId $dev.InstanceId -FriendlyName $dev.FriendlyName -DeviceClass 'NIC'
        $results.Add($r)
    }
} else {
    Write-Host '  No physical NIC devices found.' -ForegroundColor Yellow
}

# --- Results ---
Write-Host ''
Write-Host ('=' * 60) -ForegroundColor DarkCyan
Write-Host '  Results' -ForegroundColor Cyan
Write-Host ('=' * 60) -ForegroundColor DarkCyan
Write-Host ''

foreach ($r in $results) {
    $label = "[$($r.Class)] $($r.Name)"
    Write-Result -Status $r.Status -Label $label -Detail $r.Detail
}

Write-Host ''
Write-Host '  A reboot is required for MSI mode changes to take effect.' -ForegroundColor Yellow
Write-Host '  Reboot after completing all post-install steps.' -ForegroundColor DarkGray
Set-StepStatus -Step 'MSIMode' -Status complete -Detail 'MSI mode pass finished.'
Write-SectionComplete 'Step 3 - MSI Interrupt Mode'
