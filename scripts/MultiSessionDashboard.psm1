Set-StrictMode -Version Latest

$script:InstallRoot = 'C:\Program Files\Muti Session Dashboard'
$script:RdpWrapperRoot = 'C:\Program Files\RDP Wrapper'
$script:ConfigRoot = Join-Path $script:InstallRoot 'Config'
$script:UsersRoot = Join-Path $script:InstallRoot 'Users'
$script:StateFile = Join-Path $script:ConfigRoot 'sessions.json'
$script:DownloadCacheRoot = Join-Path $script:ConfigRoot 'Downloads'
$script:RdpFileCacheRoot = Join-Path $script:ConfigRoot 'RdpFiles'
# RDP Wrapper's concurrent multi-session support is more reliable connecting
# through a distinct loopback address than through 127.0.0.1 -- this is kept
# regardless of whether a session ever touches the console.
$script:RdpHost = '127.0.0.2'
$script:RdpPort = 3389
$script:RdpPlusPath = 'C:\Program Files (x86)\Remote Desktop Plus\rdp.exe'
$script:RdpWrapperManagerPath = 'C:\Program Files\RDP Wrapper\rdpWrapper_x64.exe'
$script:RdpFileCacheRoot = $null


function Set-DashboardPaths {
    param([Parameter(Mandatory)][string]$InstallRoot)
    $script:InstallRoot = $InstallRoot
    $script:ConfigRoot = Join-Path $script:InstallRoot 'Config'
    $script:UsersRoot = Join-Path $script:InstallRoot 'Users'
    $script:StateFile = Join-Path $script:ConfigRoot 'sessions.json'
    $script:DownloadCacheRoot = Join-Path $script:ConfigRoot 'Downloads'
    $script:RdpFileCacheRoot = Join-Path $script:ConfigRoot 'RdpFiles'
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

function Invoke-DashboardUiPump {
    <#
        Connect-DashboardRdp's wait for the RDP session to come up runs
        directly on Dashboard.ps1's WinForms UI thread, since its button
        click handlers call straight into it -- so without pumping the
        message loop during the wait, the whole window stops repainting and
        Windows reports it as "Not Responding" for the duration. Calling
        this once per polling iteration keeps it responsive.

        Resolved by string (not a literal [System.Windows.Forms.Application]
        type reference) so this is a safe no-op when that assembly isn't
        loaded, e.g. when this module is used from the non-interactive
        installer, which never loads WinForms.
    #>
    $appType = 'System.Windows.Forms.Application' -as [type]
    if ($appType) { $appType::DoEvents() }
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
        Write-Host "Using cached download for ${CacheName}: $cachePath"
        return $Destination
    }

    $partial = "$cachePath.partial"
    try {
        if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force }
        Write-Host "Downloading ${CacheName} from $Uri"
        Invoke-WebRequest -Uri $Uri -OutFile $partial -UseBasicParsing
        if (-not (Test-UsableDownload -Path $partial)) { throw "Downloaded file is empty: $Uri" }
        Move-Item -LiteralPath $partial -Destination $cachePath -Force
        Copy-Item -LiteralPath $cachePath -Destination $Destination -Force
        return $Destination
    } catch {
        if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue }
        if (Test-UsableDownload -Path $cachePath) {
            Write-Warning "Download failed for ${CacheName}; using cached copy at $cachePath. Error: $($_.Exception.Message)"
            Copy-Item -LiteralPath $cachePath -Destination $Destination -Force
            return $Destination
        }
        throw "Download failed for ${CacheName} from $Uri and no cached copy is available. Place the file in '$cachePath' or re-run when the network is available. Error: $($_.Exception.Message)"
    }
}

function Expand-ArchiveSafe {
    param([Parameter(Mandatory)][string]$Archive, [Parameter(Mandatory)][string]$Destination)
    if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Recurse -Force }
    New-DirectoryIfMissing -Path $Destination
    Expand-Archive -Path $Archive -DestinationPath $Destination -Force
}


function Invoke-RdpWrapperInstaller {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [string[]]$ArgumentList = @(),
        [int]$TimeoutSeconds = 600
    )

    $startParameters = @{
        FilePath = $FilePath
        WorkingDirectory = $WorkingDirectory
        PassThru = $true
        Wait = ($TimeoutSeconds -le 0)
    }
    if ($ArgumentList.Count -gt 0) { $startParameters.ArgumentList = $ArgumentList }

    Write-Host "Starting RDP Wrapper installer: $FilePath"
    if ($ArgumentList.Count -gt 0) { Write-Host "RDP Wrapper installer arguments: $($ArgumentList -join ' ')" }
    else { Write-Host 'RDP Wrapper installer arguments: <none; interactive/default installer mode>' }

    $process = Start-Process @startParameters
    if ($TimeoutSeconds -gt 0 -and -not $process.WaitForExit($TimeoutSeconds * 1000)) {
        $process.Kill()
        throw "RDP Wrapper installer did not finish within $TimeoutSeconds seconds. The upstream console install command is '-install'; use -RdpWrapperInstallTimeoutSeconds to adjust the wait or -RdpWrapperInstallArguments to override."
    }

    if ($process.ExitCode -ne 0) {
        throw "RDP Wrapper installer exited with code $($process.ExitCode). The upstream source supports '-install' for console installation; override with -RdpWrapperInstallArguments only if this release changes."
    }
}

