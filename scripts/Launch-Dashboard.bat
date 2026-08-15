@echo off
setlocal

:: Multi Session Dashboard launcher.
::
:: Dashboard.ps1 requires an elevated session (Assert-Administrator in
:: MultiSessionDashboard.psm1 throws otherwise), so this self-elevates:
:: if we're not already running as Administrator, it relaunches itself
:: with a UAC prompt via PowerShell's Start-Process -Verb RunAs, then
:: exits this non-elevated copy. That means double-clicking this file
:: from Explorer (or a desktop/Start Menu shortcut to it) is enough --
:: no need to open an elevated PowerShell prompt manually and remember
:: the full powershell.exe -ExecutionPolicy Bypass -File "..." command
:: line every time.
net session >nul 2>&1
if %errorLevel% neq 0 (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Dashboard.ps1"
