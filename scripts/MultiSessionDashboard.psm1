<#
    MultiSessionDashboard.psm1 -- kernel + public coordinator.

    This is the one module Dashboard.ps1 and Install-MultiSessionDashboard.ps1
    import. It owns:
      - Shared "kernel" functions every other module depends on: install
        paths, dashboard state persistence, admin/dir/download helpers, and
        RDP Wrapper install/verify.
      - Loading the four focused backend modules (SessionManager, UserManager,
        RdpManager, HeadlessManager) and gluing them into the handful of
        top-level workflows (Connect-DashboardRdp, Test-DashboardInstallation).
      - Start-DashboardBackgroundTask, the async-execution helper that keeps
        every slow operation (RDP launches, session waits, headless re-arm)
        off the WinForms UI thread.

    Every function in every one of this project's five backend files
    (this one, RdpManager.psm1, SessionManager.psm1, HeadlessManager.psm1,
    UserManager.psm1) is declared as `function global:Verb-Noun` instead of
    relying on PowerShell's normal per-module Export-ModuleMember/Import-Module
    scoping. This is a single WinForms desktop app that always loads every
    module into one shared runspace (or, for background work, one freshly
    Import-Module'd runspace per task) -- not a general-purpose reusable
    library -- so plain global functions are the simplest, most robust way
    to make every module's functions reliably callable from every other
    module without fighting module scope boundaries or juggling import
    order/circularity. The four backend modules are meant to be loaded
    through this coordinator (see the bottom of this file), not imported
    standalone.
#>

Set-StrictMode -Version Latest

$script:InstallRoot = 'C:\Program Files\Muti Session Dashboard'
$script:RdpWrapperRoot = 'C:\Program Files\RDP Wrapper'
$script:ConfigRoot = Join-Path $script:InstallRoot 'Config'
$script:UsersRoot = Join-Path $script:InstallRoot 'Users'
$script:StateFile = Join-Path $script:ConfigRoot 'sessions.json'
$script:DownloadCacheRoot = Join-Path $script:ConfigRoot 'Downloads'

function global:Set-DashboardPaths {
    param([Parameter(Mandatory)][string]$InstallRoot)
    $script:InstallRoot = $InstallRoot
    $script:ConfigRoot = Join-Path $script:InstallRoot 'Config'
    $script:UsersRoot = Join-Path $script:InstallRoot 'Users'
    $script:StateFile = Join-Path $script:ConfigRoot 'sessions.json'
    $script:DownloadCacheRoot = Join-Path $script:ConfigRoot 'Downloads'
    if (Get-Command -Name Set-RdpManagerPaths -ErrorAction SilentlyContinue) {
        Set-RdpManagerPaths -ConfigRoot $script:ConfigRoot
    }
}

function global:Get-DashboardInstallRoot { return $script:InstallRoot }
function global:Get-DashboardConfigRoot { return $script:ConfigRoot }
function global:Get-DashboardUsersRoot { return $script:UsersRoot }

function global:Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Multi Session Dashboard must be run from an elevated PowerShell session.'
    }
}

