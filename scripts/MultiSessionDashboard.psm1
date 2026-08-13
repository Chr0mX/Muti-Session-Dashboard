Set-StrictMode -Version Latest

$script:InstallRoot = 'C:\Program Files\Muti Session Dashboard'
$script:RdpWrapperRoot = 'C:\Program Files\RDP Wrapper'
$script:ConfigRoot = Join-Path $script:InstallRoot 'Config'
$script:UsersRoot = Join-Path $script:InstallRoot 'Users'
$script:StateFile = Join-Path $script:ConfigRoot 'sessions.json'
$script:DownloadCacheRoot = Join-Path $script:ConfigRoot 'Downloads'
$script:PortStart = 47989
$script:PortEnd = 48050
$script:RdpHost = '127.0.0.2'
$script:RdpPort = 3389
$script:RdpPlusPath = 'C:\Program Files (x86)\Remote Desktop Plus\rdp.exe'
$script:ComponentVersionsFile = Join-Path $script:ConfigRoot 'component-versions.json'
# .1 is the host and .2 is reserved by the RDP Wrapper session-handoff trick
# (see Invoke-DashboardRdpBootstrap), so per-user Sunshine loopback addresses
# start at .3. See Get-AllocatedLoopback.
$script:SunshineLoopbackStartOctet = 3

# Sunshine's 'port' config value is the base of a fixed *family* of ports,
# each offset from it by a documented, unconfigurable amount -- not a single
# port. See https://docs.lizardbyte.dev/projects/sunshine/master/md_docs_2configuration.html
$script:SunshinePortOffsets = [ordered]@{
    Https   = -5  # TCP
    Http    = 0   # TCP -- the configured 'port' value itself
    Web     = 1   # TCP
    Video   = 9   # UDP
    Control = 10  # UDP
    Audio   = 11  # UDP
    Mic     = 13  # UDP (unused)
    Rtsp    = 21  # TCP
}
$script:SunshineUdpPortNames = @('Video', 'Control', 'Audio', 'Mic')


function Set-DashboardPaths {
    param([Parameter(Mandatory)][string]$InstallRoot)
    $script:InstallRoot = $InstallRoot
    $script:ConfigRoot = Join-Path $script:InstallRoot 'Config'
    $script:UsersRoot = Join-Path $script:InstallRoot 'Users'
    $script:StateFile = Join-Path $script:ConfigRoot 'sessions.json'
    $script:DownloadCacheRoot = Join-Path $script:ConfigRoot 'Downloads'
    $script:ComponentVersionsFile = Join-Path $script:ConfigRoot 'component-versions.json'
}

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Multi Session Dashboard must be run from an elevated PowerShell session.'
    }
}

function Get-SeTcbPrivilegeSids {
    <#
        Reads the local security policy's current SeTcbPrivilege ("Act as
        part of the operating system") assignment via secedit and returns
        the raw SID/account list. Read-only; used both to check whether the
        Administrators group already has it and, in Grant-DashboardTcbPrivilege,
        to merge into rather than clobber whatever's already assigned.
    #>
    $exportPath = Join-Path $env:TEMP ("msd-secpol-export-" + [guid]::NewGuid().ToString('N') + '.inf')
    try {
        & secedit /export /cfg $exportPath /areas USER_RIGHTS | Out-Null
        if (-not (Test-Path -LiteralPath $exportPath)) {
            throw 'secedit /export did not produce a policy file.'
        }
        $line = Get-Content -LiteralPath $exportPath | Where-Object { $_ -match '^\s*SeTcbPrivilege\s*=' } | Select-Object -First 1
        if (-not $line -or $line -notmatch '=\s*(.*)$') { return @() }
        return @($matches[1] -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    } finally {
        Remove-Item -LiteralPath $exportPath -ErrorAction SilentlyContinue
    }
}

function Test-DashboardTcbPrivilegeGranted {
    <#
        Policy-level check: does the local security policy grant
        SeTcbPrivilege to BUILTIN\Administrators (S-1-5-32-544)? This can be
        true while the *current* process's own token still lacks it -- see
        Test-CurrentTokenHasTcbPrivilege for that, separate, check.
    #>
    return ((Get-SeTcbPrivilegeSids) -contains '*S-1-5-32-544')
}

function Test-CurrentTokenHasTcbPrivilege {
    <#
        Token-level check: does *this* process's own logon token carry
        SeTcbPrivilege right now? Granting the policy only affects new logon
        tokens, so an operator who was already logged in when the grant
        happened needs to log off/on (or reboot) before tscon actually works
        for them -- whoami /priv omits a privilege entirely (not merely
        'Disabled') when the token doesn't hold it at all.
    #>
    $priv = & whoami /priv 2>$null
    return (($priv -join "`n") -match '(?im)^SeTcbPrivilege\s')
}

function Grant-DashboardTcbPrivilege {
    <#
        tscon requires the caller to hold SeTcbPrivilege to hand a session
        to console without a password prompt, and to displace whoever
        currently occupies the destination session -- a hard requirement
        for Start/Connect RDP's console hand-off, not an edge case. Local
        Administrators do not hold it by default. Grants it to
        BUILTIN\Administrators via a local security policy update
        (secedit), merging into whatever accounts already hold it rather
        than replacing them. Idempotent: a no-op if already granted.

        IMPORTANT: this only affects new logon tokens. An operator already
        logged in when this runs must log off/on (or reboot) before tscon
        will work for them -- the policy change alone does not upgrade an
        existing session's token.
    #>
    if (Test-DashboardTcbPrivilegeGranted) {
        Write-Host 'SeTcbPrivilege is already granted to Administrators.'
        return
    }

    $existingSids = Get-SeTcbPrivilegeSids
    $allSids = @($existingSids + '*S-1-5-32-544' | Select-Object -Unique)

    $importPath = Join-Path $env:TEMP ("msd-secpol-import-" + [guid]::NewGuid().ToString('N') + '.inf')
    $dbPath = Join-Path $env:TEMP ("msd-secpol-" + [guid]::NewGuid().ToString('N') + '.sdb')
    try {
        $content = @(
            '[Unicode]'
            'Unicode=yes'
            '[Version]'
            'signature="$CHICAGO$"'
            'Revision=1'
            '[Privilege Rights]'
            "SeTcbPrivilege = $($allSids -join ',')"
        ) -join "`r`n"
        Set-Content -LiteralPath $importPath -Value $content -Encoding Unicode

        $result = & secedit /configure /db $dbPath /cfg $importPath /areas USER_RIGHTS 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "secedit failed to grant SeTcbPrivilege to Administrators (exit $LASTEXITCODE): $result"
        }
    } finally {
        Remove-Item -LiteralPath $importPath, $dbPath -ErrorAction SilentlyContinue
    }

    Write-Warning 'Granted SeTcbPrivilege ("Act as part of the operating system") to Administrators so tscon can hand sessions to console. This only applies to NEW logon tokens: log off and back on (or reboot), then relaunch the dashboard, before Start/Connect RDP will work.'
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
        By default resolves the latest release through the GitHub API (like
        Install-MoonlightPortable/Install-SunshinePortable) rather than only
        ever downloading the static '.../releases/latest/download/<fixed
        filename>' URL. That URL's text -- and the asset's filename -- never
        changes between releases, so a download cache keyed on it alone can
        never tell a stale cached copy apart from a newer release; the cache
        name below is keyed on the resolved release tag instead, so normal
        caching correctly reuses a hit for an unchanged release and
        correctly re-downloads when a new one is published -- no need to
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

function Install-PortableZip {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Uri, [Parameter(Mandatory)][string]$Destination)
    $zip = Join-Path $env:TEMP "$Name.zip"
    Invoke-DownloadFile -Uri $Uri -Destination $zip -CacheName $Name | Out-Null
    Expand-ArchiveSafe -Archive $zip -Destination $Destination
}

