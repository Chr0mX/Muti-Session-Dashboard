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
    param(
        [string]$Source = 'https://github.com/sergiye/rdpWrapper/releases/latest/download/rdpWrapper_x64.exe',
        [string[]]$InstallArguments = @('-install'),
        [int]$InstallTimeoutSeconds = 600
    )
    New-DirectoryIfMissing -Path $script:RdpWrapperRoot
    $extension = [IO.Path]::GetExtension(([Uri]$Source).AbsolutePath)
    if ([string]::IsNullOrWhiteSpace($extension)) { $extension = '.download' }
    $package = Join-Path $env:TEMP "rdpWrapper$extension"
    Invoke-DownloadFile -Uri $Source -Destination $package -CacheName 'rdpWrapper' | Out-Null

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
        throw "Unsupported RDP Wrapper package type '$extension' from $Source"
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
            $state[$user.Username] = @{
                Username = $user.Username
                AccountName = $user.AccountName
                SunshinePort = $null
                SessionState = 'Stopped'
                SunshineState = 'Stopped'
                RdpSessionId = $null
                RdpConnectionStatus = 'Disconnected'
            }
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
    if (-not (Test-Path -LiteralPath $script:RdpPlusPath)) {
        throw "Remote Desktop Plus was not found at '$script:RdpPlusPath'. Re-run the installer to install it."
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
    Start-Process -FilePath $script:RdpPlusPath -ArgumentList $arguments | Out-Null

    $session = Wait-DashboardRdpSession -Username $Username -TimeoutSeconds 30
    if ($null -eq $session) {
        throw "RDP login for '$Username' did not produce an active RDP session within 30 seconds."
    }
    return $session
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

function Get-DashboardState {
    New-DirectoryIfMissing -Path $script:ConfigRoot
    if (-not (Test-Path -LiteralPath $script:StateFile)) { return @{} }
    $json = Get-Content -LiteralPath $script:StateFile -Raw
    if ([string]::IsNullOrWhiteSpace($json)) { return @{} }
    $obj = $json | ConvertFrom-Json
    return (ConvertTo-HashtableRecursive $obj)
}

function Save-DashboardState { param([hashtable]$State) $State | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:StateFile -Encoding UTF8 }

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
    $used = @($state.Values | ForEach-Object { if ($_.SunshinePort) { [int]$_.SunshinePort } })
    foreach ($port in $script:PortStart..$script:PortEnd) {
        if ($used -contains $port) { continue }
        # Never probe 127.0.0.1 with Test-NetConnection. If a local process is
        # already listening, Get-NetTCPConnection can identify the collision
        # without opening a connection or waiting for a response.
        $listener = Get-NetTCPConnection -LocalAddress '0.0.0.0','127.0.0.1','::','::1' -LocalPort $port -State Listen -ErrorAction SilentlyContinue
        if ($null -ne $listener) { continue }
        if ($Reserve) {
            $state[$Username] = @{ Username=$Username; SunshinePort=$port; SessionState='Stopped'; SunshineState='Stopped'; RdpSessionId=$null; RdpConnectionStatus='Disconnected' }
            Save-DashboardState -State $state
        }
        return $port
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
    if (-not (Test-TsconAvailable)) { throw 'Windows tscon.exe is required but was not found.' }

    # 1) Create a real 1920x1080 RDP login for the selected user using native mstsc,
    #    against the per-user RDP alias with the saved Windows credential.
    $rdpSession = Invoke-DashboardRdpBootstrap -Username $Username

    # 2) Hand the RDP session to the local console so the Windows session survives.
    Invoke-TsconToConsole -SessionId $rdpSession.SessionId

    # 3) Confirm the Windows session is still online after the handoff.
    Start-Sleep -Milliseconds 750
    $online = Get-UserSession -Username $Username
    if ($null -eq $online -or -not $online.Online) {
        throw "RDP session for '$Username' was handed off with tscon, but the user is not reported Active by Windows."
    }

    # 4) Start Sunshine only after the Windows user session is online.
    $port = Get-AllocatedPort -Username $Username -Reserve
    Set-UserSunshineConfig -Username $Username -Port $port
    $sunshine = Join-Path (Join-Path 'C:\Users' $Username) 'AppData\Local\Muti Session Dashboard\Sunshine\Sunshine.exe'
    $conf = Join-Path (Join-Path 'C:\Users' $Username) 'AppData\Local\Muti Session Dashboard\Config\sunshine.conf'
    Start-Process -FilePath $sunshine -ArgumentList @($conf) -LoadUserProfile | Out-Null

    $state = Get-DashboardState
    $state[$Username].RdpSessionId = $online.SessionId
    $state[$Username].RdpConnectionStatus = 'Online'
    $state[$Username].SessionState = 'Running'
    $state[$Username].SunshineState = 'Running'
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
    Start-Process -FilePath $moonlight -ArgumentList @('--display-mode','windowed','--resolution','1920x1080')
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
    if ($state.ContainsKey($Username)) { $state[$Username].SunshinePort = $null; $state[$Username].SessionState='Stopped'; $state[$Username].SunshineState='Stopped'; $state[$Username].RdpConnectionStatus='Disconnected'; Save-DashboardState -State $state }
}

function Test-DashboardInstallation {
    $checks = [ordered]@{
        'RDP Wrapper installed' = (Test-Path -LiteralPath $script:RdpWrapperRoot)
        'TermWrap configured' = (Test-RdpWrapperConfiguration).Success
        'Remote Desktop enabled' = (((Get-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -ErrorAction SilentlyContinue).fDenyTSConnections) -eq 0)
        'Moonlight downloaded' = (Test-Path -LiteralPath (Join-Path $script:InstallRoot 'Stream\Moonlight\Moonlight.exe'))
        'Sunshine downloaded' = (Test-Path -LiteralPath (Join-Path $script:InstallRoot 'Stream\Sunshine\Sunshine.exe'))
        'tscon available' = (Test-TsconAvailable)
        'Remote Desktop Plus installed' = (Test-Path -LiteralPath $script:RdpPlusPath)
        'Dashboard installed' = (Test-Path -LiteralPath (Join-Path $script:InstallRoot 'Dashboard.ps1'))
    }
    $checks.GetEnumerator() | ForEach-Object { [pscustomobject]@{ Check=$_.Key; Passed=[bool]$_.Value } }
}

Export-ModuleMember -Function *-Dashboard*,Install-*,Test-*,New-DashboardUser,Start-DashboardSession,Stop-DashboardSession,Connect-DashboardRdp,Keep-Alive-DashboardRdp,Connect-DashboardMoonlight,Assert-Administrator,Set-DashboardPaths,Invoke-RdpWrapperInstaller,Get-RdpEndpoint,Get-DashboardState,Get-RemoteDesktopUsers,Get-UserSession,Get-UserSessions,Get-UserRdpSessionId,Get-UserConsoleSession,Maintain-DashboardSession,Invoke-DashboardRdpBootstrap
