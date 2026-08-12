Set-StrictMode -Version Latest

$script:InstallRoot = 'C:\Program Files\Muti Session Dashboard'
$script:RdpWrapperRoot = 'C:\Program Files\RDP Wrapper'
$script:ConfigRoot = Join-Path $script:InstallRoot 'Config'
$script:UsersRoot = Join-Path $script:InstallRoot 'Users'
$script:StateFile = Join-Path $script:ConfigRoot 'sessions.json'
$script:DownloadCacheRoot = Join-Path $script:ConfigRoot 'Downloads'
$script:PortStart = 47989
$script:PortEnd = 48050


function Set-DashboardPaths {
    param([Parameter(Mandatory)][string]$InstallRoot)
    $script:InstallRoot = $InstallRoot
    $script:ConfigRoot = Join-Path $script:InstallRoot 'Config'
    $script:UsersRoot = Join-Path $script:InstallRoot 'Users'
    $script:StateFile = Join-Path $script:ConfigRoot 'sessions.json'
    $script:DownloadCacheRoot = Join-Path $script:ConfigRoot 'Downloads'
}

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Multi Session Dashboard must be run from an elevated PowerShell session.'
    }
}

function New-DirectoryIfMissing {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Get-SafeCacheFileName {
    param([Parameter(Mandatory)][string]$Uri, [Parameter(Mandatory)][string]$Name)
    $extension = [IO.Path]::GetExtension(([Uri]$Uri).AbsolutePath)
    if ([string]::IsNullOrWhiteSpace($extension)) { $extension = '.download' }
    $hashInput = [Text.Encoding]::UTF8.GetBytes($Uri)
    $sha = [Security.Cryptography.SHA256]::Create()
    $hash = ([BitConverter]::ToString($sha.ComputeHash($hashInput))).Replace('-', '').Substring(0, 12).ToLowerInvariant()
    return "$Name-$hash$extension"
}

function Test-UsableDownload {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $item = Get-Item -LiteralPath $Path
    return ($item.Length -gt 0)
}

function Invoke-DownloadFile {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$CacheName,
        [string]$CacheDirectory = $script:DownloadCacheRoot,
        [switch]$ForceDownload
    )

    New-DirectoryIfMissing -Path (Split-Path -Parent $Destination)
    New-DirectoryIfMissing -Path $CacheDirectory

    $cachePath = Join-Path $CacheDirectory (Get-SafeCacheFileName -Uri $Uri -Name $CacheName)
    if (-not $ForceDownload -and (Test-UsableDownload -Path $cachePath)) {
        Copy-Item -LiteralPath $cachePath -Destination $Destination -Force
        Write-Host "Using cached download for $CacheName: $cachePath"
        return $Destination
    }

    $partial = "$cachePath.partial"
    try {
        if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force }
        Write-Host "Downloading $CacheName from $Uri"
        Invoke-WebRequest -Uri $Uri -OutFile $partial -UseBasicParsing
        if (-not (Test-UsableDownload -Path $partial)) { throw "Downloaded file is empty: $Uri" }
        Move-Item -LiteralPath $partial -Destination $cachePath -Force
        Copy-Item -LiteralPath $cachePath -Destination $Destination -Force
        return $Destination
    } catch {
        if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue }
        if (Test-UsableDownload -Path $cachePath) {
            Write-Warning "Download failed for $CacheName; using cached copy at $cachePath. Error: $($_.Exception.Message)"
            Copy-Item -LiteralPath $cachePath -Destination $Destination -Force
            return $Destination
        }
        throw "Download failed for $CacheName from $Uri and no cached copy is available. Place the file in '$cachePath' or re-run when the network is available. Error: $($_.Exception.Message)"
    }
}

function Expand-ArchiveSafe {
    param([Parameter(Mandatory)][string]$Archive, [Parameter(Mandatory)][string]$Destination)
    if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Recurse -Force }
    New-DirectoryIfMissing -Path $Destination
    Expand-Archive -Path $Archive -DestinationPath $Destination -Force
}