function Install-RdpWrapper {
    <#
        By default resolves the latest release through the GitHub API rather
        than only ever downloading the static '.../releases/latest/download/
        <fixed filename>' URL. That URL's text -- and the asset's filename --
        never changes between releases, so a download cache keyed on it
        alone can never tell a stale cached copy apart from a newer release;
        the cache name below is keyed on the resolved release tag instead,
        so normal caching correctly reuses a hit for an unchanged release
        and correctly re-downloads when a new one is published -- no need to
        force-wipe the whole download cache to pick up updates.

        Pass -Source to bypass API resolution entirely and download a
        specific URL directly (kept for advanced/offline-mirror use).
    #>
    param(
        [string]$Source,
        [string]$ReleaseApiUri = 'https://api.github.com/repos/sergiye/rdpWrapper/releases/latest',
        [string[]]$AssetNamePatterns = @('(?i)^rdpWrapper_x64\.exe$', '(?i)^rdpWrapper.*x64.*\.exe$', '(?i)^rdpWrapper.*\.zip$'),
        [string[]]$InstallArguments = @('-install'),
        [int]$InstallTimeoutSeconds = 600
    )
    New-DirectoryIfMissing -Path $script:RdpWrapperRoot

    $downloadUri = $Source
    $cacheName = 'rdpWrapper'
    if ([string]::IsNullOrWhiteSpace($downloadUri)) {
        $asset = Resolve-GitHubLatestReleaseAsset -ReleaseApiUri $ReleaseApiUri -AssetNamePatterns $AssetNamePatterns -ComponentName 'RDP Wrapper'
        $downloadUri = $asset.Uri
        $cacheName = "rdpWrapper-$($asset.Release)"
    }

    $extension = [IO.Path]::GetExtension(([Uri]$downloadUri).AbsolutePath)
    if ([string]::IsNullOrWhiteSpace($extension)) { $extension = '.download' }
    $package = Join-Path $env:TEMP "rdpWrapper$extension"
    Invoke-DownloadFile -Uri $downloadUri -Destination $package -CacheName $cacheName | Out-Null

    if ($extension -ieq '.zip') {
        Expand-ArchiveSafe -Archive $package -Destination $script:RdpWrapperRoot
        $install = Get-ChildItem -LiteralPath $script:RdpWrapperRoot -Recurse -Filter 'install.bat' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($install) {
            Invoke-RdpWrapperInstaller -FilePath $install.FullName -WorkingDirectory $install.DirectoryName -ArgumentList $InstallArguments -TimeoutSeconds $InstallTimeoutSeconds
        }
    } elseif ($extension -ieq '.exe') {
        $installer = Join-Path $script:RdpWrapperRoot 'rdpWrapper_x64.exe'
        Copy-Item -LiteralPath $package -Destination $installer -Force
        Invoke-RdpWrapperInstaller -FilePath $installer -WorkingDirectory $script:RdpWrapperRoot -ArgumentList $InstallArguments -TimeoutSeconds $InstallTimeoutSeconds
    } else {
        throw "Unsupported RDP Wrapper package type '$extension' from $downloadUri"
    }

    Set-RdpWrapperConfiguration
    $result = Test-RdpWrapperConfiguration
    if (-not $result.Success) { throw "RDP Wrapper verification failed: $($result.Failures -join ', ')" }
}


function Install-RemoteDesktopPlus {
    <#
        Installs Remote Desktop Plus (RDP+), the mstsc wrapper used to launch
        fully automated RDP logins for dashboard-managed accounts. Unlike
        mstsc.exe, rdp.exe accepts the password on the command line, so the
        login never depends on a saved Windows Credential Manager entry.
    #>
    param(
        [string]$Source = 'https://www.donkz.nl/download/remote-desktop-plus-msi/',
        [int]$InstallTimeoutSeconds = 300
    )

    $msi = Join-Path $env:TEMP 'RemoteDesktopPlus.msi'
    Invoke-DownloadFile -Uri $Source -Destination $msi -CacheName 'remoteDesktopPlus' | Out-Null

    $logFile = Join-Path $env:TEMP 'RemoteDesktopPlus-install.log'
    $arguments = @('/i', "`"$msi`"", '/quiet', '/qn', '/norestart', '/log', "`"$logFile`"")

    Write-Host 'Installing Remote Desktop Plus...'
    $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList $arguments -PassThru
    if (-not $process.WaitForExit($InstallTimeoutSeconds * 1000)) {
        $process.Kill()
        throw "Remote Desktop Plus installer did not finish within $InstallTimeoutSeconds seconds."
    }
    # 3010 = success, reboot required; treat it as success like the RDP Wrapper installer does.
    if ($process.ExitCode -ne 0 -and $process.ExitCode -ne 3010) {
        throw "Remote Desktop Plus MSI install failed with exit code $($process.ExitCode). See log at '$logFile'."
    }

    if (-not (Test-Path -LiteralPath $script:RdpPlusPath)) {
        throw "Remote Desktop Plus installer completed but rdp.exe was not found at '$script:RdpPlusPath'."
    }
}

function Resolve-RemoteDesktopPlusPath {
    <#
        Confirms rdp.exe's location rather than only ever assuming the
        hard-coded install path: if it isn't there (a different MSI version,
        a manual install), search both Program Files roots for it and cache
        whatever is found for the rest of this session.
    #>
    if (Test-Path -LiteralPath $script:RdpPlusPath) { return $script:RdpPlusPath }

    $roots = @('C:\Program Files (x86)', 'C:\Program Files') | Where-Object { Test-Path -LiteralPath $_ }
    foreach ($root in $roots) {
        $found = Get-ChildItem -LiteralPath $root -Filter 'rdp.exe' -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.DirectoryName -like '*Remote Desktop Plus*' } |
            Select-Object -First 1
        if ($found) {
            $script:RdpPlusPath = $found.FullName
            return $script:RdpPlusPath
        }
    }

    return $script:RdpPlusPath
}


