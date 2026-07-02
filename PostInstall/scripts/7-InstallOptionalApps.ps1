#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\Shared.ps1"

[void](Initialize-ChamberLog -Name 'optional-apps')
Assert-Admin
Set-StepStatus -Step 'OptionalApps' -Status running

$Categories = [ordered]@{
    '1' = [pscustomobject]@{
        Name     = 'Monitoring Tools'
        PackName = 'monitoring-tools'
        Packages = @(
            [pscustomobject]@{ Key = '1'; Name = 'HWiNFO64'; Id = 'REALiX.HWiNFO' },
            [pscustomobject]@{ Key = '2'; Name = 'AIDA64 Extreme'; Id = 'FinalWire.AIDA64.Extreme' },
            [pscustomobject]@{ Key = '3'; Name = 'CapFrameX'; Id = 'CXWorld.CapFrameX' }
        )
    }
    '2' = [pscustomobject]@{
        Name     = 'Benchmark / Overclocking Tools'
        PackName = 'benchmark-overclocking-tools'
        Packages = @(
            [pscustomobject]@{ Key = '1'; Name = 'OCCT'; Id = 'OCBase.OCCT.Personal' },
            [pscustomobject]@{ Key = '2'; Name = 'MSI Afterburner + RivaTuner'; Id = 'Guru3D.Afterburner' }
        )
    }
    '3' = [pscustomobject]@{
        Name     = 'Game Launchers'
        PackName = 'game-launchers'
        Packages = @(
            [pscustomobject]@{ Key = '1'; Name = 'Steam'; Id = 'Valve.Steam' },
            [pscustomobject]@{ Key = '2'; Name = 'Epic Games Launcher'; Id = 'EpicGames.EpicGamesLauncher' },
            [pscustomobject]@{ Key = '3'; Name = 'Battle.net'; Id = 'Blizzard.BattleNet' },
            [pscustomobject]@{ Key = '4'; Name = 'GOG Galaxy'; Id = 'GOG.Galaxy' },
            [pscustomobject]@{ Key = '5'; Name = 'Ubisoft Connect'; Id = 'Ubisoft.Connect' },
            [pscustomobject]@{ Key = '6'; Name = 'EA App'; Id = 'ElectronicArts.EADesktop' }
        )
    }
}

function Test-WingetAvailable {
    $health = Get-WingetHealth
    if ($health.Available) { return $true }

    Write-Host ''
    Write-Host '  winget was not found. Optional app installs require Windows Package Manager.' -ForegroundColor Yellow
    if ($health.AppInstallerPresent) {
        Write-Host '  Use Repair / Revert Common Uses to re-register App Installer, then retry.' -ForegroundColor DarkGray
    } else {
        Write-Host '  Open Microsoft Store and update App Installer, then retry.' -ForegroundColor DarkGray
    }
    Write-Host ''
    Wait-AnyKey
    Set-StepStatus -Step 'OptionalApps' -Status skipped -Detail 'winget unavailable.'
    return $false
}

function New-WingetCategoryPack {
    param([pscustomobject]$Category)

    Ensure-StateDir
    $packDir = Join-Path $script:StateDir 'winget-packs'
    if (-not (Test-Path -LiteralPath $packDir)) {
        [void](New-Item -ItemType Directory -Path $packDir -Force)
    }

    $packPath = Join-Path $packDir "$($Category.PackName).json"
    $pack = [ordered]@{
        Sources = @(
            [ordered]@{
                Packages = @($Category.Packages | ForEach-Object {
                    [ordered]@{ PackageIdentifier = $_.Id }
                })
                SourceDetails = [ordered]@{
                    Argument = 'https://cdn.winget.microsoft.com/cache'
                    Identifier = 'Microsoft.Winget.Source_8wekyb3d8bbwe'
                    Name = 'winget'
                    Type = 'Microsoft.PreIndexed.Package'
                }
            }
        )
    }
    $pack | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $packPath -Encoding UTF8
    Write-ChamberLog "Wrote winget pack: $packPath"
    return $packPath
}

function Install-WingetPackage {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Id
    )

    Write-Host ''
    Write-Host "  Installing $Name..." -ForegroundColor Cyan
    Write-Host "  winget package: $Id" -ForegroundColor DarkGray
    Write-Host ''

    $result = Invoke-ChamberWingetInstall -Name $Name -Id $Id

    Write-Host ''
    if ($result.ExitCode -eq 0) {
        Write-Host "  Installed: $Name" -ForegroundColor Green
    } else {
        Write-Host "  Install failed: $Name (winget exit $($result.ExitCode))" -ForegroundColor Yellow
    }
}

function Invoke-PackageMenu {
    param([pscustomobject]$Category)

    $packPath = New-WingetCategoryPack -Category $Category

    while ($true) {
        Write-Header $Category.Name

        foreach ($package in $Category.Packages) {
            Write-Host "  [$($package.Key)]  $($package.Name)" -ForegroundColor White
        }
        Write-Host '  [A]  Install all in this category' -ForegroundColor Cyan
        Write-Host '  [P]  Show winget JSON pack path' -ForegroundColor DarkGray
        Write-Host '  [B]  Back' -ForegroundColor DarkGray
        Write-Host ''
        Write-Host '  Choice: ' -NoNewline

        $choice = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        Write-Host $choice.Character
        $key = $choice.Character.ToString().ToUpper()

        if ($key -eq 'B') { return }
        if ($key -eq 'P') {
            Write-Host ''
            Write-Host "  Winget pack: $packPath" -ForegroundColor Cyan
            Write-Host '  It can be reused with winget import after review.' -ForegroundColor DarkGray
            Write-Host ''
            Wait-AnyKey
            continue
        }

        if ($key -eq 'A') {
            Write-Host ''
            Write-Host "  Pack written: $packPath" -ForegroundColor DarkGray
            foreach ($package in $Category.Packages) {
                Install-WingetPackage -Name $package.Name -Id $package.Id
            }
            Write-Host ''
            Wait-AnyKey
            continue
        }

        $selected = $Category.Packages | Where-Object { $_.Key -eq $key } | Select-Object -First 1
        if ($selected) {
            Install-WingetPackage -Name $selected.Name -Id $selected.Id
            Write-Host ''
            Wait-AnyKey
        }
    }
}

if (-not (Test-WingetAvailable)) { return }

while ($true) {
    Write-Header 'Optional App Installer'

    foreach ($key in $Categories.Keys) {
        Write-Host "  [$key]  $($Categories[$key].Name)" -ForegroundColor White
    }
    Write-Host '  [Q]  Back to main menu' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  Choice: ' -NoNewline

    $choice = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    Write-Host $choice.Character
    $key = $choice.Character.ToString().ToUpper()

    if ($key -eq 'Q') {
        Set-StepStatus -Step 'OptionalApps' -Status complete -Detail 'Optional app menu closed.'
        return
    }
    if ($Categories.Contains($key)) {
        Invoke-PackageMenu -Category $Categories[$key]
    }
}
