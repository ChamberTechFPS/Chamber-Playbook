@echo off
title Chamber - Post-Install
:menu
cls
echo.
echo   ============================================
echo     CHAMBER - POST-INSTALL
echo   ============================================
echo.
echo    [1]  Verify system (checks every tweak)
echo    [2]  Verify + create support report zip
echo    [3]  Open Drivers folder
echo    [4]  Read the guide
echo    [Q]  Quit
echo.
set /p choice="   Select: "
if /i "%choice%"=="1" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Verify\Verify-Chamber.ps1" & pause & goto menu
if /i "%choice%"=="2" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Verify\Verify-Chamber.ps1" -ClientReport & pause & goto menu
if /i "%choice%"=="3" explorer "%~dp0Drivers" & goto menu
if /i "%choice%"=="4" notepad "%~dp0README.txt" & goto menu
if /i "%choice%"=="Q" exit /b
goto menu
