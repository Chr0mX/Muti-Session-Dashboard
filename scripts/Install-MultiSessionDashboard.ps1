#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$InstallRoot = 'C:\Program Files\Muti Session Dashboard',
    # Empty by default: Install-RdpWrapper then resolves the latest release
    # through the GitHub API so its download cache is keyed on the actual
    # release version instead of the static 'latest/download/<fixed
    # filename>' URL, whose text never changes between releases. Pass an
    # explicit URL here to bypass that and download it directly instead.
    [string]$RdpWrapperUri = '',
    [string]$RdpWrapperReleaseApiUri = 'https://api.github.com/repos/sergiye/rdpWrapper/releases/latest',
    [string[]]$RdpWrapperAssetNamePatterns = @('(?i)^rdpWrapper_x64\.exe$', '(?i)^rdpWrapper.*x64.*\.exe$', '(?i)^rdpWrapper.*\.zip$'),
    [string[]]$RdpWrapperInstallArguments = @('-install'),
    [int]$RdpWrapperInstallTimeoutSeconds = 600,
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
    (Join-Path $InstallRoot 'Config'),
    (Join-Path $InstallRoot 'Users')
)
foreach ($directory in $directories) {
    if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
}

Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Dashboard.ps1') -Destination (Join-Path $InstallRoot 'Dashboard.ps1') -Force
Copy-Item -LiteralPath $modulePath -Destination (Join-Path $InstallRoot 'MultiSessionDashboard.psm1') -Force

# MultiSessionDashboard.psm1 is only the coordinator; it loads these four
# focused backend modules from the same directory it's running from, so
# they need to land alongside it in the install root too.
foreach ($backendModule in @('SessionManager.psm1', 'UserManager.psm1', 'RdpManager.psm1', 'HeadlessManager.psm1')) {
    $source = Join-Path $PSScriptRoot $backendModule
    if (-not (Test-Path -LiteralPath $source)) {
        throw "Required backend module '$backendModule' was not found next to Install-MultiSessionDashboard.ps1 at '$source'."
    }
    Copy-Item -LiteralPath $source -Destination (Join-Path $InstallRoot $backendModule) -Force
}

Write-Host 'Installing RDP Wrapper...'
Install-RdpWrapper -Source $RdpWrapperUri -ReleaseApiUri $RdpWrapperReleaseApiUri -AssetNamePatterns $RdpWrapperAssetNamePatterns -InstallArguments $RdpWrapperInstallArguments -InstallTimeoutSeconds $RdpWrapperInstallTimeoutSeconds

Write-Host 'Installing Remote Desktop Plus...'
Install-RemoteDesktopPlus -Source $RemoteDesktopPlusUri -InstallTimeoutSeconds $RemoteDesktopPlusInstallTimeoutSeconds

$checks = Test-DashboardInstallation
$checks | Format-Table -AutoSize
$failed = @($checks | Where-Object { -not $_.Passed })
if ($failed.Count -gt 0) {
    throw "Installation incomplete. Failed checks: $($failed.Check -join ', ')"
}

Write-Host 'Multi Session Dashboard installation completed and verified.'