function Install-RdpWrapper {
    param([string]$Source = 'https://github.com/sergiye/rdpWrapper/archive/refs/heads/master.zip')
    $zip = Join-Path $env:TEMP 'rdpWrapper.zip'
    Invoke-DownloadFile -Uri $Source -Destination $zip -CacheName 'rdpWrapper'
    Expand-ArchiveSafe -Archive $zip -Destination $script:RdpWrapperRoot

    $install = Get-ChildItem -LiteralPath $script:RdpWrapperRoot -Recurse -Filter 'install.bat' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($install) { Start-Process -FilePath $install.FullName -WorkingDirectory $install.DirectoryName -Wait -Verb RunAs }

    Set-RdpWrapperConfiguration
    $result = Test-RdpWrapperConfiguration
    if (-not $result.Success) { throw "RDP Wrapper verification failed: $($result.Failures -join ', ')" }
}

function Set-RdpWrapperConfiguration {
    New-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -Value 0 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name 'AllowRemoteRPC' -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path 'HKLM:\Software\Policies\Microsoft\Windows NT\Terminal Services' -Name 'Shadow' -Value 2 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path 'HKLM:\Software\Microsoft\Terminal Server Client' -Name 'AuthenticationLevelOverride' -Value 0 -PropertyType DWord -Force | Out-Null
    New-NetFirewallRule -DisplayGroup 'Remote Desktop' -Enabled True -ErrorAction SilentlyContinue | Out-Null

    $ini = Get-ChildItem -LiteralPath $script:RdpWrapperRoot -Recurse -Filter 'rdpwrap.ini' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($ini) {
        $content = Get-Content -LiteralPath $ini.FullName -Raw
        if ($content -notmatch '(?im)^PreferredWrapper=') { $content += "`r`nPreferredWrapper=TermWrap`r`n" }
        else { $content = $content -replace '(?im)^PreferredWrapper=.*$', 'PreferredWrapper=TermWrap' }
        Set-Content -LiteralPath $ini.FullName -Value $content -Encoding ASCII
    }
}

function Test-RdpWrapperConfiguration {
    $failures = [System.Collections.Generic.List[string]]::new()
    if (-not (Test-Path -LiteralPath $script:RdpWrapperRoot)) { $failures.Add('RDP Wrapper installed') }
    $deny = (Get-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -ErrorAction SilentlyContinue).fDenyTSConnections
    if ($deny -ne 0) { $failures.Add('Remote Desktop enabled') }
    $shadow = (Get-ItemProperty -Path 'HKLM:\Software\Policies\Microsoft\Windows NT\Terminal Services' -Name 'Shadow' -ErrorAction SilentlyContinue).Shadow
    if ($shadow -ne 2) { $failures.Add('Session Shadow configured') }
    $auth = (Get-ItemProperty -Path 'HKLM:\Software\Microsoft\Terminal Server Client' -Name 'AuthenticationLevelOverride' -ErrorAction SilentlyContinue).AuthenticationLevelOverride
    if ($auth -ne 0) { $failures.Add('RDP authentication/client warning configured') }
    $ini = Get-ChildItem -LiteralPath $script:RdpWrapperRoot -Recurse -Filter 'rdpwrap.ini' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $ini -or ((Get-Content -LiteralPath $ini.FullName -Raw) -notmatch '(?im)^PreferredWrapper=TermWrap$')) { $failures.Add('TermWrap configured') }
    [pscustomobject]@{ Success = $failures.Count -eq 0; Failures = $failures }
}

function Install-PortableZip {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Uri, [Parameter(Mandatory)][string]$Destination)
    $zip = Join-Path $env:TEMP "$Name.zip"
    Invoke-DownloadFile -Uri $Uri -Destination $zip -CacheName $Name
    Expand-ArchiveSafe -Archive $zip -Destination $Destination
}

