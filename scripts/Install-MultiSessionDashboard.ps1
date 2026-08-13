#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$InstallRoot = 'C:\Program Files\Muti Session Dashboard',
    # Empty by default: Install-RdpWrapper then resolves the latest release
    # through the GitHub API (like Moonlight/Sunshine below) so its download
    # cache is keyed on the actual release version instead of the static
    # 'latest/download/<fixed filename>' URL, whose text never changes
    # between releases. Pass an explicit URL here to bypass that and
    # download it directly instead.
    [string]$RdpWrapperUri = '',
    [string]$RdpWrapperReleaseApiUri = 'https://api.github.com/repos/sergiye/rdpWrapper/releases/latest',
    [string[]]$RdpWrapperAssetNamePatterns = @('(?i)^rdpWrapper_x64\.exe$', '(?i)^rdpWrapper.*x64.*\.exe$', '(?i)^rdpWrapper.*\.zip$'),
    [string[]]$RdpWrapperInstallArguments = @('-install'),
    [int]$RdpWrapperInstallTimeoutSeconds = 600,
    [string]$MoonlightReleaseApiUri = 'https://api.github.com/repos/moonlight-stream/moonlight-qt/releases/latest',
    [string[]]$MoonlightAssetNamePatterns = @('^MoonlightPortable-x64\.zip$', '^MoonlightPortable-x64-.*\.zip$', '^MoonlightPortable.*x64.*\.zip$'),
    [string]$SunshineReleaseApiUri = 'https://api.github.com/repos/LizardByte/Sunshine/releases/latest',
    [string[]]$SunshineAssetNamePatterns = @('(?i)^sunshine-windows-portable\.zip$', '(?i)^sunshine-windows.*portable.*\.zip$', '(?i)^sunshine.*windows.*portable.*\.zip$', '(?i)^sunshine.*portable.*windows.*\.zip$'),
    [string]$RemoteDesktopPlusUri = 'https://www.donkz.nl/download/remote-desktop-plus-msi/',
    [int]$RemoteDesktopPlusInstallTimeoutSeconds = 300,
    [switch]$RefreshDownloadCache
)

$ErrorActionPreference = 'Stop'
$modulePath = Join-Path $PSScriptRoot 'MultiSessionDashboard.psm1'
Import-Module $modulePath -Force
Set-DashboardPaths -InstallRoot $InstallRoot
if ($RefreshDownloadCache) {
    $cachePath = Join-Path $InstallRoot 'Config\Downloads'
    if (Test-Path -LiteralPath $cachePath) { Remove-Item -LiteralPath $cachePath -Recurse -Force }
}

Assert-Administrator

$directories = @(
    $InstallRoot,
    (Join-Path $InstallRoot 'Stream\Moonlight'),
    (Join-Path $InstallRoot 'Stream\Sunshine'),
    (Join-Path $InstallRoot 'Config'),
    (Join-Path $InstallRoot 'Users')
)
foreach ($directory in $directories) {
    if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
}

Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Dashboard.ps1') -Destination (Join-Path $InstallRoot 'Dashboard.ps1') -Force
Copy-Item -LiteralPath $modulePath -Destination (Join-Path $InstallRoot 'MultiSessionDashboard.psm1') -Force

Write-Host 'Installing RDP Wrapper...'
Install-RdpWrapper -Source $RdpWrapperUri -ReleaseApiUri $RdpWrapperReleaseApiUri -AssetNamePatterns $RdpWrapperAssetNamePatterns -InstallArguments $RdpWrapperInstallArguments -InstallTimeoutSeconds $RdpWrapperInstallTimeoutSeconds

Write-Host 'Installing Moonlight Portable...'
Install-MoonlightPortable -ReleaseApiUri $MoonlightReleaseApiUri -AssetNamePatterns $MoonlightAssetNamePatterns

Write-Host 'Installing Sunshine Portable...'
Install-SunshinePortable -ReleaseApiUri $SunshineReleaseApiUri -AssetNamePatterns $SunshineAssetNamePatterns

Write-Host 'Installing Remote Desktop Plus...'
Install-RemoteDesktopPlus -Source $RemoteDesktopPlusUri -InstallTimeoutSeconds $RemoteDesktopPlusInstallTimeoutSeconds

Write-Host 'Using native Windows tscon for RDP session handoff and Remote Desktop Plus for automated RDP login on 127.0.0.2:3389...'
if (-not (Test-TsconAvailable)) { throw 'tscon.exe is required but was not found in System32.' }

$checks = Test-DashboardInstallation
$checks | Format-Table -AutoSize
$failed = @($checks | Where-Object { -not $_.Passed })
if ($failed.Count -gt 0) {
    throw "Installation incomplete. Failed checks: $($failed.Check -join ', ')"
}

Write-Host 'Multi Session Dashboard installation completed and verified.'
