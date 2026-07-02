Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$stateRoot = if ($env:CHAMBER_STATE_DIR) { $env:CHAMBER_STATE_DIR } else { Join-Path $env:ProgramData 'ChamberPostInstall' }

$script:StateDir   = $stateRoot
$script:LogDir     = Join-Path $script:StateDir 'logs'
$script:BackupDir  = Join-Path $script:StateDir 'backups'
$script:StateFile  = Join-Path $script:StateDir 'state.json'
$script:CurrentLog = $null

function Test-IsAdmin {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

function Assert-Admin {
    param([string]$ScriptPath)

    if (Test-IsAdmin) { return }

    if (-not $ScriptPath) {
        $caller = Get-PSCallStack | Select-Object -Skip 1 -First 1
        if ($caller -and $caller.ScriptName) {
            $ScriptPath = $caller.ScriptName
        } else {
            $ScriptPath = $PSCommandPath
        }
    }

    Write-Host 'Relaunching as administrator...' -ForegroundColor Yellow
    $psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath)
    Start-Process powershell.exe -ArgumentList $psArgs -Verb RunAs
    exit 0
}

function Ensure-StateDir {
    foreach ($path in @($script:StateDir, $script:LogDir, $script:BackupDir)) {
        if (-not (Test-Path -LiteralPath $path)) {
            [void](New-Item -ItemType Directory -Path $path -Force)
        }
    }
}

function Initialize-ChamberLog {
    param([string]$Name = 'launcher')

    Ensure-StateDir
    $safeName = $Name -replace '[^A-Za-z0-9_.-]', '_'
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $script:CurrentLog = Join-Path $script:LogDir "$stamp-$safeName.log"
    [System.IO.File]::AppendAllText($script:CurrentLog, "[$(Get-Date -Format o)] Started $Name`r`n")
    return $script:CurrentLog
}

function Write-ChamberLog {
    param(
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR','DEBUG')][string]$Level = 'INFO'
    )

    Ensure-StateDir
    if (-not $script:CurrentLog) {
        [void](Initialize-ChamberLog -Name 'shared')
    }

    $line = "[$(Get-Date -Format o)] [$Level] $Message`r`n"
    [System.IO.File]::AppendAllText($script:CurrentLog, $line)
}

function New-ChamberState {
    Ensure-StateDir
    return [pscustomobject]@{
        SchemaVersion  = 1
        CreatedAt      = (Get-Date).ToString('o')
        UpdatedAt      = (Get-Date).ToString('o')
        Steps          = [pscustomobject]@{}
        Flags          = [pscustomobject]@{}
        Hardware       = [pscustomobject]@{}
        Pending        = [pscustomobject]@{}
        LastFailure    = $null
        WingetFailures = @()
    }
}

function Add-ObjectPropertyIfMissing {
    param(
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][string]$Name,
        $Value
    )

    if (-not $Object.PSObject.Properties[$Name]) {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
}