function Enable-RemoteDesktopFirewallRules {
    $rules = Get-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction SilentlyContinue
    if ($rules) {
        $rules | Enable-NetFirewallRule -ErrorAction SilentlyContinue | Out-Null
        return
    }

    $legacyGroups = @(
        '@FirewallAPI.dll,-28752',
        'Remote Desktop'
    )
    foreach ($group in $legacyGroups) {
        netsh advfirewall firewall set rule group=$group new enable=Yes | Out-Null
    }
}

function Set-RdpWrapperConfiguration {
    New-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -Value 0 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name 'AllowRemoteRPC' -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path 'HKLM:\Software\Policies\Microsoft\Windows NT\Terminal Services' -Name 'Shadow' -Value 2 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path 'HKLM:\Software\Microsoft\Terminal Server Client' -Name 'AuthenticationLevelOverride' -Value 0 -PropertyType DWord -Force | Out-Null
    Enable-RemoteDesktopFirewallRules

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
    if ($ini -and ((Get-Content -LiteralPath $ini.FullName -Raw) -notmatch '(?im)^PreferredWrapper=TermWrap$')) { $failures.Add('TermWrap configured') }
    [pscustomobject]@{ Success = $failures.Count -eq 0; Failures = $failures }
}


function Resolve-GitHubLatestReleaseAsset {
    param(
        [Parameter(Mandatory)][string]$ReleaseApiUri,
        [Parameter(Mandatory)][string[]]$AssetNamePatterns,
        [Parameter(Mandatory)][string]$ComponentName
    )

    Write-Host "Querying latest $ComponentName release: $ReleaseApiUri"
    $release = Invoke-RestMethod -Uri $ReleaseApiUri -UseBasicParsing -Headers @{ 'User-Agent' = 'Muti-Session-Dashboard-Installer' }
    if (-not $release.assets) { throw "No assets were returned by $ReleaseApiUri for $ComponentName." }

    foreach ($pattern in $AssetNamePatterns) {
        $asset = @($release.assets | Where-Object { $_.name -match $pattern } | Sort-Object -Property name | Select-Object -First 1)
        if ($asset.Count -gt 0) {
            $selected = $asset[0]
            Write-Host "Selected $ComponentName asset '$($selected.name)' from release '$($release.tag_name)'."
            return [pscustomobject]@{
                Name = $selected.name
                Uri = $selected.browser_download_url
                Release = $release.tag_name
            }
        }
    }

    $available = ($release.assets | ForEach-Object { $_.name }) -join ', '
    throw "Could not find a $ComponentName release asset matching patterns: $($AssetNamePatterns -join ', '). Available assets: $available"
}