function Install-MoonlightPortable {
    param(
        [string]$ReleaseApiUri = 'https://api.github.com/repos/moonlight-stream/moonlight-qt/releases/latest',
        [string[]]$AssetNamePatterns = @('^MoonlightPortable-x64\.zip$', '^MoonlightPortable-x64-.*\.zip$', '^MoonlightPortable.*x64.*\.zip$')
    )
    $asset = Resolve-GitHubLatestReleaseAsset -ReleaseApiUri $ReleaseApiUri -AssetNamePatterns $AssetNamePatterns -ComponentName 'Moonlight Portable'
    Install-PortableZip -Name 'moonlight' -Uri $asset.Uri -Destination (Join-Path $script:InstallRoot 'Stream\Moonlight')
    if (-not (Test-Path -LiteralPath (Join-Path $script:InstallRoot 'Stream\Moonlight\Moonlight.exe'))) { throw 'Moonlight.exe was not found after extraction.' }
    Save-ComponentVersion -Component 'Moonlight' -Version $asset.Release
}

function Install-SunshinePortable {
    param(
        [string]$ReleaseApiUri = 'https://api.github.com/repos/LizardByte/Sunshine/releases/latest',
        [string[]]$AssetNamePatterns = @(
            '(?i)^Sunshine-Windows-AMD64-portable\.zip$',
            '(?i)^Sunshine-Windows.*portable.*\.zip$',
            '(?i)^Sunshine.*Windows.*portable.*\.zip$',
            '(?i)^Sunshine.*portable.*Windows.*\.zip$'
        )
    )

    $destination = Join-Path $script:InstallRoot 'Stream\Sunshine'

    Write-Host 'Installing Sunshine Portable master copy...'

    $asset = Resolve-GitHubLatestReleaseAsset `
        -ReleaseApiUri $ReleaseApiUri `
        -AssetNamePatterns $AssetNamePatterns `
        -ComponentName 'Sunshine Portable'

    Install-PortableZip `
        -Name 'sunshine' `
        -Uri $asset.Uri `
        -Destination $destination

    # Find the actual Sunshine executable anywhere in the extracted archive.
    $sunshineExe = Get-ChildItem `
        -LiteralPath $destination `
        -Recurse `
        -Filter 'sunshine.exe' `
        -File `
        -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if (-not $sunshineExe) {
        throw "Sunshine.exe was not found after extraction under '$destination'."
    }

    # If the ZIP contains a nested Sunshine directory, flatten it.
    if ($sunshineExe.Directory.FullName -ne $destination) {
        $sourceDirectory = $sunshineExe.Directory.FullName

        Write-Host "Flattening Sunshine Portable directory:"
        Write-Host "  $sourceDirectory"
        Write-Host "  -> $destination"

        Get-ChildItem -LiteralPath $sourceDirectory -Force |
            Move-Item -Destination $destination -Force

        # Remove the now-empty nested directory.
        if (Test-Path -LiteralPath $sourceDirectory) {
            Remove-Item -LiteralPath $sourceDirectory -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    $expectedExe = Join-Path $destination 'sunshine.exe'

    if (-not (Test-Path -LiteralPath $expectedExe)) {
        throw "Sunshine.exe was not found at expected path '$expectedExe'."
    }

    Write-Host "Sunshine Portable installed successfully."
    Write-Host "Executable: $expectedExe"
    Save-ComponentVersion -Component 'Sunshine' -Version $asset.Release
}

function Test-TsconAvailable {
    $tscon = Join-Path $env:SystemRoot 'System32\tscon.exe'
    return (Test-Path -LiteralPath $tscon)
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

function Get-UserSessions {
    param([Parameter(Mandatory)][string]$Username)
    $sessions = @()
    foreach ($line in @(quser 2>$null)) {
        $text = [string]$line
        if ($text -match '^\s*>?\s*(\S+)(?:\s+(\S+))?\s+(\d+)\s+(\S+)') {
            $user = $matches[1]; $sessionName = if ($matches[2] -match '^rdp-tcp|^console$') { $matches[2] } else { '' }; $id = [int]$matches[3]; $state = $matches[4]
            if ($user -ieq $Username) {
                $sessions += [pscustomobject]@{ Username=$user; SessionId=$id; SessionName=$sessionName; State=$state; Online=($state -match '^(Active|Conn)$'); IsRdp=($sessionName -like 'rdp-tcp*'); IsConsole=($sessionName -ieq 'console') }
            }
        }
    }
    return @($sessions)
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

function Get-UserConsoleSession {
    param([Parameter(Mandatory)][string]$Username)
    return @(Get-UserSessions -Username $Username | Where-Object { $_.IsConsole } | Sort-Object SessionId | Select-Object -First 1)
}

function Wait-DashboardRdpSession {
    param([Parameter(Mandatory)][string]$Username,[int]$TimeoutSeconds=30,[int[]]$IgnoreSessionIds=@())
    $deadline=(Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $session=@(Get-UserSessions -Username $Username | Where-Object { $_.IsRdp -and $_.State -match '^(Active|Conn)$' -and ($IgnoreSessionIds -notcontains $_.SessionId) } | Sort-Object SessionId | Select-Object -First 1)
        if ($null -ne $session -and @($session).Count -gt 0) { return $session[0] }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    return $null
}

function Invoke-TsconToConsole {
    param([Parameter(Mandatory)][int]$SessionId)
    Assert-Administrator
    $tscon=Join-Path $env:SystemRoot 'System32\tscon.exe'
    if (-not (Test-Path -LiteralPath $tscon)) { throw "tscon.exe was not found at '$tscon'." }
    & $tscon $SessionId /dest:console 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "tscon failed for session $SessionId with exit code $LASTEXITCODE." }
}

function Maintain-DashboardSession {
    param([Parameter(Mandatory)][string]$Username)
    Assert-Administrator
    $sessions=@(Get-UserSessions -Username $Username)
    if ($sessions.Count -eq 0) { return $null }

    # Do not interrupt a live GUI RDP connection. When the client disconnects,
    # hand that disconnected RDP session to the console so the user session
    # remains alive for Sunshine/Moonlight.
    $disconnectedRdp=$sessions | Where-Object { $_.IsRdp -and $_.State -match '^(Disc|Disconnected)$' } | Sort-Object SessionId | Select-Object -First 1
    if ($null -ne $disconnectedRdp) {
        $console = $sessions | Where-Object { $_.IsConsole -and $_.Online } | Select-Object -First 1
        if ($null -ne $console) {
            # The preserved console session is already alive. Do not create a
            # second console session; remove the stale disconnected RDP login.
            logoff $disconnectedRdp.SessionId 2>$null
        } else {
            # No console session exists, so tscon the disconnected RDP session
            # back to console to revive the user's desktop without logging off.
            Invoke-TsconToConsole -SessionId $disconnectedRdp.SessionId
            Start-Sleep -Milliseconds 500
        }
    }
    return (Get-UserSession -Username $Username)
}

function Invoke-DashboardRdpBootstrap {
    param([Parameter(Mandatory)][string]$Username)

    Assert-Administrator
    $rdpPlusPath = Resolve-RemoteDesktopPlusPath
    if (-not (Test-Path -LiteralPath $rdpPlusPath)) {
        throw "Remote Desktop Plus was not found at '$rdpPlusPath'. Re-run the installer to install it."
    }

    # Dashboard-managed local accounts always use the username as the Windows
    # account password (see New-DashboardUser), so the login is passed
    # explicitly and completes with no saved-credential prompt to click
    # through. 127.0.0.2 (not 127.0.0.1) is required: it is the loopback
    # address RDP Wrapper uses to grant an *additional* session to an account
    # that is already logged on, instead of reconnecting to its existing one.
    $arguments = @(
        "/v:$($script:RdpHost):$($script:RdpPort)",
        "/u:.\$Username",
        "/p:$Username",
        '/w:1920',
        '/h:1080'
    )

    Write-Host "Starting Remote Desktop Plus for '$Username' at 1920x1080."
    $rdpPlusProcess = Start-Process -FilePath $rdpPlusPath -ArgumentList $arguments -PassThru

    $session = Wait-DashboardRdpSession -Username $Username -TimeoutSeconds 30
    if ($null -eq $session) {
        throw "RDP login for '$Username' did not produce an active RDP session within 30 seconds."
    }

    # Stashed so Start-DashboardSession can close the client window once it
    # has handed the session to console (that window is no longer needed --
    # the session lives on via tscon). Connect-DashboardRdp deliberately
    # ignores this: that window IS the live interactive session.
    $session | Add-Member -NotePropertyName RdpPlusProcessId -NotePropertyValue $rdpPlusProcess.Id -Force
    return $session
}

function Stop-DashboardRdpPlusProcess {
    <#
        Closes the Remote Desktop Plus client window Start-DashboardSession
        launched, once tscon has already handed its session off to console
        and the window is just stale leftover. Remote Desktop Plus wraps
        mstsc.exe, so the visible window may belong to either the rdp.exe
        process itself or a child mstsc.exe it spawned -- close both.
        Best-effort/cosmetic: failures here should never fail Start.
    #>
    param([Parameter(Mandatory)][int]$ProcessId)
    try {
        $children = @(Get-CimInstance -ClassName Win32_Process -Filter "ParentProcessId=$ProcessId" -ErrorAction SilentlyContinue)
        foreach ($child in $children) {
            Stop-Process -Id $child.ProcessId -Force -ErrorAction SilentlyContinue
        }
        Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
    } catch {
        Write-Verbose "Could not close the Remote Desktop Plus window (PID $ProcessId): $($_.Exception.Message)"
    }
}

function Keep-DashboardRdpSessionAlive {
    param([Parameter(Mandatory)][string]$Username)

    Assert-Administrator
    $tscon = Join-Path $env:SystemRoot 'System32\tscon.exe'
    if (-not (Test-Path -LiteralPath $tscon)) { throw "tscon.exe was not found at '$tscon'." }

    $session = Get-UserRdpSessionId -Username $Username
    if ($null -eq $session) { throw "No active RDP session was found for '$Username'." }

    & $tscon $session.SessionId /dest:console 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "tscon failed for session $($session.SessionId) with exit code $LASTEXITCODE." }
    return $session.SessionId
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
        every call site (which is exactly how the last field added here
        ended up missing from some of them).
    #>
    param([Parameter(Mandatory)][string]$Username, [string]$AccountName)
    if ([string]::IsNullOrWhiteSpace($AccountName)) { $AccountName = ".\$Username" }
    return @{
        Username = $Username
        AccountName = $AccountName
        SunshinePort = $null
        SunshineLoopback = $null
        SessionState = 'Stopped'
        SunshineState = 'Stopped'
        RdpSessionId = $null
        RdpConnectionStatus = 'Disconnected'
        SunshineProcessId = $null
    }
}

function Repair-DashboardStateEntry {
    <#
        Set-StrictMode -Version Latest throws "property ... cannot be found"
        on dot-access to a hashtable key that simply isn't there -- so an
        entry written by an older version of this module (before
        SunshineLoopback/SunshineProcessId existed, or before any future
        field) crashes the first time anything reads it that way. Back-fill
        any missing keys with their default value so every entry always has
        the full current shape, regardless of when it was first created.
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

function Get-ComponentVersions {
    if (-not (Test-Path -LiteralPath $script:ComponentVersionsFile)) { return @{} }
    $json = Get-Content -LiteralPath $script:ComponentVersionsFile -Raw
    if ([string]::IsNullOrWhiteSpace($json)) { return @{} }
    return (ConvertTo-HashtableRecursive ($json | ConvertFrom-Json))
}

function Save-ComponentVersion {
    <#
        Persists the resolved release tag for a downloaded component so a
        future run can tell what's currently installed without re-querying
        the release API -- the "store version information for future update
        checks" step the installer functions otherwise discard.
    #>
    param([Parameter(Mandatory)][string]$Component, [Parameter(Mandatory)][string]$Version)
    New-DirectoryIfMissing -Path $script:ConfigRoot
    $versions = Get-ComponentVersions
    $versions[$Component] = @{ Version = $Version; InstalledAt = (Get-Date).ToString('o') }
    $versions | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:ComponentVersionsFile -Encoding UTF8
}

function New-DashboardUser {
    <#
        Dashboard-managed accounts always get the username as their Windows
        account password. Start/Connect RDP (Invoke-DashboardRdpBootstrap)
        depend on this: they pass /p:$Username to Remote Desktop Plus for a
        fully automated login, so the account's real password must match.
        If -Password is supplied and differs from -Username, the account is
        still created with that password, but automated RDP login for it
        will fail until the password is reset to match the username.
    #>
    param([Parameter(Mandatory)][string]$Username, [string]$Password)
    Assert-Administrator
    if ([string]::IsNullOrEmpty($Password)) { $Password = $Username }
    if ($Password -ne $Username) {
        Write-Warning "'$Username' is being created with a password that does not match the username. Start/Connect RDP auto sign-in requires the account password to equal the username; automated RDP login will fail until it is reset to match."
    }

    net user $Username $Password /add | Out-Null
    net localgroup 'Remote Desktop Users' $Username /add | Out-Null

    $userRoot = Join-Path $script:UsersRoot $Username
    New-DirectoryIfMissing -Path $userRoot
    Initialize-UserSunshine -Username $Username
}

function Install-UserSunshineFiles {
    <#
        Copies the current master Sunshine install into a user's per-user
        directory and (re)writes their config/apps.json/Startup shortcut.
        Shared by Initialize-UserSunshine (new user) and
        Update-DashboardUserSunshine (existing user, e.g. after a newer
        Sunshine release was installed) so both stay in sync.
    #>
    param([Parameter(Mandatory)][string]$Username, [switch]$ReservePort)

    $master = Join-Path $script:InstallRoot 'Stream\Sunshine'
    if (-not (Test-Path -LiteralPath (Join-Path $master 'sunshine.exe'))) {
        throw 'Master Sunshine installation is missing. Run the installer to install/update it first.'
    }

    # Stop any running copy first so an in-use sunshine.exe doesn't block the
    # copy; it comes back automatically at the user's next logon (Startup
    # folder) or the next time the operator Starts/reconnects the session.
    Get-Process -Name 'Sunshine' -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -like "C:\Users\$Username\AppData\Local\Muti Session Dashboard\Sunshine\*" } |
        Stop-Process -Force -ErrorAction SilentlyContinue

    $profile = Join-Path 'C:\Users' $Username
    $dest = Join-Path $profile 'AppData\Local\Muti Session Dashboard\Sunshine'
    New-DirectoryIfMissing -Path $dest

    # -LiteralPath disables wildcard expansion, so Copy-Item -LiteralPath
    # "$master\*" was looking for a file literally named "*" -- which never
    # exists -- and failing as a non-terminating error that nothing here
    # caught, leaving $dest empty with no error ever surfacing. Enumerate
    # $master's contents (LiteralPath is safe there, no globbing needed) and
    # copy each item instead; -ErrorAction Stop makes any real copy failure
    # (locked file, permissions, disk full) throw immediately too.
    Get-ChildItem -LiteralPath $master -Force | Copy-Item -Destination $dest -Recurse -Force -ErrorAction Stop
    if (-not (Test-Path -LiteralPath (Join-Path $dest 'sunshine.exe'))) {
        throw "sunshine.exe was not found in '$dest' after copying from '$master'."
    }

    $configDir = Join-Path $profile 'AppData\Local\Muti Session Dashboard\Config'
    New-DirectoryIfMissing -Path $configDir

    # The loopback address is reserved permanently (unlike the port, which is
    # only tentatively previewed for a brand-new user and actually
    # reserved/released per Start/Stop cycle): Moonlight pairs per-host, so
    # giving a user a stable address avoids forcing a re-pair every session.
    $loopback = Get-AllocatedLoopback -Username $Username -Reserve
    $port = Get-AllocatedPort -Username $Username -Reserve:$ReservePort -Loopback $loopback
    Set-UserSunshineConfig -Username $Username -Port $port -Loopback $loopback
    New-UserSunshineAppsConfig -Username $Username
    Set-UserSunshineAutoStart -Username $Username

    return [pscustomobject]@{ Username = $Username; Port = $port; Loopback = $loopback }
}

function Initialize-UserSunshine {
    param([Parameter(Mandatory)][string]$Username)
    Install-UserSunshineFiles -Username $Username -ReservePort:$false | Out-Null
}

function Update-DashboardUserSunshine {
    <#
        Installs/updates Sunshine for an already-created dashboard user --
        e.g. after Install-SunshinePortable has pulled a newer release into
        the master copy, this pushes it out to an existing user without
        recreating their Windows account. Re-copies the executable/assets
        and refreshes sunshine.conf/the Startup-folder shortcut; apps.json
        is left alone if it already exists, so an operator's own app-list
        customization survives an update.
    #>
    param([Parameter(Mandatory)][string]$Username)
    Assert-Administrator

    $knownUsers = @(Get-RemoteDesktopUsers | ForEach-Object { $_.Username })
    if ($knownUsers -notcontains $Username) {
        throw "'$Username' is not a member of the local 'Remote Desktop Users' group. Create the user first."
    }

    $result = Install-UserSunshineFiles -Username $Username -ReservePort

    $versions = Get-ComponentVersions
    $sunshineVersion = if ($versions.ContainsKey('Sunshine')) { $versions['Sunshine'].Version } else { 'unknown' }
    Write-Host "Sunshine updated for '$Username' (release $sunshineVersion, port $($result.Port), loopback $($result.Loopback))."
    return $result
}

function Get-AllocatedPort {
    <#
        Sunshine's 'port' is the base of a fixed *family* of ports (see the
        $script:SunshinePortOffsets table), not a single port -- e.g. two
        users whose base ports are only 1 apart collide, because the first
        user's Web port (base+1) lands on the second user's HTTP port
        (base+0). Every offset is checked against real listeners, not just
        the bare base value, or "no collision on the base port" would be a
        false negative.

        Each user's own loopback address (bind_address, see
        Get-AllocatedLoopback) already isolates its whole port family from
        every other dashboard-managed user -- a listening socket is
        (address, port), not port alone -- so pass -Loopback once it's known
        for a check that also catches something else already listening on
        that specific address, on top of the shared-address check below.
    #>
    param([Parameter(Mandatory)][string]$Username, [switch]$Reserve, [string]$Loopback)
    $state = Get-DashboardState
    if ($state.ContainsKey($Username) -and $state[$Username].SunshinePort) { return [int]$state[$Username].SunshinePort }
    $used = @($state.Values | ForEach-Object { if ($_.SunshinePort) { [int]$_.SunshinePort } })

    $addresses = @('0.0.0.0', '127.0.0.1', '::', '::1')
    if (-not [string]::IsNullOrWhiteSpace($Loopback)) { $addresses += $Loopback }

    foreach ($port in $script:PortStart..$script:PortEnd) {
        if ($used -contains $port) { continue }

        $collision = $false
        foreach ($name in $script:SunshinePortOffsets.Keys) {
            $candidate = $port + $script:SunshinePortOffsets[$name]
            if ($candidate -lt 1 -or $candidate -gt 65535) { continue }
            # Never probe with Test-NetConnection. Get-NetTCPConnection /
            # Get-NetUDPEndpoint identify an existing listener without
            # opening a connection or waiting for a response.
            if ($script:SunshineUdpPortNames -contains $name) {
                $listener = Get-NetUDPEndpoint -LocalAddress $addresses -LocalPort $candidate -ErrorAction SilentlyContinue
            } else {
                $listener = Get-NetTCPConnection -LocalAddress $addresses -LocalPort $candidate -State Listen -ErrorAction SilentlyContinue
            }
            if ($null -ne $listener) { $collision = $true; break }
        }
        if ($collision) { continue }

        if ($Reserve) {
            if ($state.ContainsKey($Username)) {
                # Update in place -- replacing the whole entry here would
                # clobber fields (RdpSessionId, SunshineLoopback, ...) an
                # existing user already had recorded.
                $state[$Username].SunshinePort = $port
            } else {
                $state[$Username] = Get-DefaultDashboardStateEntry -Username $Username
                $state[$Username].SunshinePort = $port
            }
            Save-DashboardState -State $state
        }
        return $port
    }
    throw 'No available Sunshine ports remain.'
}

function Get-AllocatedLoopback {
    <#
        Assigns each dashboard-managed user a distinct loopback address
        (127.0.0.3, 127.0.0.4, ...) that Sunshine binds to via bind_address.
        Windows treats the entire 127.0.0.0/8 block as loopback with no
        extra routing/firewall configuration needed -- the same property
        Invoke-DashboardRdpBootstrap already relies on for 127.0.0.2.

        This exists because moonlight-qt has no supported way to target a
        non-default Sunshine port from its command line (confirmed against
        its own command-line parser source: getHost() never parses a port
        out of the host argument), so per-user *ports* alone (Get-AllocatedPort)
        can't be reached by Connect-DashboardMoonlight. A distinct address per
        user, each answering on Sunshine's default GameStream ports, is what
        actually makes every user's stream independently reachable.
    #>
    param([Parameter(Mandatory)][string]$Username, [switch]$Reserve)
    $state = Get-DashboardState
    if ($state.ContainsKey($Username) -and $state[$Username].SunshineLoopback) { return [string]$state[$Username].SunshineLoopback }

    $used = @($state.Values | ForEach-Object { if ($_.SunshineLoopback) { [string]$_.SunshineLoopback } })
    for ($octet = $script:SunshineLoopbackStartOctet; $octet -le 254; $octet++) {
        $address = "127.0.0.$octet"
        if ($used -contains $address) { continue }
        if ($Reserve) {
            if ($state.ContainsKey($Username)) {
                $state[$Username].SunshineLoopback = $address
            } else {
                $state[$Username] = Get-DefaultDashboardStateEntry -Username $Username
                $state[$Username].SunshineLoopback = $address
            }
            Save-DashboardState -State $state
        }
        return $address
    }
    throw 'No available Sunshine loopback addresses remain.'
}

function Set-UserSunshineConfig {
    param(
        [Parameter(Mandatory)][string]$Username,
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][string]$Loopback
    )
    $configDir = Join-Path (Join-Path 'C:\Users' $Username) 'AppData\Local\Muti Session Dashboard\Config'
    New-DirectoryIfMissing -Path $configDir
    $appsFile = Join-Path $configDir 'apps.json'
    $content = @(
        '# Generated by Multi Session Dashboard',
        "port = $Port",
        "bind_address = $Loopback",
        "sunshine_name = $Username",
        'origin_web_ui_allowed = lan',
        'upnp = disabled',
        'global_prep_cmd = []',
        # Default CSRF-allowed origins only cover localhost/127.0.0.1/::1,
        # but this user's Sunshine answers on its own dedicated loopback
        # address (see Get-AllocatedLoopback), not literally 127.0.0.1, so
        # its own web UI origin needs to be added explicitly or its web UI
        # gets CSRF-blocked. Web UI port is the base port + 1 (Sunshine's
        # fixed port family, see $script:SunshinePortOffsets).
        "csrf_allowed_origins = https://$($Loopback):$($Port + 1)",
        "file_apps = $appsFile",
        "log_path = $(Join-Path $configDir 'sunshine.log')",
        "credentials_file = $(Join-Path $configDir 'sunshine_state.json')",
        "pkey = $(Join-Path $configDir 'credentials\cakey.pem')",
        "cert = $(Join-Path $configDir 'credentials\cacert.pem')"
    ) -join "`r`n"
    Set-Content -LiteralPath (Join-Path $configDir 'sunshine.conf') -Value $content -Encoding UTF8
}

function New-UserSunshineAppsConfig {
    <#
        Writes a minimal per-user apps.json (Sunshine's list of streamable
        apps/desktops) with a single "Desktop" entry, matching the app name
        Connect-DashboardMoonlight passes to `moonlight stream <host> <app>`.
        Never overwrites an operator's own customization on repeat runs.
    #>
    param([Parameter(Mandatory)][string]$Username)
    $configDir = Join-Path (Join-Path 'C:\Users' $Username) 'AppData\Local\Muti Session Dashboard\Config'
    New-DirectoryIfMissing -Path $configDir
    $appsFile = Join-Path $configDir 'apps.json'
    if (Test-Path -LiteralPath $appsFile) { return }
    $apps = [ordered]@{ apps = @(@{ name = 'Desktop'; 'image-path' = 'desktop.png' }) }
    $apps | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $appsFile -Encoding UTF8
}

function Set-UserSunshineAutoStart {
    <#
        Creates a Startup-folder shortcut so Sunshine launches automatically
        at this user's own interactive logon -- running as that user, not as
        the elevated dashboard/operator account a Start-Process call from the
        dashboard would otherwise run it under. See Test-UserSunshineRunning
        for the verification this is paired with, and Start-DashboardSession
        for how the two are used together.
    #>
    param([Parameter(Mandatory)][string]$Username)
    $profile = Join-Path 'C:\Users' $Username
    $sunshine = Join-Path $profile 'AppData\Local\Muti Session Dashboard\Sunshine\sunshine.exe'
    $conf = Join-Path $profile 'AppData\Local\Muti Session Dashboard\Config\sunshine.conf'
    $startupDir = Join-Path $profile 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup'
    New-DirectoryIfMissing -Path $startupDir
    $shortcutPath = Join-Path $startupDir 'Sunshine.lnk'

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $sunshine
    $shortcut.Arguments = "`"$conf`""
    $shortcut.WorkingDirectory = Split-Path -Parent $sunshine
    $shortcut.WindowStyle = 7 # minimized
    $shortcut.Description = "Multi Session Dashboard: auto-start Sunshine for $Username"
    $shortcut.Save()
}

