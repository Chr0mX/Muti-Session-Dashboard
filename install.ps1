#Requires -RunAsAdministrator
<#
    .SYNOPSIS
    URL-based installer/updater entry point for Multi Session Dashboard.

    .DESCRIPTION
    Designed to be run directly from GitHub with no local checkout, e.g.:

        irm https://raw.githubusercontent.com/Chr0mX/Muti-Session-Dashboard/main/install.ps1 | iex

    The same command works for both a first-time install and an update: it
    always downloads the latest scripts and dependency releases and re-runs
    the (idempotent) installer, overwriting the previous installation.

    When piped through `irm | iex`, $PSScriptRoot is empty and there is no
    local checkout to load MultiSessionDashboard.psm1/Dashboard.ps1 from, so
    this script stages fresh copies of the required scripts from the repo's
    raw GitHub URLs into a temp directory and invokes the real installer from
    there.
#>
[CmdletBinding()]
param(
    [string]$RepoRawBaseUri = 'https://raw.githubusercontent.com/Chr0mX/Muti-Session-Dashboard/main/scripts',
    [string]$InstallRoot = 'C:\Program Files\Muti Session Dashboard',
    [string]$RdpWrapperUri = 'https://github.com/sergiye/rdpWrapper/releases/latest/download/rdpWrapper_x64.exe',
    [string[]]$RdpWrapperInstallArguments = @('-install'),
    [int]$RdpWrapperInstallTimeoutSeconds = 600,
    [string]$MoonlightReleaseApiUri = 'https://api.github.com/repos/moonlight-stream/moonlight-qt/releases/latest',
    [string[]]$MoonlightAssetNamePatterns = @('^MoonlightPortable-x64\.zip$', '^MoonlightPortable-x64-.*\.zip$', '^MoonlightPortable.*x64.*\.zip$'),
    [string]$SunshineReleaseApiUri = 'https://api.github.com/repos/LizardByte/Sunshine/releases/latest',
    [string[]]$SunshineAssetNamePatterns = @('(?i)^sunshine-windows-portable\.zip$', '(?i)^sunshine-windows.*portable.*\.zip$', '(?i)^sunshine.*windows.*portable.*\.zip$', '(?i)^sunshine.*portable.*windows.*\.zip$'),
    [string]$RemoteDesktopPlusUri = 'https://www.donkz.nl/download/remote-desktop-plus-msi/',
    [int]$RemoteDesktopPlusInstallTimeoutSeconds = 300
)

$ErrorActionPreference = 'Stop'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this installer from an elevated PowerShell session (Run as Administrator).'
}

$staging = Join-Path $env:TEMP ("MultiSessionDashboard-Install-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $staging -Force | Out-Null

try {
    $files = @('MultiSessionDashboard.psm1', 'Dashboard.ps1', 'Install-MultiSessionDashboard.ps1')
    foreach ($file in $files) {
        $uri = "$RepoRawBaseUri/$file"
        $destination = Join-Path $staging $file
        Write-Host "Fetching $uri"
        Invoke-WebRequest -Uri $uri -OutFile $destination -UseBasicParsing
    }

    # -RefreshDownloadCache guarantees this same command updates an existing
    # install: it re-resolves and re-downloads the latest RDP Wrapper,
    # Moonlight, and Sunshine releases instead of reusing a stale cache.
    & (Join-Path $staging 'Install-MultiSessionDashboard.ps1') `
        -InstallRoot $InstallRoot `
        -RdpWrapperUri $RdpWrapperUri `
        -RdpWrapperInstallArguments $RdpWrapperInstallArguments `
        -RdpWrapperInstallTimeoutSeconds $RdpWrapperInstallTimeoutSeconds `
        -MoonlightReleaseApiUri $MoonlightReleaseApiUri `
        -MoonlightAssetNamePatterns $MoonlightAssetNamePatterns `
        -SunshineReleaseApiUri $SunshineReleaseApiUri `
        -SunshineAssetNamePatterns $SunshineAssetNamePatterns `
        -RemoteDesktopPlusUri $RemoteDesktopPlusUri `
        -RemoteDesktopPlusInstallTimeoutSeconds $RemoteDesktopPlusInstallTimeoutSeconds `
        -RefreshDownloadCache
} finally {
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
}