function Install-MoonlightPortable {
    param([string]$Uri = 'https://github.com/moonlight-stream/moonlight-qt/releases/latest/download/MoonlightPortable-x64.zip')
    Install-PortableZip -Name 'moonlight' -Uri $Uri -Destination (Join-Path $script:InstallRoot 'Stream\Moonlight')
    if (-not (Test-Path -LiteralPath (Join-Path $script:InstallRoot 'Stream\Moonlight\Moonlight.exe'))) { throw 'Moonlight.exe was not found after extraction.' }
}

function Install-SunshinePortable {
    param([string]$Uri = 'https://github.com/LizardByte/Sunshine/releases/latest/download/sunshine-windows-portable.zip')
    Install-PortableZip -Name 'sunshine' -Uri $Uri -Destination (Join-Path $script:InstallRoot 'Stream\Sunshine')
    if (-not (Test-Path -LiteralPath (Join-Path $script:InstallRoot 'Stream\Sunshine\Sunshine.exe'))) { throw 'Sunshine.exe was not found after extraction.' }
}

function Install-AardwolfComponents {
    param(
        [string]$CliUri = 'https://github.com/tsl0922/ttyd/releases/latest/download/aardwolf-windows-x64.zip',
        [string]$GuiUri = 'https://github.com/tsl0922/ttyd/releases/latest/download/aardwolf-gui-windows-x64.zip'
    )
    $dest = Join-Path $script:InstallRoot 'Aardwolf'
    Install-PortableZip -Name 'aardwolf' -Uri $CliUri -Destination $dest
    Install-PortableZip -Name 'aardwolf-gui' -Uri $GuiUri -Destination $dest
    if (-not (Test-Path -LiteralPath (Join-Path $dest 'Aardwolf.exe'))) { throw 'Aardwolf.exe was not found after extraction.' }
    if (-not (Test-Path -LiteralPath (Join-Path $dest 'AardwolfGUI.exe'))) { throw 'AardwolfGUI.exe was not found after extraction.' }
}

function ConvertTo-HashtableRecursive {
    param([Parameter(ValueFromPipeline)]$InputObject)
    process {
        if ($null -eq $InputObject) { return $null }
        if ($InputObject -is [hashtable]) { return $InputObject }
        if ($InputObject -is [System.Collections.IDictionary]) {
            $hash = @{}
            foreach ($key in $InputObject.Keys) { $hash[$key] = ConvertTo-HashtableRecursive $InputObject[$key] }
            return $hash
        }
        if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
            return @($InputObject | ForEach-Object { ConvertTo-HashtableRecursive $_ })
        }
        if ($InputObject -is [pscustomobject]) {
            $hash = @{}
            foreach ($property in $InputObject.PSObject.Properties) { $hash[$property.Name] = ConvertTo-HashtableRecursive $property.Value }
            return $hash
        }
        return $InputObject
    }
}

function Get-DashboardState {
    New-DirectoryIfMissing -Path $script:ConfigRoot
    if (-not (Test-Path -LiteralPath $script:StateFile)) { return @{} }
    $json = Get-Content -LiteralPath $script:StateFile -Raw
    if ([string]::IsNullOrWhiteSpace($json)) { return @{} }
    $obj = $json | ConvertFrom-Json
    return (ConvertTo-HashtableRecursive $obj)
}

function Save-DashboardState { param([hashtable]$State) $State | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:StateFile -Encoding UTF8 }

function Test-BlankPasswordRdpPolicy {
    $value = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name 'LimitBlankPasswordUse' -ErrorAction SilentlyContinue).LimitBlankPasswordUse
    [pscustomobject]@{ AllowsBlankPasswordRdp = ($value -eq 0); PolicyValue = $value }
}

