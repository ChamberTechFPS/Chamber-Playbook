#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\Shared.ps1"

[void](Initialize-ChamberLog -Name 'prepare-drivers')
Assert-Admin
Set-StepStatus -Step 'PrepareDrivers' -Status running

Write-Header 'Step 1 - Prepare GPU Drivers'

$preflight = Invoke-ChamberPreflight -Quiet
$gpus    = @(Get-GpuInventory)
$vendor  = Get-GpuVendor
$gpuName = Get-GpuName

Write-Host "  GPU detected: $gpuName" -ForegroundColor White
if ($gpus.Count -gt 1 -and $vendor -ne 'Unknown') {
    Write-Host "  Preferred DDU target: $vendor" -ForegroundColor DarkGray
}

foreach ($gpu in $gpus) {
    if ($gpu.Vendor -ne 'Unknown') {
        Write-Host "    - $($gpu.Name) [$($gpu.Vendor)]" -ForegroundColor DarkGray
    } else {
        Write-Host "    - $($gpu.Name)" -ForegroundColor DarkGray
    }
}
Write-Host ''

try {
    $seenDrivers = @{}
    $drivers = foreach ($driver in (Get-CimInstance -ClassName Win32_PnPSignedDriver -Filter "DeviceClass='DISPLAY'")) {
        if ($driver.DeviceName -match 'Microsoft') { continue }

        $key = if ($driver.DeviceID) { [string]$driver.DeviceID } else { "$($driver.DeviceName)|$($driver.DriverVersion)" }
        if ($seenDrivers.ContainsKey($key)) { continue }
        $seenDrivers[$key] = $true
        $driver
    }

    foreach ($driver in ($drivers | Sort-Object DeviceName)) {
        if ($driver.DriverVersion) {
            Write-Host "  Current driver: $($driver.DeviceName) - $($driver.DriverVersion)" -ForegroundColor DarkGray
            Write-ChamberLog "Current display driver: $($driver.DeviceName) $($driver.DriverVersion)"
        }
    }
} catch {
    Write-ChamberLog "Could not query display drivers: $($_.Exception.Message)" -Level WARN
}

Write-Host ''

$toolsDir = Join-Path $PSScriptRoot '..\tools'

function Stage-DduExe {
    param([string]$Path)

    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }

    if (-not (Test-Path -LiteralPath $toolsDir)) {
        [void](New-Item -ItemType Directory -Path $toolsDir -Force)
    }

    $dest = Join-Path $toolsDir 'Display Driver Uninstaller.exe'
    if ([System.IO.Path]::GetFullPath($Path) -ne [System.IO.Path]::GetFullPath($dest)) {
        Copy-Item -Path $Path -Destination $dest -Force
    }

    return $dest
}

function Find-DduExe {
    $searchRoots = @(
        $toolsDir,
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)}
    )
    if ($env:LocalAppData) { $searchRoots += Join-Path $env:LocalAppData 'Programs' }

    foreach ($root in $searchRoots) {
        if (-not $root -or -not (Test-Path -LiteralPath $root)) { continue }
        $found = Get-ChildItem -Path $root -Filter 'Display Driver Uninstaller.exe' -Recurse -Depth 4 -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($found) { return $found.FullName }
    }
    return $null
}

$dduExe = Find-DduExe

if ($dduExe) {
    Write-Host "  DDU found: $dduExe" -ForegroundColor Green
} else {
    $winget = Get-WingetHealth
    if ($winget.Available -and $preflight.Internet) {
        Write-Host '  Installing DDU via winget...' -ForegroundColor DarkGray
        $installResult = Invoke-ChamberWingetInstall -Name 'Display Driver Uninstaller' -Id 'Wagnardsoft.DisplayDriverUninstaller'
        if ($installResult.ExitCode -eq 0) {
            Write-Host '  DDU installed.' -ForegroundColor Green
            $dduExe = Find-DduExe
        } else {
            Write-Host "  winget failed installing DDU (exit $($installResult.ExitCode))." -ForegroundColor Yellow
        }
    } else {
        Write-Host '  winget or internet is unavailable; DDU cannot be installed automatically.' -ForegroundColor Yellow
    }

    if (-not $dduExe) {
        Write-Host ''
        Write-Host '  Enter the full path to "Display Driver Uninstaller.exe",' -ForegroundColor White
        Write-Host '  or press Enter to open the download page and skip staging for now.' -ForegroundColor White
        $manualPath = (Read-Host '  Path').Trim()

        if ($manualPath -and (Test-Path -LiteralPath $manualPath)) {
            $dduExe = $manualPath
        } else {
            Start-Process 'https://www.wagnardsoft.com/display-driver-uninstaller-DDU-'
            Write-Host '  Skipping DDU setup. Re-run this step after downloading DDU.' -ForegroundColor Yellow
        }
    }
}