function Get-RemoteDesktopUsers {
    <#
        Returns direct members of the local "Remote Desktop Users" group.
        Uses Get-LocalGroupMember when available and falls back to the
        built-in Windows WinNT provider so detection works without the
        LocalAccounts PowerShell module.
    #>
    $members = [System.Collections.Generic.List[object]]::new()
    $cmd = Get-Command -Name Get-LocalGroupMember -ErrorAction SilentlyContinue

    if ($null -ne $cmd) {
        try {
            foreach ($member in @(Get-LocalGroupMember -Group 'Remote Desktop Users' -ErrorAction Stop)) {
                $accountName = [string]$member.Name
                if ([string]::IsNullOrWhiteSpace($accountName)) { continue }

                $displayName = $accountName
                if ($displayName -match '^[^\\]+\\(.+)$') { $displayName = $matches[1] }

                $members.Add([pscustomobject]@{
                    Username        = $displayName
                    AccountName     = $accountName
                    PrincipalSource = [string]$member.PrincipalSource
                    ObjectClass     = [string]$member.ObjectClass
                })
            }
            return @($members | Sort-Object Username, AccountName -Unique)
        }
        catch {
            Write-Verbose "Get-LocalGroupMember failed; falling back to WinNT provider. $($_.Exception.Message)"
        }
    }

    try {
        $group = [ADSI]'WinNT://./Remote Desktop Users,group'
        foreach ($member in @($group.psbase.Invoke('Members'))) {
            try {
                $accountName = [string]$member.GetType().InvokeMember(
                    'Name', [System.Reflection.BindingFlags]::GetProperty, $null, $member, $null)

                if ([string]::IsNullOrWhiteSpace($accountName)) { continue }

                $className = ''
                $adsPath = ''
                try {
                    $className = [string]$member.GetType().InvokeMember(
                        'Class', [System.Reflection.BindingFlags]::GetProperty, $null, $member, $null)
                } catch {}
                try {
                    $adsPath = [string]$member.GetType().InvokeMember(
                        'ADsPath', [System.Reflection.BindingFlags]::GetProperty, $null, $member, $null)
                } catch {}

                $displayName = $accountName
                $qualifiedName = $accountName

                if ($adsPath -match '^WinNT://([^/]+)/(.+)$') {
                    $displayName = $matches[2]
                    $qualifiedName = "$($matches[1])\$($matches[2])"
                }

                $source = 'Unknown'
                if ($qualifiedName -match '^([^\\]+)\\') { $source = $matches[1] }

                $members.Add([pscustomobject]@{
                    Username        = $displayName
                    AccountName     = $qualifiedName
                    PrincipalSource = $source
                    ObjectClass     = $className
                })
            }
            catch {
                Write-Verbose "Could not read one Remote Desktop Users member: $($_.Exception.Message)"
            }
        }
    }
    catch {
        throw "Could not read members of the local 'Remote Desktop Users' group. $($_.Exception.Message)"
    }

    return @($members | Sort-Object Username, AccountName -Unique)
}

function Get-DashboardUsers {
    # Sync dashboard state with the current Remote Desktop Users group.
    $state = Get-DashboardState
    $users = @(Get-RemoteDesktopUsers)

    foreach ($user in $users) {
        if (-not $state.ContainsKey($user.Username)) {
            $state[$user.Username] = Get-DefaultDashboardStateEntry -Username $user.Username -AccountName $user.AccountName
        } else {
            $state[$user.Username].Username = $user.Username
            $state[$user.Username].AccountName = $user.AccountName
        }
    }

    Save-DashboardState -State $state
    return $users
}

function Get-RdpEndpoint {
    return "$($script:RdpHost):$($script:RdpPort)"
}

function Add-DashboardWtsApiType {
    <#
        Registers the Win32 WTS (Windows Terminal Services) session
        enumeration API via P/Invoke. Get-AllUserSessions prefers this over
        parsing quser's fixed-width text output: quser has been observed to
        report a session that is genuinely Active (confirmed independently
        via `query session`) as not found at all when its column layout
        doesn't match the parsing regex exactly for that Windows build, or
        when it is invoked without a real attached console (as happens when
        PowerShell is launched non-interactively, e.g. from a GUI process).
        WTSEnumerateSessions/WTSQuerySessionInformation is the same API
        `quser`/`query session` themselves call internally, without the text
        round-trip that makes parsing fragile.
    #>
    if ('BetterRdp.Wts' -as [type]) { return }
    Add-Type -Namespace BetterRdp -Name Wts -MemberDefinition @'
[DllImport("wtsapi32.dll", SetLastError = true)]
public static extern IntPtr WTSOpenServer(string pServerName);

[DllImport("wtsapi32.dll")]
public static extern void WTSCloseServer(IntPtr hServer);

[DllImport("wtsapi32.dll", SetLastError = true)]
public static extern bool WTSEnumerateSessions(IntPtr hServer, int Reserved, int Version, out IntPtr ppSessionInfo, out int pCount);

[DllImport("wtsapi32.dll")]
public static extern void WTSFreeMemory(IntPtr pMemory);

[DllImport("wtsapi32.dll", SetLastError = true)]
public static extern bool WTSQuerySessionInformation(IntPtr hServer, int sessionId, int wtsInfoClass, out IntPtr ppBuffer, out int pBytesReturned);

[StructLayout(LayoutKind.Sequential)]
public struct WTS_SESSION_INFO {
    public int SessionId;
    [MarshalAs(UnmanagedType.LPStr)]
    public string pWinStationName;
    public int State;
}
'@ -UsingNamespace 'System.Runtime.InteropServices'
}