function New-DashboardUser {
    param([Parameter(Mandatory)][string]$Username, [string]$Password, [switch]$AllowBlankPasswordPolicyChange)
    Assert-Administrator
    if ([string]::IsNullOrEmpty($Password)) {
        $policy = Test-BlankPasswordRdpPolicy
        if (-not $policy.AllowsBlankPasswordRdp) {
            if (-not $AllowBlankPasswordPolicyChange) { throw 'Blank password RDP logon is blocked by Windows policy. Re-run with explicit AllowBlankPasswordPolicyChange after warning the operator.' }
            Write-Warning 'Changing LimitBlankPasswordUse weakens Windows security by permitting blank-password remote logon.'
            New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name 'LimitBlankPasswordUse' -Value 0 -PropertyType DWord -Force | Out-Null
        }
        net user $Username /add | Out-Null
    } else {
        net user $Username $Password /add | Out-Null
    }
    net localgroup 'Remote Desktop Users' $Username /add | Out-Null

    $userRoot = Join-Path $script:UsersRoot $Username
    New-DirectoryIfMissing -Path $userRoot
    Initialize-UserSunshine -Username $Username
}

function Initialize-UserSunshine {
    param([Parameter(Mandatory)][string]$Username)
    $master = Join-Path $script:InstallRoot 'Stream\Sunshine'
    if (-not (Test-Path -LiteralPath (Join-Path $master 'Sunshine.exe'))) { throw 'Master Sunshine installation is missing.' }
    $profile = Join-Path 'C:\Users' $Username
    $dest = Join-Path $profile 'AppData\Local\Muti Session Dashboard\Sunshine'
    New-DirectoryIfMissing -Path $dest
    Copy-Item -LiteralPath (Join-Path $master '*') -Destination $dest -Recurse -Force
    $configDir = Join-Path $profile 'AppData\Local\Muti Session Dashboard\Config'
    New-DirectoryIfMissing -Path $configDir
    Set-UserSunshineConfig -Username $Username -Port (Get-AllocatedPort -Username $Username -Reserve:$false)
}

function Get-AllocatedPort {
    param([Parameter(Mandatory)][string]$Username, [switch]$Reserve)
    $state = Get-DashboardState
    if ($state.ContainsKey($Username) -and $state[$Username].SunshinePort) { return [int]$state[$Username].SunshinePort }
    $used = @($state.Values | ForEach-Object { $_.SunshinePort })
    foreach ($port in $script:PortStart..$script:PortEnd) {
        if ($used -notcontains $port -and -not (Test-NetConnection -ComputerName '127.0.0.1' -Port $port -InformationLevel Quiet -WarningAction SilentlyContinue)) {
            if ($Reserve) {
                $state[$Username] = @{ Username=$Username; SunshinePort=$port; SessionState='Stopped'; SunshineState='Stopped'; RdpSessionId=$null; RdpConnectionStatus='Disconnected' }
                Save-DashboardState -State $state
            }
            return $port
        }
    }
    throw 'No available Sunshine ports remain.'
}

function Set-UserSunshineConfig {
    param([Parameter(Mandatory)][string]$Username, [Parameter(Mandatory)][int]$Port)
    $configDir = Join-Path (Join-Path 'C:\Users' $Username) 'AppData\Local\Muti Session Dashboard\Config'
    New-DirectoryIfMissing -Path $configDir
    $content = @(
        "# Generated by Multi Session Dashboard",
        "port = $Port",
        'origin_web_ui_allowed = lan',
        'upnp = disabled',
        'global_prep_cmd = []'
    ) -join "`r`n"
    Set-Content -LiteralPath (Join-Path $configDir 'sunshine.conf') -Value $content -Encoding UTF8
}