function Test-UserSunshineRunning {
    <#
        The real per-user verification the spec requires: do not report
        Sunshine as running just because a process was launched. Confirms a
        sunshine.exe process is both the one under this user's own per-user
        copy AND actually owned by that Windows user (not SYSTEM,
        Administrator, or the dashboard's own account), and that its
        assigned loopback address/port is listening.
    #>
    param([Parameter(Mandatory)][string]$Username)

    $expectedPath = Join-Path (Join-Path 'C:\Users' $Username) 'AppData\Local\Muti Session Dashboard\Sunshine\sunshine.exe'
    $result = [pscustomobject]@{ Running = $false; ProcessId = $null; Owner = $null; PortListening = $false }

    $processes = @(Get-CimInstance -ClassName Win32_Process -Filter "Name='sunshine.exe'" -ErrorAction SilentlyContinue)
    foreach ($process in $processes) {
        if ($process.ExecutablePath -and $process.ExecutablePath -ieq $expectedPath) {
            $ownerInfo = Invoke-CimMethod -InputObject $process -MethodName GetOwner -ErrorAction SilentlyContinue
            $owner = if ($ownerInfo) { [string]$ownerInfo.User } else { $null }
            if ($owner -ieq $Username) {
                $result.Running = $true
                $result.ProcessId = [int]$process.ProcessId
                $result.Owner = $owner
                break
            }
        }
    }

    if ($result.Running) {
        $state = Get-DashboardState
        $port = if ($state.ContainsKey($Username)) { $state[$Username].SunshinePort } else { $null }
        $loopback = if ($state.ContainsKey($Username)) { $state[$Username].SunshineLoopback } else { $null }
        if ($port -and $loopback) {
            $listener = Get-NetTCPConnection -LocalAddress $loopback -LocalPort ([int]$port) -State Listen -ErrorAction SilentlyContinue
            $result.PortListening = ($null -ne $listener)
        }
    }

    return $result
}

function Start-DashboardSession {
    param([Parameter(Mandatory)][string]$Username)
    Assert-Administrator
    if (-not (Test-TsconAvailable)) { throw 'Windows tscon.exe is required but was not found.' }

    # 0) Validate preconditions before attempting anything: known user -> RDP
    #    Wrapper healthy -> per-user Sunshine installed. Failing fast here
    #    avoids a confusing partial failure deep inside the RDP bootstrap.
    $knownUsers = @(Get-RemoteDesktopUsers | ForEach-Object { $_.Username })
    if ($knownUsers -notcontains $Username) {
        throw "'$Username' is not a member of the local 'Remote Desktop Users' group."
    }
    $wrapperCheck = Test-RdpWrapperConfiguration
    if (-not $wrapperCheck.Success) {
        throw "RDP Wrapper is not correctly configured: $($wrapperCheck.Failures -join ', ')"
    }
    $sunshineExe = Join-Path (Join-Path 'C:\Users' $Username) 'AppData\Local\Muti Session Dashboard\Sunshine\sunshine.exe'
    if (-not (Test-Path -LiteralPath $sunshineExe)) {
        throw "Sunshine is not installed for '$Username'. Create the user through the dashboard so Initialize-UserSunshine can run first."
    }
    if (-not (Test-CurrentTokenHasTcbPrivilege)) {
        throw "This session's logon token does not hold SeTcbPrivilege, which tscon needs to hand a session to console. The installer grants this to Administrators, but only new logon tokens pick it up -- log off and back on (or reboot), then relaunch the dashboard, before using Start."
    }

    # 1) Create a real 1920x1080 RDP login for the selected user via Remote
    #    Desktop Plus. If this doesn't produce an Active RDP session in time,
    #    fail cleanly here -- tscon hand-off is never attempted.
    try {
        $rdpSession = Invoke-DashboardRdpBootstrap -Username $Username
    } catch {
        throw "RDP session was not created. TSCON hand-off was not attempted. $($_.Exception.Message)"
    }

    # 2) Hand the RDP session to the local console so the Windows session survives.
    Invoke-TsconToConsole -SessionId $rdpSession.SessionId

    # The Remote Desktop Plus window is now stale -- its session already
    # lives on via tscon -- so close it instead of leaving a disconnected
    # client window behind. Cosmetic cleanup only; never fails Start.
    if ($rdpSession.PSObject.Properties['RdpPlusProcessId']) {
        Stop-DashboardRdpPlusProcess -ProcessId $rdpSession.RdpPlusProcessId
    }

    # 3) Confirm the Windows session is still online after the handoff.
    Start-Sleep -Milliseconds 750
    $online = Get-UserSession -Username $Username
    if ($null -eq $online -or -not $online.Online) {
        throw "RDP session for '$Username' was handed off with tscon, but the user is not reported Active by Windows."
    }

    # 4) Sunshine auto-starts under the user's own identity via the Startup-
    #    folder shortcut created at user-creation time (Set-UserSunshineAutoStart)
    #    -- it is deliberately never Start-Process'd from here, since that
    #    would run it as the elevated dashboard/operator account instead of
    #    the target user. Poll for the real, verified state instead of
    #    trusting that launching it worked.
    $loopback = Get-AllocatedLoopback -Username $Username -Reserve
    $port = Get-AllocatedPort -Username $Username -Reserve -Loopback $loopback
    Set-UserSunshineConfig -Username $Username -Port $port -Loopback $loopback

    $deadline = (Get-Date).AddSeconds(20)
    $sunshineStatus = Test-UserSunshineRunning -Username $Username
    while (-not $sunshineStatus.Running -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        $sunshineStatus = Test-UserSunshineRunning -Username $Username
    }
    if (-not $sunshineStatus.Running) {
        throw "Sunshine did not start under '$Username' within 20 seconds. Check the Startup-folder entry (AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup\Sunshine.lnk) and Group Policy for that user; Sunshine is intentionally never launched under the dashboard's own account."
    }

    $state = Get-DashboardState
    $state[$Username].RdpSessionId = $online.SessionId
    $state[$Username].RdpConnectionStatus = 'Online'
    $state[$Username].SessionState = 'Running'
    $state[$Username].SunshineState = 'Running'
    $state[$Username].SunshineProcessId = $sunshineStatus.ProcessId
    Save-DashboardState -State $state
    return $online
}

function Connect-DashboardRdp {
    param([Parameter(Mandatory)][string]$Username)
    Assert-Administrator

    # Reconnects to the user's Windows session using native mstsc against the
    # per-user RDP alias and saved credential. If Start previously handed the
    # session off to the console with tscon, this creates a fresh RDP session
    # for the same Windows logon rather than a brand new user session; the
    # session monitor hands it back to console via tscon when it disconnects.
    $rdp = Invoke-DashboardRdpBootstrap -Username $Username

    $state=Get-DashboardState
    if ($state.ContainsKey($Username)) {
        $state[$Username].RdpSessionId=$rdp.SessionId
        $state[$Username].RdpConnectionStatus='Connected'
        $state[$Username].SessionState='Running'
        Save-DashboardState -State $state
    }
    return $rdp
}

function Keep-Alive-DashboardRdp {
    param([Parameter(Mandatory)][string]$Username)
    $sessionId = Keep-DashboardRdpSessionAlive -Username $Username
    $state = Get-DashboardState
    if ($state.ContainsKey($Username)) {
        $state[$Username].RdpSessionId = $sessionId
        $state[$Username].RdpConnectionStatus = 'Connected'
        Save-DashboardState -State $state
    }
    return $sessionId
}

function Connect-DashboardMoonlight {
    param([Parameter(Mandatory)][string]$Username)
    $moonlight = Join-Path $script:InstallRoot 'Stream\Moonlight\Moonlight.exe'
    if (-not (Test-Path -LiteralPath $moonlight)) { throw 'Moonlight.exe is missing.' }

    $state = Get-DashboardState
    if (-not $state.ContainsKey($Username) -or [string]::IsNullOrWhiteSpace([string]$state[$Username].SunshineLoopback)) {
        throw "No Sunshine target is assigned for '$Username' yet. Create the user (or run Start) before Connect Moonlight."
    }
    $loopback = [string]$state[$Username].SunshineLoopback

    # moonlight-qt's CLI has no supported way to target a non-default
    # Sunshine port (confirmed against its command-line parser source), so
    # each user gets its own loopback address instead (Get-AllocatedLoopback)
    # and Sunshine always answers there on its default GameStream ports.
    # 'stream <host> <app>' and '--absolute-mouse' (backing "optimize mouse
    # for remote desktop instead of games") are real StreamCommandLineParser
    # options, not flags this dashboard invented.
    $arguments = @('stream', $loopback, 'Desktop', '--display-mode', 'windowed', '--resolution', '1920x1080', '--absolute-mouse')
    Start-Process -FilePath $moonlight -ArgumentList $arguments | Out-Null
}

function Stop-DashboardSession {
    param([Parameter(Mandatory)][string]$Username)
    Get-Process -Name 'Sunshine' -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "C:\Users\$Username\AppData\Local\Muti Session Dashboard\Sunshine\*" } | Stop-Process -Force

    # Stop explicitly terminates the user's session; tscon is only used to
    # detach an RDP session without logging it off.
    $session = Get-UserRdpSessionId -Username $Username
    if ($null -ne $session) { logoff $session.SessionId 2>$null }
    else { logoff $Username 2>$null }

    $state = Get-DashboardState
    if ($state.ContainsKey($Username)) {
        # SunshineLoopback is intentionally left in place: it's a stable
        # per-user identity (Moonlight pairs per-host), unlike the port,
        # which is freely re-allocated on the next Start.
        $state[$Username].SunshinePort = $null
        $state[$Username].SessionState = 'Stopped'
        $state[$Username].SunshineState = 'Stopped'
        $state[$Username].RdpConnectionStatus = 'Disconnected'
        $state[$Username].SunshineProcessId = $null
        Save-DashboardState -State $state
    }
}