function Get-AllUserSessions {
    <#
        Enumerates every Terminal Services session on this machine (all
        users, not just one) via the WTS API -- the primary, reliable
        source Get-UserSessions filters against. Falls back to parsing
        `quser` text output only if the WTS call itself fails outright
        (e.g. wtsapi32.dll unavailable), since a fragile text parse is
        still better than no data at all.
    #>
    $results = [System.Collections.Generic.List[object]]::new()
    try {
        Add-DashboardWtsApiType
        $server = [IntPtr]::Zero  # local server
        $sessionInfoPtr = [IntPtr]::Zero
        $count = 0
        $ok = [BetterRdp.Wts]::WTSEnumerateSessions($server, 0, 1, [ref]$sessionInfoPtr, [ref]$count)
        if (-not $ok) { throw "WTSEnumerateSessions failed (Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))." }

        try {
            $structSize = [Runtime.InteropServices.Marshal]::SizeOf([type]'BetterRdp.Wts+WTS_SESSION_INFO')
            for ($i = 0; $i -lt $count; $i++) {
                $current = [IntPtr]::Add($sessionInfoPtr, $i * $structSize)
                $info = [Runtime.InteropServices.Marshal]::PtrToStructure($current, [type]'BetterRdp.Wts+WTS_SESSION_INFO')

                # WTSUserName = 5, WTSConnectState is already on $info.State
                $userPtr = [IntPtr]::Zero; $userBytes = 0
                $username = ''
                if ([BetterRdp.Wts]::WTSQuerySessionInformation($server, $info.SessionId, 5, [ref]$userPtr, [ref]$userBytes)) {
                    try { $username = [Runtime.InteropServices.Marshal]::PtrToStringAnsi($userPtr) }
                    finally { [BetterRdp.Wts]::WTSFreeMemory($userPtr) }
                }
                if ([string]::IsNullOrWhiteSpace($username)) { continue }

                # WTS_CONNECTSTATE_CLASS: 0=Active 1=Connected 2=ConnectQuery
                # 3=Shadow 4=Disconnected 5=Idle 6=Listen 7=Reset 8=Down 9=Init
                $stateName = switch ($info.State) {
                    0 { 'Active' }
                    1 { 'Connected' }
                    4 { 'Disc' }
                    5 { 'Idle' }
                    default { 'Other' }
                }
                $sessionName = [string]$info.pWinStationName

                $results.Add([pscustomobject]@{
                    Username    = $username
                    SessionId   = $info.SessionId
                    SessionName = $sessionName
                    State       = $stateName
                    Online      = ($info.State -eq 0 -or $info.State -eq 1)
                    IsRdp       = ($sessionName -like 'RDP-Tcp*')
                    IsConsole   = ($sessionName -ieq 'Console')
                })
            }
        } finally {
            if ($sessionInfoPtr -ne [IntPtr]::Zero) { [BetterRdp.Wts]::WTSFreeMemory($sessionInfoPtr) }
        }
        return @($results)
    } catch {
        Write-Verbose "WTS session enumeration failed; falling back to quser text parsing. $($_.Exception.Message)"
    }

    # Fallback: parse `quser`'s fixed-width text output. Kept only as a
    # last resort -- see Add-DashboardWtsApiType's comment for why this is
    # not the primary path.
    foreach ($line in @(quser 2>$null)) {
        $text = [string]$line
        if ($text -match '^\s*>?\s*(\S+)(?:\s+(\S+))?\s+(\d+)\s+(\S+)') {
            $user = $matches[1]; $sessionName = if ($matches[2] -match '^rdp-tcp|^console$') { $matches[2] } else { '' }; $id = [int]$matches[3]; $state = $matches[4]
            $results.Add([pscustomobject]@{ Username=$user; SessionId=$id; SessionName=$sessionName; State=$state; Online=($state -match '^(Active|Conn)$'); IsRdp=($sessionName -like 'rdp-tcp*'); IsConsole=($sessionName -ieq 'console') })
        }
    }
    return @($results)
}

function Get-UserSessions {
    param([Parameter(Mandatory)][string]$Username)
    return @(Get-AllUserSessions | Where-Object { $_.Username -ieq $Username })
}

function Get-UserSession {
    param([Parameter(Mandatory)][string]$Username)
    $sessions = @(Get-UserSessions -Username $Username)
    if ($sessions.Count -eq 0) { return $null }
    $console = $sessions | Where-Object { $_.IsConsole -and $_.Online } | Select-Object -First 1
    if ($null -ne $console) { return $console }
    $active = $sessions | Where-Object { $_.Online } | Select-Object -First 1
    if ($null -ne $active) { return $active }
    return ($sessions | Select-Object -First 1)
}

function Get-UserRdpSessionId {
    param([Parameter(Mandatory)][string]$Username)
    return @(Get-UserSessions -Username $Username | Where-Object { $_.IsRdp } | Sort-Object SessionId | Select-Object -First 1)
}