function Start-DashboardSession {
    param([Parameter(Mandatory)][string]$Username)
    Assert-Administrator
    $port = Get-AllocatedPort -Username $Username -Reserve
    Set-UserSunshineConfig -Username $Username -Port $port
    $aardwolf = Join-Path $script:InstallRoot 'Aardwolf\Aardwolf.exe'
    if (Test-Path -LiteralPath $aardwolf) { Start-Process -FilePath $aardwolf -ArgumentList @('start','--user', $Username) }
    $sunshine = Join-Path (Join-Path 'C:\Users' $Username) 'AppData\Local\Muti Session Dashboard\Sunshine\Sunshine.exe'
    $conf = Join-Path (Join-Path 'C:\Users' $Username) 'AppData\Local\Muti Session Dashboard\Config\sunshine.conf'
    Start-Process -FilePath $sunshine -ArgumentList @($conf) -LoadUserProfile
    $state = Get-DashboardState
    $state[$Username].SessionState = 'Running'; $state[$Username].SunshineState = 'Running'; $state[$Username].RdpConnectionStatus = 'Available'
    Save-DashboardState -State $state
}

function Connect-DashboardRdp {
    param([Parameter(Mandatory)][string]$Username)
    $state = Get-DashboardState
    if (-not $state.ContainsKey($Username) -or $state[$Username].SessionState -eq 'Stopped') { throw 'Start the session before connecting RDP.' }
    Start-Process -FilePath (Join-Path $script:InstallRoot 'Aardwolf\AardwolfGUI.exe') -ArgumentList @('connect','--user', $Username)
}

function Connect-DashboardMoonlight {
    param([Parameter(Mandatory)][string]$Username)
    $moonlight = Join-Path $script:InstallRoot 'Stream\Moonlight\Moonlight.exe'
    if (-not (Test-Path -LiteralPath $moonlight)) { throw 'Moonlight.exe is missing.' }
    Start-Process -FilePath $moonlight -ArgumentList @('--display-mode','windowed','--resolution','1920x1080')
}

function Stop-DashboardSession {
    param([Parameter(Mandatory)][string]$Username)
    Get-Process -Name 'Sunshine' -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "C:\Users\$Username\AppData\Local\Muti Session Dashboard\Sunshine\*" } | Stop-Process -Force
    $aardwolf = Join-Path $script:InstallRoot 'Aardwolf\Aardwolf.exe'
    if (Test-Path -LiteralPath $aardwolf) { Start-Process -FilePath $aardwolf -ArgumentList @('stop','--user', $Username) -Wait }
    logoff $Username 2>$null
    $state = Get-DashboardState
    if ($state.ContainsKey($Username)) { $state[$Username].SunshinePort = $null; $state[$Username].SessionState='Stopped'; $state[$Username].SunshineState='Stopped'; $state[$Username].RdpConnectionStatus='Disconnected'; Save-DashboardState -State $state }
}

function Test-DashboardInstallation {
    $checks = [ordered]@{
        'RDP Wrapper installed' = (Test-Path -LiteralPath $script:RdpWrapperRoot)
        'TermWrap configured' = (Test-RdpWrapperConfiguration).Success
        'Remote Desktop enabled' = (((Get-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -ErrorAction SilentlyContinue).fDenyTSConnections) -eq 0)
        'Moonlight downloaded' = (Test-Path -LiteralPath (Join-Path $script:InstallRoot 'Stream\Moonlight\Moonlight.exe'))
        'Sunshine downloaded' = (Test-Path -LiteralPath (Join-Path $script:InstallRoot 'Stream\Sunshine\Sunshine.exe'))
        'Aardwolf installed' = (Test-Path -LiteralPath (Join-Path $script:InstallRoot 'Aardwolf\Aardwolf.exe'))
        'Aardwolf GUI available' = (Test-Path -LiteralPath (Join-Path $script:InstallRoot 'Aardwolf\AardwolfGUI.exe'))
        'Dashboard installed' = (Test-Path -LiteralPath (Join-Path $script:InstallRoot 'Dashboard.ps1'))
    }
    $checks.GetEnumerator() | ForEach-Object { [pscustomobject]@{ Check=$_.Key; Passed=[bool]$_.Value } }
}

Export-ModuleMember -Function *-Dashboard*,Install-*,Test-*,New-DashboardUser,Start-DashboardSession,Stop-DashboardSession,Connect-DashboardRdp,Connect-DashboardMoonlight,Assert-Administrator,Set-DashboardPaths