if ($dduExe) {
    $stagedDdu = Stage-DduExe -Path $dduExe
    if ($stagedDdu) {
        $dduExe = $stagedDdu
        Write-Host "  DDU staged to: $dduExe" -ForegroundColor Green
    }

    Ensure-StateDir
    [System.IO.File]::WriteAllText((Join-Path $script:StateDir 'ddu_path.txt'), $dduExe)
    Write-Host "  DDU path saved: $dduExe" -ForegroundColor DarkGray
    Write-ChamberLog "DDU staged path: $dduExe"
}

Write-Host ''

$seenVendors = @{}
$driverTargets = foreach ($gpu in $gpus) {
    if (-not $gpu.DriverUrl -or $seenVendors.ContainsKey($gpu.Vendor)) { continue }
    $seenVendors[$gpu.Vendor] = $true
    $gpu
}

$driverVendors = @($driverTargets | Select-Object -ExpandProperty Vendor)

if ($driverTargets) {
    Write-Host "  Opening driver page(s) for: $($driverVendors -join ', ')" -ForegroundColor DarkGray
    foreach ($target in $driverTargets) {
        Start-Process $target.DriverUrl
        Write-ChamberLog "Opened driver page: $($target.Vendor) $($target.DriverUrl)"
    }

    if ($driverVendors -contains 'NVIDIA') {
        Write-Host '  Opening NVCleanstall download page...' -ForegroundColor DarkGray
        Start-Process 'https://www.techpowerup.com/download/techpowerup-nvcleanstall/'
    }

    Write-Host ''
    Write-Host '  HOW TO DOWNLOAD YOUR DRIVER:' -ForegroundColor Yellow
    if (($driverVendors -contains 'Intel') -and (($driverVendors -contains 'NVIDIA') -or ($driverVendors -contains 'AMD'))) {
        Write-Host '  Hybrid graphics detected: download the NVIDIA/AMD driver first. Intel can be updated afterward.' -ForegroundColor DarkGray
    }
    $stepNumber = 1
    if ($driverVendors -contains 'NVIDIA') {
        Write-Host "    $stepNumber. NVIDIA: search for your GPU and download the Game Ready Driver" -ForegroundColor White
        $stepNumber++
        Write-Host "    $stepNumber. NVIDIA: optionally download NVCleanstall" -ForegroundColor White
        $stepNumber++
    }
    if ($driverVendors -contains 'AMD') {
        Write-Host "    $stepNumber. AMD: select your GPU model and download Adrenalin Edition" -ForegroundColor White
        $stepNumber++
    }
    if ($driverVendors -contains 'Intel') {
        Write-Host "    $stepNumber. Intel: use Download Center or Driver & Support Assistant" -ForegroundColor White
        $stepNumber++
    }
    Write-Host "    $stepNumber. Save each installer to your Desktop so it is easy to find later" -ForegroundColor White
    $stepNumber++
    Write-Host "    $stepNumber. Do NOT run any installer yet; DDU happens first" -ForegroundColor White
} else {
    Write-Host '  Could not detect GPU vendor. Download your GPU driver manually' -ForegroundColor Yellow
    Write-Host '  and save it to your Desktop.' -ForegroundColor Yellow
}

Write-Host ''
Write-Host '  Take your time. Press Enter here when the driver download is complete.' -ForegroundColor Cyan
Read-Host ''

$installerPath = Select-GpuDriverInstallerCandidate -Vendors $driverVendors
if ($installerPath) {
    Write-Host ''
    Write-Host "  Driver installer saved for post-DDU launch:" -ForegroundColor Green
    Write-Host "  $installerPath" -ForegroundColor White
    Write-Host '  Chamber will offer to run this after DDU completes.' -ForegroundColor DarkGray
} else {
    Write-Host ''
    Write-Host '  No driver installer was saved. Chamber will ask again after DDU.' -ForegroundColor Yellow
}

Set-StateFlag 'driver_downloaded'
Set-StepStatus -Step 'PrepareDrivers' -Status complete -Detail 'Driver pages opened and DDU staged if available.'
Write-Host '  Step 1 complete. Run Step 2 to perform the clean driver install.' -ForegroundColor Green
Write-SectionComplete 'Step 1 - Prepare GPU Drivers'
