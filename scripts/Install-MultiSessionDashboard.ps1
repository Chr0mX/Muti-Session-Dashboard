#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$InstallRoot = 'C:\Program Files\Muti Session Dashboard',
    [string]$RdpWrapperUri = 'https://github.com/sergiye/rdpWrapper/releases/latest/download/rdpWrapper_x64.exe',
    [string]$MoonlightUri = 'https://github.com/moonlight-stream/moonlight-qt/releases/latest/download/MoonlightPortable-x64.zip',
    [string]$SunshineUri = 'https://github.com/LizardByte/Sunshine/releases/latest/download/sunshine-windows-portable.zip',
    [Parameter(Mandatory=$false)][string]$AardwolfCliUri,
    [Parameter(Mandatory=$false)][string]$AardwolfGuiUri,
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
    (Join-Path $InstallRoot 'Aardwolf'),
    (Join-Path $InstallRoot 'Config'),
    (Join-Path $InstallRoot 'Users')
)
foreach ($directory in $directories) {
    if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
}

Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Dashboard.ps1') -Destination (Join-Path $InstallRoot 'Dashboard.ps1') -Force
Copy-Item -LiteralPath $modulePath -Destination (Join-Path $InstallRoot 'MultiSessionDashboard.psm1') -Force

Write-Host 'Installing RDP Wrapper...'
Install-RdpWrapper -Source $RdpWrapperUri

Write-Host 'Installing Moonlight Portable...'
Install-MoonlightPortable -Uri $MoonlightUri

Write-Host 'Installing Sunshine Portable master copy...'
Install-SunshinePortable -Uri $SunshineUri

Write-Host 'Installing Aardwolf components...'
if ([string]::IsNullOrWhiteSpace($AardwolfCliUri) -or [string]::IsNullOrWhiteSpace($AardwolfGuiUri)) {
    throw 'Aardwolf CLI and GUI download URLs must be supplied with -AardwolfCliUri and -AardwolfGuiUri so the installer can verify exact required components.'
}
Install-AardwolfComponents -CliUri $AardwolfCliUri -GuiUri $AardwolfGuiUri

$checks = Test-DashboardInstallation
$checks | Format-Table -AutoSize
$failed = @($checks | Where-Object { -not $_.Passed })
if ($failed.Count -gt 0) {
    throw "Installation incomplete. Failed checks: $($failed.Check -join ', ')"
}

Write-Host 'Multi Session Dashboard installation completed and verified.'
