@echo off
setlocal

:: Self-elevate if not already running as administrator
net session >nul 2>&1
if %ERRORLEVEL% NEQ 0 (
    echo Requesting administrator privileges...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

cd /d "%~dp0"
PowerShell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\0-Launcher.ps1"
if %ERRORLEVEL% NEQ 0 (
    echo.
    echo ERROR: Script exited with code %ERRORLEVEL%
    echo Check the output above for details.
    echo.
    pause
)