function Wait-DashboardRdpSession {
    param([Parameter(Mandatory)][string]$Username,[int]$TimeoutSeconds=30,[int[]]$IgnoreSessionIds=@())
    $deadline=(Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $session=@(Get-UserSessions -Username $Username | Where-Object { $_.IsRdp -and $_.State -match '^(Active|Conn)$' -and ($IgnoreSessionIds -notcontains $_.SessionId) } | Sort-Object SessionId | Select-Object -First 1)
        if ($null -ne $session -and @($session).Count -gt 0) { return $session[0] }
        Invoke-DashboardUiPump
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    return $null
}

function New-DashboardRdpFile {
    <#
        Remote Desktop Plus (rdp.exe) accepts an .rdp settings file as a
        positional argument alongside its own /u: /p: overrides, so any
        setting normally only available in an .rdp file -- like
        "smart sizing:i:1" -- goes here instead of trying to invent a
        CLI flag for it that rdp.exe doesn't have.
    #>
    param([Parameter(Mandatory)][string]$Username)

    New-DirectoryIfMissing -Path $script:RdpFileCacheRoot
    $path = Join-Path $script:RdpFileCacheRoot "$Username.rdp"
    $lines = @(
        "full address:s:$($script:RdpHost):$($script:RdpPort)"
        "username:s:.\$Username"
        'smart sizing:i:1'
        'desktopwidth:i:1920'
        'desktopheight:i:1080'
        'screen mode id:i:1'
        'authentication level:i:0'
        'prompt for credentials:i:0'
        'enablecredsspsupport:i:1'
    )
    Set-Content -LiteralPath $path -Value $lines -Encoding ASCII
    return $path
}

function Invoke-DashboardRdpBootstrap {
    <#
        Launches a fully automated RDP login for a dashboard-managed account
        via Remote Desktop Plus. Connecting to the SAME endpoint for a user
        who already has a disconnected session reconnects it -- standard RDP
        behavior -- so this doubles as both a fresh connect and any later
        reconnect.

        -Minimize is used by Start-DashboardHeadlessLoopback to arm a
        background/anchor connection that keeps the session alive without
        an RDP window sitting in the operator's way; a later interactive
        Connect-DashboardRdp call reconnects the same session with a new,
        visible client, which displaces (disconnects) the minimized one
        automatically -- standard RDP behavior, not something this script
        has to orchestrate itself.
    #>
    param([Parameter(Mandatory)][string]$Username, [switch]$Minimize)

    Assert-Administrator
    $rdpPlusPath = Resolve-RemoteDesktopPlusPath
    if (-not (Test-Path -LiteralPath $rdpPlusPath)) {
        throw "Remote Desktop Plus was not found at '$rdpPlusPath'. Re-run the installer to install it."
    }

    # Dashboard-managed local accounts always use the username as the Windows
    # account password (see New-DashboardUser), so the login is passed
    # explicitly and completes with no saved-credential prompt to click
    # through. The generated .rdp file carries settings (like smart sizing)
    # that have no dedicated rdp.exe CLI flag; /u: and /p: are still passed
    # on the command line since a plaintext password can't be stored in the
    # .rdp file itself.
    $rdpFile = New-DashboardRdpFile -Username $Username
    $arguments = @(
        "`"$rdpFile`"",
        "/u:.\$Username",
        "/p:$Username"
    )

    Write-Host "Starting Remote Desktop Plus for '$Username' at 1920x1080."
    $process = Start-Process -FilePath $rdpPlusPath -ArgumentList $arguments -PassThru

    # 45s, not 30s: a first-ever logon (profile creation, GPU/driver init)
    # can genuinely take longer than 30s.
    $session = Wait-DashboardRdpSession -Username $Username -TimeoutSeconds 45
    if ($null -eq $session) {
        throw "RDP login for '$Username' did not produce an active RDP session within 45 seconds. Run 'query session' to check whether it actually connected -- if it shows Active, this is a detection issue rather than a failed login."
    }

    if ($Minimize) { Set-DashboardWindowMinimized -ProcessId $process.Id }

    return [pscustomobject]@{
        Username  = $session.Username
        SessionId = $session.SessionId
        ProcessId = $process.Id
    }
}

function Set-DashboardWindowMinimized {
    <#
        Best-effort minimize of an rdp.exe process's main window, used to
        keep an "armed" headless loopback connection out of the operator's
        way. A brand-new process's main window handle isn't available
        immediately, so this polls briefly for it. Failure here is
        non-fatal -- the RDP session itself is what matters; a window that
        couldn't be minimized is just a cosmetic miss.
    #>
    param([Parameter(Mandatory)][int]$ProcessId, [int]$TimeoutSeconds = 10)

    if (-not ('BetterRdp.Window' -as [type])) {
        Add-Type -Namespace BetterRdp -Name Window -MemberDefinition @'
[DllImport("user32.dll")]
public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'@ -UsingNamespace 'System.Runtime.InteropServices'
    }
    $SW_MINIMIZE = 6

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        try {
            $proc = Get-Process -Id $ProcessId -ErrorAction Stop
            $proc.Refresh()
            if ($proc.MainWindowHandle -ne [IntPtr]::Zero) {
                [BetterRdp.Window]::ShowWindow($proc.MainWindowHandle, $SW_MINIMIZE) | Out-Null
                return
            }
        } catch {
            return
        }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
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

function Get-DefaultDashboardStateEntry {
    <#
        The single source of truth for a state entry's full key set. Used
        both for brand-new entries and by Repair-DashboardStateEntry to
        back-fill entries loaded from an older sessions.json -- keeping the
        shape in one place instead of duplicating a hashtable literal at
        every call site.
    #>
    param([Parameter(Mandatory)][string]$Username, [string]$AccountName)
    if ([string]::IsNullOrWhiteSpace($AccountName)) { $AccountName = ".\$Username" }
    return @{
        Username = $Username
        AccountName = $AccountName
        SessionState = 'Stopped'
        RdpSessionId = $null
        RdpConnectionStatus = 'Disconnected'
        # Headless RDP Loopback: Start arms a background/anchor RDP
        # connection to keep the session alive and ready; Connect launches
        # a visible interactive connection that displaces it (standard RDP
        # behavior -- reconnecting the same session disconnects the prior
        # client). HeadlessArmed/HeadlessProcessId track that background
        # connection so it can be re-armed automatically after the
        # interactive client disconnects, and torn down cleanly on Stop.
        HeadlessArmed = $false
        HeadlessProcessId = $null
        # Set by Stop-DashboardSession, cleared by Start/Connect. Tells the
        # dashboard's auto re-arm monitor "the operator asked for this user
        # to be stopped" so a session going offline after an explicit Stop
        # stays stopped instead of being re-armed headless again.
        StopRequested = $false
    }
}

function Repair-DashboardStateEntry {
    <#
        Set-StrictMode -Version Latest throws "property ... cannot be found"
        on dot-access to a hashtable key that simply isn't there -- so an
        entry written by an older version of this module crashes the first
        time anything reads it that way. Back-fill any missing keys with
        their default value so every entry always has the full current
        shape, regardless of when it was first created. Fields from a
        previous schema (e.g. the old Sunshine-related keys) are left in
        place, just unused -- nothing here strips them.
    #>
    param([Parameter(Mandatory)][hashtable]$Entry, [Parameter(Mandatory)][string]$Username)
    $accountName = if ($Entry.ContainsKey('AccountName')) { $Entry['AccountName'] } else { $null }
    $defaults = Get-DefaultDashboardStateEntry -Username $Username -AccountName $accountName
    foreach ($key in $defaults.Keys) {
        if (-not $Entry.ContainsKey($key)) { $Entry[$key] = $defaults[$key] }
    }
    return $Entry
}

function Get-DashboardState {
    New-DirectoryIfMissing -Path $script:ConfigRoot
    if (-not (Test-Path -LiteralPath $script:StateFile)) { return @{} }
    $json = Get-Content -LiteralPath $script:StateFile -Raw
    if ([string]::IsNullOrWhiteSpace($json)) { return @{} }
    $obj = $json | ConvertFrom-Json
    $state = ConvertTo-HashtableRecursive $obj
    foreach ($username in @($state.Keys)) {
        $state[$username] = Repair-DashboardStateEntry -Entry $state[$username] -Username $username
    }
    return $state
}

function Save-DashboardState { param([hashtable]$State) $State | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:StateFile -Encoding UTF8 }

function New-DashboardUser {
    <#
        Dashboard-managed accounts always get the username as their Windows
        account password. Connect-DashboardRdp depends on this: it passes
        /p:$Username to Remote Desktop Plus for a fully automated login, so
        the account's real password must match. If -Password is supplied
        and differs from -Username, the account is still created with that
        password, but automated RDP login for it will fail until the
        password is reset to match the username.
    #>
    param([Parameter(Mandatory)][string]$Username, [string]$Password)
    Assert-Administrator
    if ([string]::IsNullOrEmpty($Password)) { $Password = $Username }
    if ($Password -ne $Username) {
        Write-Warning "'$Username' is being created with a password that does not match the username. Connect RDP auto sign-in requires the account password to equal the username; automated RDP login will fail until it is reset to match."
    }

    net user $Username $Password /add | Out-Null
    net localgroup 'Remote Desktop Users' $Username /add | Out-Null

    $userRoot = Join-Path $script:UsersRoot $Username
    New-DirectoryIfMissing -Path $userRoot
}

function Assert-DashboardConnectPreconditions {
    param([Parameter(Mandatory)][string]$Username)
    $knownUsers = @(Get-RemoteDesktopUsers | ForEach-Object { $_.Username })
    if ($knownUsers -notcontains $Username) {
        throw "'$Username' is not a member of the local 'Remote Desktop Users' group."
    }
    $wrapperCheck = Test-RdpWrapperConfiguration
    if (-not $wrapperCheck.Success) {
        throw "RDP Wrapper is not correctly configured: $($wrapperCheck.Failures -join ', ')"
    }
}

function Stop-DashboardHeadlessLoopback {
    <#
        Kills a still-running headless loopback rdp.exe process for this
        user, if any, and clears the tracking fields. Safe to call even if
        nothing is armed. Does not sign the underlying Windows session off
        -- that stays alive across headless -> interactive handoffs; only
        Stop-DashboardSession does that.
    #>
    param([Parameter(Mandatory)][string]$Username, [hashtable]$State)

    $ownState = $false
    if ($null -eq $State) { $State = Get-DashboardState; $ownState = $true }
    if ($State.ContainsKey($Username)) {
        $entry = $State[$Username]
        if ($entry.HeadlessArmed -and $entry.HeadlessProcessId) {
            try {
                $proc = Get-Process -Id ([int]$entry.HeadlessProcessId) -ErrorAction SilentlyContinue
                if ($proc -and -not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
            } catch {}
        }
        $entry.HeadlessArmed = $false
        $entry.HeadlessProcessId = $null
    }
    if ($ownState) { Save-DashboardState -State $State }
}

function Start-DashboardHeadlessLoopback {
    <#
        Arms a background/anchor RDP connection for this user: the same
        automated login as Connect-DashboardRdp, but launched minimized so
        it never shows an RDP window on the operator's desktop. This is the
        "Start" step in the Headless RDP Loopback flow -- it exists to keep
        the user's session alive and ready ("HEADLESS READY"), not to be
        looked at. A later Connect-DashboardRdp call reconnects the same
        session with a real, visible client, which displaces this one
        automatically (standard RDP behavior).
    #>
    param([Parameter(Mandatory)][string]$Username)
    Assert-Administrator
    Assert-DashboardConnectPreconditions -Username $Username

    $rdp = Invoke-DashboardRdpBootstrap -Username $Username -Minimize

    $state = Get-DashboardState
    if ($state.ContainsKey($Username)) {
        $state[$Username].RdpSessionId = $rdp.SessionId
        $state[$Username].RdpConnectionStatus = 'Headless'
        $state[$Username].SessionState = 'Armed'
        $state[$Username].HeadlessArmed = $true
        $state[$Username].HeadlessProcessId = $rdp.ProcessId
        $state[$Username].StopRequested = $false
        Save-DashboardState -State $state
    }
    return $rdp
}

function Connect-DashboardRdp {
    <#
        Launches (or reconnects) the selected user's RDP session as a real,
        visible, interactive client. If a headless loopback connection was
        armed for this user, connecting again to the same session displaces
        it automatically -- standard RDP behavior, reconnecting to an
        existing session disconnects whichever client held it before. The
        stale headless rdp.exe window (if it didn't already close on its
        own) is cleaned up afterward.
    #>
    param([Parameter(Mandatory)][string]$Username)
    Assert-Administrator
    Assert-DashboardConnectPreconditions -Username $Username

    $wasHeadless = $false
    $state = Get-DashboardState
    if ($state.ContainsKey($Username)) { $wasHeadless = [bool]$state[$Username].HeadlessArmed }

    $rdp = Invoke-DashboardRdpBootstrap -Username $Username

    $state = Get-DashboardState
    if ($state.ContainsKey($Username)) {
        if ($wasHeadless) { Stop-DashboardHeadlessLoopback -Username $Username -State $state }
        $state[$Username].RdpSessionId = $rdp.SessionId
        $state[$Username].RdpConnectionStatus = 'Connected'
        $state[$Username].SessionState = 'Running'
        $state[$Username].StopRequested = $false
        Save-DashboardState -State $state
    }
    return $rdp
}

function Stop-DashboardSession {
    <#
        Sign the user off, and tear down any armed headless loopback
        connection along with it.
    #>
    param([Parameter(Mandatory)][string]$Username)
    $session = Get-UserSession -Username $Username
    if ($null -ne $session) { logoff $session.SessionId 2>$null }

    $state = Get-DashboardState
    Stop-DashboardHeadlessLoopback -Username $Username -State $state
    if ($state.ContainsKey($Username)) {
        $state[$Username].SessionState = 'Stopped'
        $state[$Username].RdpConnectionStatus = 'Disconnected'
        $state[$Username].StopRequested = $true
    }
    Save-DashboardState -State $state
}

function Open-DashboardRdpWrapperManager {
    <#
        Launches the RDP Wrapper manager/config UI directly, for manual
        inspection or reconfiguration outside the dashboard's own
        install/verify flow.
    #>
    param([string]$Path = $script:RdpWrapperManagerPath)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "RDP Wrapper manager was not found at '$Path'."
    }
    Start-Process -FilePath $Path | Out-Null
}

function Test-DashboardInstallation {
    $checks = [ordered]@{
        'RDP Wrapper installed' = (Test-Path -LiteralPath $script:RdpWrapperRoot)
        'TermWrap configured' = (Test-RdpWrapperConfiguration).Success
        'Remote Desktop enabled' = (((Get-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -ErrorAction SilentlyContinue).fDenyTSConnections) -eq 0)
        'Remote Desktop Plus installed' = (Test-Path -LiteralPath (Resolve-RemoteDesktopPlusPath))
        'Dashboard installed' = (Test-Path -LiteralPath (Join-Path $script:InstallRoot 'Dashboard.ps1'))
    }
    $checks.GetEnumerator() | ForEach-Object { [pscustomobject]@{ Check=$_.Key; Passed=[bool]$_.Value } }
}

Export-ModuleMember -Function *-Dashboard*,Install-*,Test-*,New-DashboardUser,Stop-DashboardSession,Connect-DashboardRdp,Assert-Administrator,Set-DashboardPaths,Invoke-RdpWrapperInstaller,Get-RdpEndpoint,Get-DashboardState,Get-RemoteDesktopUsers,Get-UserSession,Get-UserSessions,Get-AllUserSessions,Get-UserRdpSessionId,Invoke-DashboardRdpBootstrap,Get-DefaultDashboardStateEntry,Open-DashboardRdpWrapperManager