function Get-ChamberState {
    Ensure-StateDir

    if (Test-Path -LiteralPath $script:StateFile) {
        try {
            $state = Get-Content -LiteralPath $script:StateFile -Raw | ConvertFrom-Json
        } catch {
            $corrupt = Join-Path $script:BackupDir ("state-corrupt-{0}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
            Move-Item -LiteralPath $script:StateFile -Destination $corrupt -Force
            $state = New-ChamberState
        }
    } else {
        $state = New-ChamberState
    }

    Add-ObjectPropertyIfMissing -Object $state -Name 'Steps' -Value ([pscustomobject]@{})
    Add-ObjectPropertyIfMissing -Object $state -Name 'Flags' -Value ([pscustomobject]@{})
    Add-ObjectPropertyIfMissing -Object $state -Name 'Hardware' -Value ([pscustomobject]@{})
    Add-ObjectPropertyIfMissing -Object $state -Name 'Pending' -Value ([pscustomobject]@{})
    Add-ObjectPropertyIfMissing -Object $state -Name 'WingetFailures' -Value @()
    Add-ObjectPropertyIfMissing -Object $state -Name 'LastFailure' -Value $null

    return $state
}

function Save-ChamberState {
    param([Parameter(Mandatory)]$State)

    Ensure-StateDir
    $State.UpdatedAt = (Get-Date).ToString('o')
    $json = $State | ConvertTo-Json -Depth 12
    [System.IO.File]::WriteAllText($script:StateFile, $json, [System.Text.Encoding]::UTF8)
}

function Set-StateObjectProperty {
    param(
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][string]$Name,
        $Value
    )

    if ($Object.PSObject.Properties[$Name]) {
        $Object.$Name = $Value
    } else {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
}

function Set-StateFlag {
    param([string]$Name)

    Ensure-StateDir
    $stamp = (Get-Date).ToString('o')
    [System.IO.File]::WriteAllText((Join-Path $script:StateDir "$Name.flag"), $stamp)

    $state = Get-ChamberState
    Set-StateObjectProperty -Object $state.Flags -Name $Name -Value $stamp
    Save-ChamberState -State $state
    Write-ChamberLog "Set flag: $Name"
}

function Clear-StateFlag {
    param([string]$Name)

    $flagPath = Join-Path $script:StateDir "$Name.flag"
    if (Test-Path -LiteralPath $flagPath) {
        Remove-Item -LiteralPath $flagPath -Force
    }

    $state = Get-ChamberState
    if ($state.Flags.PSObject.Properties[$Name]) {
        $state.Flags.PSObject.Properties.Remove($Name)
        Save-ChamberState -State $state
    }
    Write-ChamberLog "Cleared flag: $Name"
}

function Test-StateFlag {
    param([string]$Name)

    $flagPath = Join-Path $script:StateDir "$Name.flag"
    if (Test-Path -LiteralPath $flagPath) {
        $state = Get-ChamberState
        if (-not $state.Flags.PSObject.Properties[$Name]) {
            $stamp = [System.IO.File]::ReadAllText($flagPath).Trim()
            if (-not $stamp) { $stamp = (Get-Date).ToString('o') }
            Set-StateObjectProperty -Object $state.Flags -Name $Name -Value $stamp
            Save-ChamberState -State $state
        }
        return $true
    }
    $state = Get-ChamberState
    return $null -ne $state.Flags.PSObject.Properties[$Name]
}

function Set-StepStatus {
    param(
        [Parameter(Mandatory)][string]$Step,
        [Parameter(Mandatory)][ValidateSet('pending','running','complete','failed','skipped')][string]$Status,
        [string]$Detail = ''
    )

    $state = Get-ChamberState
    $entry = [pscustomobject]@{
        Status    = $Status
        Detail    = $Detail
        UpdatedAt = (Get-Date).ToString('o')
    }
    Set-StateObjectProperty -Object $state.Steps -Name $Step -Value $entry
    Save-ChamberState -State $state
    Write-ChamberLog "Step $Step -> $Status $Detail"
}

function Set-LastFailure {
    param(
        [string]$Step,
        [string]$Message
    )

    $state = Get-ChamberState
    $state.LastFailure = [pscustomobject]@{
        Step      = $Step
        Message   = $Message
        Timestamp = (Get-Date).ToString('o')
    }
    Save-ChamberState -State $state
    Write-ChamberLog "Failure in $Step`: $Message" -Level ERROR
}

function Get-GpuVendorPriority {
    param([string]$Vendor)

    switch ($Vendor) {
        'NVIDIA' { return 1 }
        'AMD'    { return 2 }
        'Intel'  { return 3 }
        default  { return 99 }
    }
}

function Get-GpuVendorFromText {
    param([string]$Text)

    if (-not $Text) { return 'Unknown' }
    if ($Text -match 'NVIDIA') { return 'NVIDIA' }
    if ($Text -match 'AMD|Radeon|Advanced Micro') { return 'AMD' }
    if ($Text -match 'Intel|Arc|Iris|UHD|HD Graphics') { return 'Intel' }
    return 'Unknown'
}

function Get-GpuDriverUrl {
    param([string]$Vendor)

    switch ($Vendor) {
        'NVIDIA' { return 'https://www.nvidia.com/Download/index.aspx' }
        'AMD'    { return 'https://www.amd.com/en/support' }
        'Intel'  { return 'https://www.intel.com/content/www/us/en/download-center/home.html' }
        default  { return $null }
    }
}

function Get-GpuInventory {
    try {
        $seen = @{}
        $inventory = foreach ($gpu in (Get-CimInstance -ClassName Win32_VideoController)) {
            $name = [string]$gpu.Name
            $compatibility = [string]$gpu.AdapterCompatibility

            if ($name -match 'Microsoft Basic|Remote Display' -or $compatibility -match 'Microsoft') {
                continue
            }

            $key = if ($gpu.PNPDeviceID) { [string]$gpu.PNPDeviceID } else { "$name|$compatibility" }
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true

            $vendor = Get-GpuVendorFromText "$name $compatibility"

            [pscustomobject]@{
                Name      = if ($name) { $name } else { 'Unknown GPU' }
                Vendor    = $vendor
                DriverUrl = Get-GpuDriverUrl -Vendor $vendor
                Priority  = Get-GpuVendorPriority -Vendor $vendor
            }
        }

        return @($inventory | Sort-Object Priority, Name)
    } catch {
        Write-ChamberLog "GPU inventory failed: $($_.Exception.Message)" -Level WARN
        return @()
    }
}

function Get-GpuVendor {
    $gpu = Get-GpuInventory | Where-Object { $_.Vendor -ne 'Unknown' } | Select-Object -First 1
    if ($gpu) { return $gpu.Vendor }
    return 'Unknown'
}

function Get-GpuName {
    $gpus = Get-GpuInventory
    if (-not $gpus) { return 'Unknown GPU' }

    $names = @($gpus | Select-Object -ExpandProperty Name -Unique)
    if (-not $names) { return 'Unknown GPU' }

    return ($names -join ' + ')
}

function Set-PendingValue {
    param(
        [Parameter(Mandatory)][string]$Name,
        $Value
    )

    $state = Get-ChamberState
    Set-StateObjectProperty -Object $state.Pending -Name $Name -Value $Value
    Save-ChamberState -State $state
}

function Get-PendingValue {
    param([Parameter(Mandatory)][string]$Name)

    $state = Get-ChamberState
    $prop = $state.Pending.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $null
}

function Clear-PendingValue {
    param([Parameter(Mandatory)][string]$Name)

    $state = Get-ChamberState
    if ($state.Pending.PSObject.Properties[$Name]) {
        $state.Pending.PSObject.Properties.Remove($Name)
        Save-ChamberState -State $state
    }
}

function Get-CommonInstallerSearchRoots {
    $roots = [System.Collections.Generic.List[string]]::new()

    foreach ($path in @(
        (Join-Path $env:USERPROFILE 'Downloads'),
        (Join-Path $env:USERPROFILE 'Desktop'),
        (Join-Path $env:PUBLIC 'Desktop')
    )) {
        if ($path -and (Test-Path -LiteralPath $path)) {
            $roots.Add([System.IO.Path]::GetFullPath($path))
        }
    }

    foreach ($envName in @('OneDrive', 'OneDriveConsumer', 'OneDriveCommercial')) {
        $base = [Environment]::GetEnvironmentVariable($envName)
        if (-not $base) { continue }
        foreach ($child in @('Desktop', 'Downloads')) {
            $path = Join-Path $base $child
            if (Test-Path -LiteralPath $path) {
                $full = [System.IO.Path]::GetFullPath($path)
                if (-not $roots.Contains($full)) { $roots.Add($full) }
            }
        }
    }

    return @($roots)
}

function Get-GpuDriverInstallerScore {
    param(
        [Parameter(Mandatory)][System.IO.FileInfo]$File,
        [string[]]$Vendors
    )

    $name = $File.Name
    $score = 0
    $matchedVendor = 'Unknown'

    if ($Vendors -contains 'NVIDIA') {
        if ($name -match '(?i)nvidia|geforce|studio|game.?ready') { $score += 70; $matchedVendor = 'NVIDIA' }
        if ($name -match '(?i)(desktop|notebook)-win(10|11|10-11|11-10).*(dch|whql)') { $score += 90; $matchedVendor = 'NVIDIA' }
        if ($name -match '(?i)nvcleanstall') { $score += 50; $matchedVendor = 'NVIDIA' }
    }

    if ($Vendors -contains 'AMD') {
        if ($name -match '(?i)amd.*(software|adrenalin|radeon)|radeon|adrenalin') { $score += 90; $matchedVendor = 'AMD' }
    }

    if ($Vendors -contains 'Intel') {
        if ($name -match '(?i)intel.*(graphics|arc|driver|support)|igfx|gfx_win|driver.*support.*assistant|dsasetup') { $score += 85; $matchedVendor = 'Intel' }
    }

    if ($name -match '(?i)driver') { $score += 10 }
    if ($name -match '(?i)chipset|audio|bluetooth|wifi|wireless|lan|ethernet|realtek|killer') { $score -= 60 }
    if ($name -match '(?i)display|graphics|gpu|vga') { $score += 20 }
    if ($File.LastWriteTime -gt (Get-Date).AddDays(-3)) { $score += 15 }
    elseif ($File.LastWriteTime -gt (Get-Date).AddDays(-14)) { $score += 8 }

    return [pscustomobject]@{
        Score        = $score
        MatchedVendor = $matchedVendor
    }
}

function Find-GpuDriverInstallerCandidates {
    param([string[]]$Vendors)

    if (-not $Vendors -or $Vendors.Count -eq 0) {
        $Vendors = @(Get-GpuInventory | Where-Object { $_.Vendor -ne 'Unknown' } | Select-Object -ExpandProperty Vendor -Unique)
    }
    if (-not $Vendors -or $Vendors.Count -eq 0) { return @() }

    $candidates = [System.Collections.Generic.List[object]]::new()
    $seen = @{}

    foreach ($root in (Get-CommonInstallerSearchRoots)) {
        try {
            $files = @(Get-ChildItem -LiteralPath $root -Filter '*.exe' -File -Recurse -Depth 2 -ErrorAction SilentlyContinue)
        } catch {
            Write-ChamberLog "Installer search skipped $root`: $($_.Exception.Message)" -Level WARN
            continue
        }

        foreach ($file in $files) {
            $fullPath = [System.IO.Path]::GetFullPath($file.FullName)
            if ($seen.ContainsKey($fullPath)) { continue }
            $seen[$fullPath] = $true

            $match = Get-GpuDriverInstallerScore -File $file -Vendors $Vendors
            if ($match.Score -lt 50) { continue }

            $candidates.Add([pscustomobject]@{
                Path          = $file.FullName
                Name          = $file.Name
                Directory     = $file.DirectoryName
                LastWriteTime = $file.LastWriteTime
                LengthMB      = [math]::Round($file.Length / 1MB, 1)
                Score         = $match.Score
                Vendor        = $match.MatchedVendor
            })
        }
    }

    return @($candidates | Sort-Object Score, LastWriteTime -Descending)
}

function Set-PendingGpuDriverInstaller {
    param([Parameter(Mandatory)][string]$Path)

    $file = Get-Item -LiteralPath $Path -ErrorAction Stop
    $value = [pscustomobject]@{
        Path          = $file.FullName
        Name          = $file.Name
        LastWriteTime = $file.LastWriteTime.ToString('o')
        LengthMB      = [math]::Round($file.Length / 1MB, 1)
        SavedAt       = (Get-Date).ToString('o')
    }
    Set-PendingValue -Name 'GpuDriverInstaller' -Value $value
    Write-ChamberLog "Saved GPU driver installer candidate: $($file.FullName)"
}

function Get-PendingGpuDriverInstaller {
    $pending = Get-PendingValue -Name 'GpuDriverInstaller'
    if (-not $pending -or -not $pending.Path) { return $null }
    if (-not (Test-Path -LiteralPath $pending.Path)) {
        Write-ChamberLog "Saved GPU driver installer missing: $($pending.Path)" -Level WARN
        return $null
    }

    return $pending
}

function Select-GpuDriverInstallerCandidate {
    param([string[]]$Vendors)

    $saved = Get-PendingGpuDriverInstaller
    if ($saved) {
        Write-Host "  Saved GPU driver installer: $($saved.Path)" -ForegroundColor Green
        return $saved.Path
    }

    $candidates = @(Find-GpuDriverInstallerCandidates -Vendors $Vendors | Select-Object -First 5)
    if ($candidates.Count -gt 0) {
        Write-Host '  Found likely GPU driver installer(s):' -ForegroundColor Cyan
        for ($i = 0; $i -lt $candidates.Count; $i++) {
            $item = $candidates[$i]
            Write-Host ("    [{0}] {1} ({2} MB, {3}, {4})" -f ($i + 1), $item.Name, $item.LengthMB, $item.Vendor, $item.LastWriteTime) -ForegroundColor White
            Write-Host "        $($item.Path)" -ForegroundColor DarkGray
        }
        Write-Host ''
        Write-Host '  Press Enter to use the first match, choose a number, paste a path, or type S to skip.' -ForegroundColor DarkGray
        $choice = (Read-Host '  Driver installer').Trim()

        if (-not $choice) {
            Set-PendingGpuDriverInstaller -Path $candidates[0].Path
            return $candidates[0].Path
        }
        if ($choice -match '^[Ss]$') { return $null }

        [int]$index = 0
        if ([int]::TryParse($choice, [ref]$index) -and $index -ge 1 -and $index -le $candidates.Count) {
            Set-PendingGpuDriverInstaller -Path $candidates[$index - 1].Path
            return $candidates[$index - 1].Path
        }

        if (Test-Path -LiteralPath $choice) {
            Set-PendingGpuDriverInstaller -Path $choice
            return $choice
        }

        Write-Host "  File not found: $choice" -ForegroundColor Yellow
        return $null
    }

    Write-Host '  No likely GPU driver installer was found in Downloads or Desktop.' -ForegroundColor Yellow
    Write-Host '  Paste the full path to the installer, or press Enter to skip for now.' -ForegroundColor DarkGray
    $manualPath = (Read-Host '  Driver installer path').Trim()
    if ($manualPath -and (Test-Path -LiteralPath $manualPath)) {
        Set-PendingGpuDriverInstaller -Path $manualPath
        return $manualPath
    }

    return $null
}

function Invoke-PendingGpuDriverInstaller {
    param([switch]$AllowPrompt)

    $pending = Get-PendingGpuDriverInstaller
    $installerPath = if ($pending) { $pending.Path } else { $null }

    if (-not $installerPath -and $AllowPrompt) {
        $vendors = @(Get-GpuInventory | Where-Object { $_.Vendor -ne 'Unknown' } | Select-Object -ExpandProperty Vendor -Unique)
        $installerPath = Select-GpuDriverInstallerCandidate -Vendors $vendors
    }

    if (-not $installerPath) {
        Write-Host '  No GPU driver installer is staged yet.' -ForegroundColor Yellow
        return $false
    }

    Write-Host ''
    Write-Host '  Chamber can launch the downloaded GPU driver installer now.' -ForegroundColor Cyan
    Write-Host "  Installer: $installerPath" -ForegroundColor White
    Write-Host '  Review the vendor installer UI. Use a clean/minimal install option if offered.' -ForegroundColor DarkGray
    Write-Host ''

    if (-not (Confirm-Continue '  Launch this GPU driver installer?')) {
        Write-Host '  Driver install skipped for now.' -ForegroundColor Yellow
        return $false
    }

    try {
        Write-ChamberLog "Launching GPU driver installer: $installerPath"
        $process = Start-Process -FilePath $installerPath -Wait -PassThru -ErrorAction Stop
        $exitCode = $process.ExitCode
        Write-ChamberLog "GPU driver installer exited with code $exitCode"

        if ($exitCode -eq 0 -or $exitCode -eq 3010 -or $exitCode -eq 1641) {
            Set-StateFlag 'driver_installed'
            Clear-PendingValue -Name 'GpuDriverInstaller'
            Set-StepStatus -Step 'GpuDriverInstall' -Status complete -Detail "Installer exit code $exitCode."
            Write-Host '  GPU driver installer finished.' -ForegroundColor Green
            if ($exitCode -eq 3010 -or $exitCode -eq 1641) {
                Write-Host '  The installer requested a reboot. Finish Chamber steps first unless the installer already restarted Windows.' -ForegroundColor Yellow
            }
            return $true
        }

        Write-Host "  Installer exited with code $exitCode." -ForegroundColor Yellow
        if (Confirm-Continue '  Mark the GPU driver as installed anyway?') {
            Set-StateFlag 'driver_installed'
            Clear-PendingValue -Name 'GpuDriverInstaller'
            Set-StepStatus -Step 'GpuDriverInstall' -Status complete -Detail "User accepted installer exit code $exitCode."
            return $true
        }

        Set-StepStatus -Step 'GpuDriverInstall' -Status failed -Detail "Installer exit code $exitCode."
        return $false
    } catch {
        Set-StepStatus -Step 'GpuDriverInstall' -Status failed -Detail $_.Exception.Message
        Set-LastFailure -Step 'GpuDriverInstall' -Message $_.Exception.Message
        Write-Host "  Failed to launch installer: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

function Get-PhysicalNicInventory {
    try {
        return @(Get-PnpDevice -Class Net -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Status -eq 'OK' -and
                $_.FriendlyName -notmatch 'Virtual|WAN|Loopback|Bluetooth|Wi-Fi Direct|Miniport|VPN|TAP|Kernel Debug'
            } |
            ForEach-Object {
                [pscustomobject]@{
                    Name       = $_.FriendlyName
                    InstanceId = $_.InstanceId
                    VendorId   = if ($_.InstanceId -match 'VEN_([0-9A-Fa-f]{4})') { $Matches[1].ToUpper() } else { $null }
                }
            })
    } catch {
        Write-ChamberLog "NIC inventory failed: $($_.Exception.Message)" -Level WARN
        return @()
    }
}

function Write-Header {
    param([string]$Title)
    Clear-Host
    Write-Host ('=' * 60) -ForegroundColor DarkCyan
    Write-Host '  Chamber - Post-Install Setup' -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor White
    Write-Host ('=' * 60) -ForegroundColor DarkCyan
    Write-Host ''
}

function Confirm-Continue {
    param([string]$Message)
    Write-Host $Message -ForegroundColor Yellow -NoNewline
    Write-Host ' [Y/N]: ' -NoNewline
    $key = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    Write-Host $key.Character
    return $key.Character -match '^[Yy]$'
}

function Write-Result {
    param(
        [ValidateSet('PASS','FAIL','WARN','INFO','DISABLED')][string]$Status,
        [string]$Label,
        [string]$Detail = ''
    )
    $colors = @{ PASS = 'Green'; FAIL = 'Red'; WARN = 'Yellow'; INFO = 'Cyan'; DISABLED = 'DarkGray' }
    $pad = 22
    $labelPad = if ($Label.Length -gt $pad) { $Label } else { $Label.PadRight($pad) }
    Write-Host "  $labelPad" -NoNewline
    Write-Host "[$Status]" -ForegroundColor $colors[$Status] -NoNewline
    if ($Detail) {
        Write-Host "  $Detail"
    } else {
        Write-Host ''
    }
    Write-ChamberLog "$Status $Label $Detail"
}

function Wait-AnyKey {
    param([string]$Message = '  Press any key to continue...')
    Write-Host $Message -ForegroundColor DarkGray
    [void]$Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    Write-Host ''
}

function Write-SectionComplete {
    param([string]$SectionName)
    Write-Host ''
    Write-Host ('  ' + ('=' * 58)) -ForegroundColor Green
    Write-Host "    All done: $SectionName" -ForegroundColor Green
    Write-Host ('  ' + ('=' * 58)) -ForegroundColor Green
    Write-Host ''
    Wait-AnyKey '  Press any key to return to the menu...'
}

function Test-InternetConnection {
    try {
        return [bool](Test-Connection -ComputerName '8.8.8.8' -Count 1 -Quiet -ErrorAction SilentlyContinue)
    } catch {
        return $false
    }
}

function Resolve-WingetCommand {
    $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $windowsApps = Join-Path $env:ProgramFiles 'WindowsApps'
    if (Test-Path -LiteralPath $windowsApps) {
        $found = Get-ChildItem -Path $windowsApps -Filter winget.exe -Recurse -Depth 3 -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($found) { return $found.FullName }
    }

    return $null
}

function Get-WingetHealth {
    $wingetPath = Resolve-WingetCommand
    $appInstaller = Get-AppxPackage -Name 'Microsoft.DesktopAppInstaller' -ErrorAction SilentlyContinue

    $version = $null
    if ($wingetPath) {
        try {
            $versionOutput = & $wingetPath --version 2>&1
            if ($LASTEXITCODE -eq 0) { $version = ($versionOutput | Select-Object -First 1) }
        } catch {
            Write-ChamberLog "winget version check failed: $($_.Exception.Message)" -Level WARN
        }
    }

    return [pscustomobject]@{
        Available           = [bool]$wingetPath
        Path                = $wingetPath
        Version             = $version
        AppInstallerPresent = [bool]$appInstaller
        AppInstallerVersion = if ($appInstaller) { [string]$appInstaller.Version } else { $null }
    }
}

function Test-PendingReboot {
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired',
        'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
    )

    if (Test-Path -LiteralPath $paths[0]) { return $true }
    if (Test-Path -LiteralPath $paths[1]) { return $true }

    try {
        $pendingRename = (Get-ItemProperty -LiteralPath $paths[2] -Name 'PendingFileRenameOperations' -ErrorAction SilentlyContinue).PendingFileRenameOperations
        if ($pendingRename) { return $true }
    } catch { }

    return $false
}

function Test-SystemRestoreAvailable {
    if (-not (Get-Command Checkpoint-Computer -ErrorAction SilentlyContinue)) { return $false }
    try {
        $svc = Get-Service -Name 'VSS' -ErrorAction SilentlyContinue
        return $null -ne $svc
    } catch {
        return $false
    }
}

function New-ChamberRestorePoint {
    param([string]$Description = 'Chamber Post-Install')

    if (-not (Test-SystemRestoreAvailable)) {
        Write-ChamberLog 'System Restore is not available.' -Level WARN
        return $false
    }

    try {
        Checkpoint-Computer -Description $Description -RestorePointType MODIFY_SETTINGS
        Write-ChamberLog "Created restore point: $Description"
        return $true
    } catch {
        Write-ChamberLog "Restore point skipped/failed: $($_.Exception.Message)" -Level WARN
        return $false
    }
}

function Backup-ChamberRegistry {
    param([string]$Label = 'pre-change')

    Ensure-StateDir
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $safeLabel = $Label -replace '[^A-Za-z0-9_.-]', '_'
    $keys = @(
        'HKLM\SOFTWARE\Policies\Microsoft\Windows Defender',
        'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate',
        'HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard',
        'HKLM\SYSTEM\CurrentControlSet\Control\CI',
        'HKCU\System\GameConfigStore',
        'HKCU\SOFTWARE\Microsoft\GameBar',
        'HKLM\SOFTWARE\Policies\Microsoft\Windows\GameDVR',
        'HKCU\Control Panel\Mouse',
        'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\CompatTelRunner.exe',
        'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\AggregatorHost.exe',
        'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\DeviceCensus.exe'
    )

    function Convert-ChamberRegistryPath {
        param([Parameter(Mandatory)][string]$Path)

        if ($Path -match '^HKLM\\(.+)$') { return "HKLM:\$($Matches[1])" }
        if ($Path -match '^HKCU\\(.+)$') { return "HKCU:\$($Matches[1])" }
        if ($Path -match '^HKCR\\(.+)$') { return "HKCR:\$($Matches[1])" }
        if ($Path -match '^HKU\\(.+)$')  { return "Registry::HKEY_USERS\$($Matches[1])" }
        return $null
    }

    foreach ($key in $keys) {
        $providerPath = Convert-ChamberRegistryPath -Path $key
        if ($providerPath -and -not (Test-Path -LiteralPath $providerPath)) {
            Write-ChamberLog "Registry backup skipped: $key (key not present)" -Level WARN
            continue
        }

        $fileSafeKey = $key -replace '[\\: ]', '_'
        $dest = Join-Path $script:BackupDir "$stamp-$safeLabel-$fileSafeKey.reg"

        $previousErrorActionPreference = $ErrorActionPreference
        $output = $null
        $exitCode = 1
        try {
            $ErrorActionPreference = 'Continue'
            $output = & reg.exe export $key $dest /y 2>&1
            $exitCode = $LASTEXITCODE
        } catch {
            $output = $_.Exception.Message
            $exitCode = 1
        } finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }

        if ($exitCode -eq 0) {
            Write-ChamberLog "Registry backup exported: $key"
        } else {
            Write-ChamberLog "Registry backup skipped: $key ($output)" -Level WARN
        }
    }

    Backup-ChamberHostsFile -Label $safeLabel | Out-Null
}

