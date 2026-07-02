#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class TaskbarNative
{
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct APPBARDATA
    {
        public uint cbSize;
        public IntPtr hWnd;
        public uint uCallbackMessage;
        public uint uEdge;
        public RECT rc;
        public IntPtr lParam;
    }

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern IntPtr FindWindow(string lpClassName, string lpWindowName);

    [DllImport("shell32.dll")]
    public static extern UIntPtr SHAppBarMessage(uint dwMessage, ref APPBARDATA pData);
}
"@

try {
    $taskbarHwnd = [TaskbarNative]::FindWindow('Shell_TrayWnd', $null)
    if ($taskbarHwnd -eq [IntPtr]::Zero) {
        throw 'Could not find the Windows taskbar window. Ensure Explorer is running and try again.'
    }

    $abd = New-Object TaskbarNative+APPBARDATA
    $abd.cbSize = [uint32][System.Runtime.InteropServices.Marshal]::SizeOf($abd)
    $abd.hWnd = $taskbarHwnd

    # ABM_SETSTATE with ABS_AUTOHIDE | ABS_ALWAYSONTOP.
    $abd.lParam = [IntPtr]3
    [void][TaskbarNative]::SHAppBarMessage(0x0000000A, [ref]$abd)
} catch {
    Write-Host "ERROR: Failed to configure taskbar for OLED safety: $_" -ForegroundColor Red
    exit 1
}
