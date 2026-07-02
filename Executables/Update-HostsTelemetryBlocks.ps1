#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$hostsBackup = $hostsPath + '.chamber-backup'
$entries = @(
    '0.0.0.0 vortex.data.microsoft.com',
    '0.0.0.0 settings-win.data.microsoft.com',
    '0.0.0.0 telemetry.microsoft.com',
    '0.0.0.0 watson.telemetry.microsoft.com',
    '0.0.0.0 statsfe2.ws.microsoft.com',
    '0.0.0.0 statsfe1.ws1.microsoft.com'
)

# Take a one-time backup before the first modification
if ((Test-Path -LiteralPath $hostsPath) -and -not (Test-Path -LiteralPath $hostsBackup)) {
    [System.IO.File]::Copy($hostsPath, $hostsBackup)
}

$tempPath = $hostsPath + '.tmp'

for ($attempt = 1; $attempt -le 10; $attempt++) {
    try {
        $lines = [System.Collections.Generic.List[string]]::new()
        if (Test-Path -LiteralPath $hostsPath) {
            $lines.AddRange([System.IO.File]::ReadAllLines($hostsPath))
        }

        $changed = $false
        foreach ($entry in $entries) {
            if (-not $lines.Contains($entry)) {
                $lines.Add($entry)
                $changed = $true
            }
        }

        if ($changed) {
            # Write to temp first, then overwrite the hosts file explicitly.
            # File.Move cannot replace an existing destination on Windows.
            [System.IO.File]::WriteAllLines($tempPath, $lines, [System.Text.Encoding]::ASCII)
            Copy-Item -LiteralPath $tempPath -Destination $hostsPath -Force
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }

        break
    } catch [System.IO.IOException] {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
        if ($attempt -eq 10) {
            throw
        }

        Start-Sleep -Milliseconds 500
    } catch [System.UnauthorizedAccessException] {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
        if ($attempt -eq 10) {
            throw
        }

        Start-Sleep -Milliseconds 500
    }
}