function Backup-ChamberHostsFile {
    param([string]$Label = 'pre-change')

    Ensure-StateDir
    $hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    if (-not (Test-Path -LiteralPath $hostsPath)) { return $null }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $safeLabel = $Label -replace '[^A-Za-z0-9_.-]', '_'
    $dest = Join-Path $script:BackupDir "$stamp-$safeLabel-hosts"
    Copy-Item -LiteralPath $hostsPath -Destination $dest -Force
    Write-ChamberLog "Hosts backup exported: $dest"
    return $dest
}

function Invoke-ChamberPreflight {
    param([switch]$Quiet)

    Ensure-StateDir
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    } catch {
        Write-ChamberLog "OS inventory failed: $($_.Exception.Message)" -Level WARN
        $os = [pscustomobject]@{
            Caption     = 'Unknown Windows'
            BuildNumber = 'Unknown'
            Version     = 'Unknown'
        }
    }
    $gpuInventory = @(Get-GpuInventory)
    $nicInventory = @(Get-PhysicalNicInventory)
    $winget = Get-WingetHealth
    $internet = Test-InternetConnection
    $pendingReboot = Test-PendingReboot
    $restoreAvailable = Test-SystemRestoreAvailable
    $dduPath = Join-Path (Join-Path $PSScriptRoot '..\tools') 'Display Driver Uninstaller.exe'
    $pendingGpuInstaller = Get-PendingGpuDriverInstaller

    $summary = [pscustomobject]@{
        ComputerName           = $env:COMPUTERNAME
        OSCaption              = $os.Caption
        OSBuild                = $os.BuildNumber
        OSVersion              = $os.Version
        PendingReboot          = $pendingReboot
        Internet               = $internet
        WingetAvailable        = $winget.Available
        WingetVersion          = $winget.Version
        AppInstallerPresent    = $winget.AppInstallerPresent
        SystemRestoreAvailable = $restoreAvailable
        DduStaged              = (Test-Path -LiteralPath $dduPath)
        GpuDriverInstaller     = if ($pendingGpuInstaller) { $pendingGpuInstaller.Path } else { $null }
        GPUs                   = @($gpuInventory | Select-Object Name, Vendor)
        NICs                   = @($nicInventory | Select-Object Name, VendorId)
    }

    $state = Get-ChamberState
    $state.Hardware = $summary
    Save-ChamberState -State $state

    if (-not $Quiet) {
        Write-Result -Status INFO -Label 'OS Build' -Detail "$($summary.OSCaption) build $($summary.OSBuild)"
        Write-Result -Status ($(if ($pendingReboot) { 'WARN' } else { 'PASS' })) -Label 'Pending reboot' -Detail ($(if ($pendingReboot) { 'Detected' } else { 'None detected' }))
        Write-Result -Status ($(if ($internet) { 'PASS' } else { 'WARN' })) -Label 'Internet' -Detail ($(if ($internet) { 'Available' } else { 'Not detected' }))
        Write-Result -Status ($(if ($winget.Available) { 'PASS' } else { 'WARN' })) -Label 'winget' -Detail ($(if ($winget.Available) { "$($winget.Version)" } else { 'Missing or not registered' }))
        Write-Result -Status ($(if ($restoreAvailable) { 'PASS' } else { 'WARN' })) -Label 'System Restore' -Detail ($(if ($restoreAvailable) { 'Available' } else { 'Unavailable or disabled' }))
        Write-Result -Status ($(if ($summary.DduStaged) { 'PASS' } else { 'INFO' })) -Label 'DDU staged' -Detail ($(if ($summary.DduStaged) { 'Found in tools' } else { 'Will locate or install in driver step' }))
        Write-Result -Status ($(if ($pendingGpuInstaller) { 'PASS' } else { 'INFO' })) -Label 'GPU installer' -Detail ($(if ($pendingGpuInstaller) { $pendingGpuInstaller.Name } else { 'Not saved yet' }))
    }

    Write-ChamberLog "Preflight: $($summary | ConvertTo-Json -Depth 8 -Compress)"
    return $summary
}