function Test-DashboardInstallation {
    $checks = [ordered]@{
        'RDP Wrapper installed' = (Test-Path -LiteralPath $script:RdpWrapperRoot)
        'TermWrap configured' = (Test-RdpWrapperConfiguration).Success
        'Remote Desktop enabled' = (((Get-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -ErrorAction SilentlyContinue).fDenyTSConnections) -eq 0)
        'Moonlight downloaded' = (Test-Path -LiteralPath (Join-Path $script:InstallRoot 'Stream\Moonlight\Moonlight.exe'))
        'Sunshine downloaded' = (Test-Path -LiteralPath (Join-Path $script:InstallRoot 'Stream\Sunshine\Sunshine.exe'))
        'tscon available' = (Test-TsconAvailable)
        'SeTcbPrivilege granted to Administrators' = (Test-DashboardTcbPrivilegeGranted)
        'Remote Desktop Plus installed' = (Test-Path -LiteralPath (Resolve-RemoteDesktopPlusPath))
        'Dashboard installed' = (Test-Path -LiteralPath (Join-Path $script:InstallRoot 'Dashboard.ps1'))
    }
    $checks.GetEnumerator() | ForEach-Object { [pscustomobject]@{ Check=$_.Key; Passed=[bool]$_.Value } }
}

Export-ModuleMember -Function *-Dashboard*,Install-*,Test-*,New-DashboardUser,Start-DashboardSession,Stop-DashboardSession,Connect-DashboardRdp,Keep-Alive-DashboardRdp,Connect-DashboardMoonlight,Assert-Administrator,Set-DashboardPaths,Invoke-RdpWrapperInstaller,Get-RdpEndpoint,Get-DashboardState,Get-RemoteDesktopUsers,Get-UserSession,Get-UserSessions,Get-UserRdpSessionId,Get-UserConsoleSession,Maintain-DashboardSession,Invoke-DashboardRdpBootstrap,Get-DefaultDashboardStateEntry