function global:New-DirectoryIfMissing {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function global:Invoke-DashboardUiPump {
    <#
        Historically used to keep the WinForms message loop alive during a
        blocking wait run directly on the UI thread. The dashboard no
        longer does that -- RDP launches, session waits, and headless
        re-arms all run on background runspaces now (see
        Start-DashboardBackgroundTask) and marshal UI updates back via
        Control.BeginInvoke instead. Kept only for backward compatibility /
        any future genuinely-UI-thread wait that wants it; resolved by
        string so it's a safe no-op when WinForms isn't loaded (e.g. from
        the non-interactive installer, or from a background runspace).
    #>
    $appType = 'System.Windows.Forms.Application' -as [type]
    if ($appType) { $appType::DoEvents() }
}

function global:Get-SafeCacheFileName {
    param([Parameter(Mandatory)][string]$Uri, [Parameter(Mandatory)][string]$Name)
    $extension = [IO.Path]::GetExtension(([Uri]$Uri).AbsolutePath)
    if ([string]::IsNullOrWhiteSpace($extension)) { $extension = '.download' }
    $hashInput = [Text.Encoding]::UTF8.GetBytes($Uri)
    $sha = [Security.Cryptography.SHA256]::Create()
    $hash = ([BitConverter]::ToString($sha.ComputeHash($hashInput))).Replace('-', '').Substring(0, 12).ToLowerInvariant()
    return "$Name-$hash$extension"
}

function global:Test-UsableDownload {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $item = Get-Item -LiteralPath $Path
    return ($item.Length -gt 0)
}

function global:Invoke-DownloadFile {
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

function global:Expand-ArchiveSafe {
    param([Parameter(Mandatory)][string]$Archive, [Parameter(Mandatory)][string]$Destination)
    if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Recurse -Force }
    New-DirectoryIfMissing -Path $Destination
    Expand-Archive -Path $Archive -DestinationPath $Destination -Force
}

function global:Invoke-RdpWrapperInstaller {
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

function global:Install-RdpWrapper {
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

function global:Enable-RemoteDesktopFirewallRules {
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

function global:Set-RdpWrapperConfiguration {
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

function global:Test-RdpWrapperConfiguration {
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

function global:Resolve-GitHubLatestReleaseAsset {
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

function global:ConvertTo-HashtableRecursive {
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

function global:Get-DefaultDashboardStateEntry {
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
        # Set by Update-DashboardMonitorState when an automatic re-arm
        # attempt throws, so the failure is visible in the dashboard grid
        # instead of only ever going to Write-Verbose (invisible by
        # default, and this all runs in a background runspace with no
        # console anyway). Cleared on the next successful arm/connect.
        LastHeadlessArmError = $null
    }
}

function global:Repair-DashboardStateEntry {
    <#
        Set-StrictMode -Version Latest throws "property ... cannot be found"
        on dot-access to a hashtable key that simply isn't there -- so an
        entry written by an older version of this module crashes the first
        time anything reads it that way. Back-fill any missing keys with
        their default value so every entry always has the full current
        shape, regardless of when it was first created. Fields from a
        previous schema are left in place, just unused -- nothing here
        strips them.
    #>
    param([Parameter(Mandatory)][hashtable]$Entry, [Parameter(Mandatory)][string]$Username)
    $accountName = if ($Entry.ContainsKey('AccountName')) { $Entry['AccountName'] } else { $null }
    $defaults = Get-DefaultDashboardStateEntry -Username $Username -AccountName $accountName
    foreach ($key in $defaults.Keys) {
        if (-not $Entry.ContainsKey($key)) { $Entry[$key] = $defaults[$key] }
    }
    return $Entry
}

function global:Get-DashboardState {
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

function global:Save-DashboardState { param([hashtable]$State) $State | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:StateFile -Encoding UTF8 }

function global:Connect-DashboardRdp {
    <#
        CONNECT workflow: launch (or reconnect) the selected user's RDP
        session as a real, visible, interactive client. If a headless
        loopback connection was armed for this user, connecting again to
        the same session displaces it automatically -- standard RDP
        behavior, reconnecting to an existing session disconnects whichever
        client held it before. The stale headless rdp.exe window (if it
        didn't already close on its own) is cleaned up afterward.

        The rest of the CONNECT workflow -- waiting for the interactive
        client to actually close and then re-arming a fresh headless
        loopback -- happens in Update-DashboardMonitorState, which already
        runs on its own background runspace on every monitor tick, so it
        naturally continues watching this session after this function
        returns without blocking anything here.

        Blocks for as long as Invoke-DashboardRdpBootstrap does, so this
        must always be run from a background runspace.
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
        $state[$Username].LastHeadlessArmError = $null
        Save-DashboardState -State $state
    }
    return $rdp
}

function global:Update-DashboardMonitorState {
    <#
        One full monitoring pass: refresh Remote Desktop Users membership,
        poll each member's real Windows session state (via the live WTS
        session ID, never a hard-coded one), and -- for any RDS user who is
        currently Disconnected, not already headless-armed, and hasn't been
        explicitly Stopped -- wait for their session to genuinely finish
        closing (a no-op wait if there's no session at all yet, e.g. a
        brand-new user) and re-arm their headless loopback right here. This
        keeps every RDS user "HEADLESS ready" by default at all times, not
        just users who were previously interactively connected -- Start is
        a manual "do it now" shortcut, not the only way a user ever gets
        armed.

        This entire function is meant to run inside the background
        runspace Start-DashboardBackgroundTask creates for it (see
        Dashboard.ps1's monitor timer), so the potentially multi-second
        wait-then-rearm never touches the UI thread. Returns the refreshed
        state as a hashtable for the caller to render.
    #>
    $state = Get-DashboardState
    $users = @(Get-RemoteDesktopUsers)

    foreach ($user in $users) {
        $key = [string]$user.Username
        if ([string]::IsNullOrWhiteSpace($key)) { continue }
        if (-not $state.ContainsKey($key)) {
            $state[$key] = Get-DefaultDashboardStateEntry -Username $key -AccountName $user.AccountName
        }
        $entry = $state[$key]

        try {
            $session = Get-UserSession -Username $key
            if ($null -eq $session) {
                $entry.RdpSessionId = $null
                $entry.RdpConnectionStatus = 'Disconnected'
                if ($entry.SessionState -ne 'Stopped') { $entry.SessionState = 'Stopped' }
            } else {
                $entry.RdpSessionId = $session.SessionId
                if ($session.Online) {
                    # A headless-armed entry whose session shows Online again
                    # with no interactive Connect having happened is just the
                    # loopback itself; keep it Armed/Headless rather than
                    # clobbering that state.
                    if (-not $entry.HeadlessArmed) {
                        $entry.RdpConnectionStatus = 'Connected'
                        $entry.SessionState = 'Running'
                    }
                } else {
                    $entry.RdpConnectionStatus = 'Disconnected'
                }
            }
        } catch {
            # Keep the monitor alive even if a single user's session
            # temporarily cannot be queried.
            $entry.RdpConnectionStatus = 'Error'
        }

        # Always-armed headless loopback: any RDS user sitting Disconnected
        # (whether they just went offline, were never started at all, or a
        # previous arm attempt failed) gets re-armed automatically, unless
        # the operator explicitly hit Stop. Self-limiting: Start-DashboardHeadlessLoopback
        # can block up to ~45s per attempt, and this whole function only
        # ever has one instance in flight at a time ($script:MonitorTaskInFlight
        # in Dashboard.ps1), so a persistently-failing arm retries roughly
        # every ~45s+, not every 2s tick.
        $needsArming = ($entry.RdpConnectionStatus -eq 'Disconnected' -and -not $entry.HeadlessArmed -and -not $entry.StopRequested)
        if ($needsArming) {
            try {
                Wait-DashboardSessionClosed -Username $key -TimeoutSeconds 10 | Out-Null
                Start-DashboardHeadlessLoopback -Username $key | Out-Null
                $fresh = Get-DashboardState
                if ($fresh.ContainsKey($key)) {
                    $state[$key] = $fresh[$key]
                    $state[$key].LastHeadlessArmError = $null
                }
            } catch {
                # Write-Verbose alone (the previous behavior here) is
                # invisible by default and this whole function runs in a
                # background runspace with no console anyone would see
                # anyway -- a silently-swallowed failure here is exactly
                # what made a real report ("auto-arm doesn't relaunch a new
                # RDP process") impossible to diagnose without another
                # round trip. Surface it in the state itself instead.
                $entry.LastHeadlessArmError = $_.Exception.Message
                $entry.RdpConnectionStatus = 'Error'
                Write-Verbose "Auto re-arm of headless loopback for '$key' failed: $($_.Exception.Message)"
            }
        }
    }

    Save-DashboardState -State $state
    return $state
}

function global:Test-DashboardInstallation {
    $checks = [ordered]@{
        'RDP Wrapper installed' = (Test-Path -LiteralPath $script:RdpWrapperRoot)
        'TermWrap configured' = (Test-RdpWrapperConfiguration).Success
        'Remote Desktop enabled' = (((Get-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -ErrorAction SilentlyContinue).fDenyTSConnections) -eq 0)
        'Remote Desktop Plus installed' = (Test-Path -LiteralPath (Resolve-RemoteDesktopPlusPath))
        'Dashboard installed' = (Test-Path -LiteralPath (Join-Path $script:InstallRoot 'Dashboard.ps1'))
    }
    $checks.GetEnumerator() | ForEach-Object { [pscustomobject]@{ Check=$_.Key; Passed=[bool]$_.Value } }
}

function global:Start-DashboardBackgroundTask {
    <#
        Runs a single module command (by name, with a parameter hashtable --
        never a scriptblock, which would carry cross-runspace baggage) on
        its own background runspace, so the WinForms UI thread is never
        blocked by RDP launches, session waits, or headless re-arms -- all
        of which can legitimately take several seconds up to tens of
        seconds. This is what makes Start/Connect/Stop and the monitor tick
        non-blocking.

        Non-blocking end to end:
          1. PowerShell.BeginInvoke() starts the command on its own
             background runspace/thread and returns immediately -- this UI
             thread never waits on it directly.
          2. Completion is detected by polling IsCompleted from a WinForms
             Timer, not a raw .NET ThreadPool callback. This matters: a
             ThreadPool callback (e.g. via ThreadPool.RegisterWaitForSingleObject)
             fires on a pooled worker thread that has no PowerShell runspace
             attached, so it cannot run any PowerShell script at all --
             attempting to would crash the whole process the instant it
             fires ("There is no Runspace available to run scripts in this
             thread"). A WinForms Timer's Tick, by contrast, always fires on
             the thread that created it (here, always the UI thread, since
             Start-DashboardBackgroundTask is only ever called from a button
             handler or the monitor tick) via the same message loop
             ShowDialog() already pumps -- exactly like the pre-existing
             session timer, so it already has a valid runspace.
          3. -OnSuccess/-OnError/-OnComplete are still funneled through
             -Control's Control.BeginInvoke, the standard, safe way to touch
             a WinForms control -- harmless even though the poll timer's
             Tick is already running on that same UI thread, and it keeps
             this helper correct if a future caller ever did trigger it from
             a different thread.
    #>
    param(
        [Parameter(Mandatory)][string]$Command,
        [hashtable]$Params = @{},
        # Deliberately untyped (not [System.Windows.Forms.Control]): this
        # module must be importable from the non-interactive installer,
        # which never loads System.Windows.Forms, and a strict WinForms
        # type constraint here would fail to resolve at module-load time in
        # that context. $Control is expected to be a WinForms Control (or
        # anything else exposing IsHandleCreated/BeginInvoke) -- PowerShell
        # method calls are late-bound, so this works without the static type.
        [Parameter(Mandatory)]$Control,
        [scriptblock]$OnSuccess = {},
        [scriptblock]$OnError = {},
        [scriptblock]$OnComplete = {}
    )

    $moduleRoot = $script:InstallRoot
    # Prefer the actual module file's own directory (works from a local
    # checkout too, not just an installed copy) so background runspaces
    # resolve the same MultiSessionDashboard.psm1 this coordinator is
    # already running from.
    if ($PSScriptRoot) { $moduleRoot = $PSScriptRoot }

    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.ApartmentState = [System.Threading.ApartmentState]::MTA
    $runspace.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
    $runspace.Open()

    $ps = [powershell]::Create()
    $ps.Runspace = $runspace
    [void]$ps.AddScript({
        param($ModuleRoot, $Command, $Params)
        Import-Module (Join-Path $ModuleRoot 'MultiSessionDashboard.psm1') -Force
        & $Command @Params
    })
    [void]$ps.AddArgument($moduleRoot)
    [void]$ps.AddArgument($Command)
    [void]$ps.AddArgument($Params)

    $asyncResult = $ps.BeginInvoke()

    <#
        A plain scriptblock literal does NOT keep its defining function
        call's local variables alive once that call returns -- and
        Start-DashboardBackgroundTask returns right after this point, well
        before the timer ever ticks. Without .GetNewClosure(), the Tick
        handler below would try to read $asyncResult (and everything else)
        from a scope that's already gone, throwing "The variable ...
        cannot be retrieved because it has not been set." (confirmed by
        reproducing it). .GetNewClosure() snapshots the referenced
        variables into the scriptblock's own storage at creation time,
        independent of the original scope's lifetime.

        That snapshot does NOT reliably chain through a second, nested
        .GetNewClosure() called from inside an already-closed scriptblock
        (also confirmed by reproducing it: a variable closed over by the
        outer closure was empty inside a scriptblock closed a second time
        from within it). So $successCallback/$errorCallback/$completeCallback
        below are each built as their own single-level closure right here,
        and the Tick handler calls them as already-built delegate objects,
        passing $result/$message as a genuine Control.BeginInvoke argument
        (plain .NET delegate-argument marshaling) rather than baking them
        into a further nested closure.
    #>
    $successCallback = [Action[object]]({ param($r) & $OnSuccess $r }).GetNewClosure()
    $errorCallback = [Action[string]]({ param($m) & $OnError $m }).GetNewClosure()
    $completeCallback = [Action]({ & $OnComplete }).GetNewClosure()

    $pollTimer = New-Object System.Windows.Forms.Timer
    $pollTimer.Interval = 150
    $pollTimer.Add_Tick({
        if (-not $asyncResult.IsCompleted) { return }
        $pollTimer.Stop()
        $pollTimer.Dispose()

        try {
            $output = $ps.EndInvoke($asyncResult)
            if ($ps.Streams.Error.Count -gt 0) { throw $ps.Streams.Error[0].Exception }
            $items = @($output)
            $result = if ($items.Count -eq 1) { $items[0] } elseif ($items.Count -eq 0) { $null } else { $items }
            if ($Control.IsHandleCreated) {
                $Control.BeginInvoke($successCallback, @($result)) | Out-Null
            }
        } catch {
            $message = $_.Exception.Message
            if ($Control.IsHandleCreated) {
                $Control.BeginInvoke($errorCallback, @($message)) | Out-Null
            }
        } finally {
            if ($Control.IsHandleCreated) {
                $Control.BeginInvoke($completeCallback, @()) | Out-Null
            }
            $ps.Dispose()
            $runspace.Dispose()
        }
    }.GetNewClosure())
    $pollTimer.Start()
}

# Load the four focused backend modules. One direction only (coordinator ->
# managers) to avoid any Import-Module circularity: none of the four ever
# import this file or each other. -Global makes their exported functions
# available process-wide immediately, on top of each already using
# `function global:` internally -- belt and suspenders, since either alone
# is sufficient given this project's single-runspace-per-process model (see
# this file's header comment).
$managerModules = @('SessionManager.psm1', 'UserManager.psm1', 'RdpManager.psm1', 'HeadlessManager.psm1')
foreach ($manager in $managerModules) {
    $managerPath = if ($PSScriptRoot) { Join-Path $PSScriptRoot $manager } else { Join-Path $script:InstallRoot $manager }
    Import-Module $managerPath -Force -Global
}

Export-ModuleMember -Function *