function Invoke-ChamberWingetInstall {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Id,
        [string]$ExtraArgs = ''
    )

    $winget = Resolve-WingetCommand
    if (-not $winget) {
        throw 'winget was not found. Open Microsoft Store and update App Installer, then retry.'
    }

    $args = @(
        'install', '-e', '--id', $Id,
        '--source', 'winget',
        '--silent',
        '--accept-package-agreements',
        '--accept-source-agreements',
        '--disable-interactivity'
    )

    if ($ExtraArgs) {
        $args += ($ExtraArgs -split ' ' | Where-Object { $_ })
    }

    Write-ChamberLog "winget install $Id ($Name)"
    $output = & $winget @args 2>&1
    $exitCode = $LASTEXITCODE
    $output | ForEach-Object { Write-ChamberLog "winget[$Id] $_" }

    if ($exitCode -ne 0) {
        $state = Get-ChamberState
        $failures = @($state.WingetFailures)
        $failures += [pscustomobject]@{
            Name      = $Name
            Id        = $Id
            ExitCode  = $exitCode
            Timestamp = (Get-Date).ToString('o')
        }
        $state.WingetFailures = $failures
        Save-ChamberState -State $state
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output   = $output
    }
}

function Export-ChamberDiagnostics {
    Ensure-StateDir
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $exportRoot = Join-Path $script:StateDir "diagnostics-$stamp"
    $zipPath = Join-Path $script:StateDir "Chamber-Diagnostics-$stamp.zip"
    [void](New-Item -ItemType Directory -Path $exportRoot -Force)

    if (Test-Path -LiteralPath $script:StateFile) {
        Copy-Item -LiteralPath $script:StateFile -Destination (Join-Path $exportRoot 'state.json') -Force
    }
    if (Test-Path -LiteralPath $script:LogDir) {
        Copy-Item -Path (Join-Path $script:LogDir '*') -Destination $exportRoot -Force -ErrorAction SilentlyContinue
    }

    $systemText = Join-Path $exportRoot 'system-summary.txt'
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("Chamber diagnostics exported: $(Get-Date -Format o)")
    $lines.Add("Computer: $env:COMPUTERNAME")
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem
        $lines.Add("OS: $($os.Caption) $($os.Version) build $($os.BuildNumber)")
    } catch { }
    $lines.Add("Admin: $(Test-IsAdmin)")
    $lines.Add("Internet: $(Test-InternetConnection)")
    $winget = Get-WingetHealth
    $lines.Add("winget available: $($winget.Available)")
    $lines.Add("winget path: $($winget.Path)")
    $lines.Add("winget version: $($winget.Version)")
    $lines.Add("App Installer present: $($winget.AppInstallerPresent)")
    $lines.Add("GPU: $(Get-GpuName)")
    $gpuInstaller = Get-PendingGpuDriverInstaller
    $lines.Add("GPU driver installer: $(if ($gpuInstaller) { $gpuInstaller.Path } else { 'not saved' })")
    [System.IO.File]::WriteAllLines($systemText, $lines, [System.Text.Encoding]::UTF8)

    if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
    Compress-Archive -Path (Join-Path $exportRoot '*') -DestinationPath $zipPath -Force
    Remove-Item -LiteralPath $exportRoot -Recurse -Force
    Write-ChamberLog "Diagnostics exported: $zipPath"
    return $zipPath
}
