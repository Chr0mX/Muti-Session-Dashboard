<#
    RdpManager.psm1 -- RDP launching and the Remote Desktop Plus dependency.

    Owns everything about actually starting an automated RDP client
    connection: locating/installing Remote Desktop Plus, generating the
    per-user .rdp settings file (smart sizing and friends), launching it,
    and minimizing it for a headless loopback connection. Also owns the
    "Open RDP Wrapper" manager-launch helper, since that's RDP tooling too.

    See SessionManager.psm1's header comment for why every function here is
    `function global:Verb-Noun`. This module is meant to be loaded through
    MultiSessionDashboard.psm1, not imported standalone -- it calls kernel
    functions (Assert-Administrator, New-DirectoryIfMissing,
    Invoke-DownloadFile, Get-DashboardConfigRoot) and SessionManager's
    Wait-DashboardRdpSession.
#>

Set-StrictMode -Version Latest

# RDP Wrapper's concurrent multi-session support is more reliable connecting
# through a distinct loopback address than through 127.0.0.1 -- this is kept
# regardless of whether a session ever touches the console.
$script:RdpHost = '127.0.0.2'
$script:RdpPort = 3389
$script:RdpPlusPath = 'C:\Program Files (x86)\Remote Desktop Plus\rdp.exe'
$script:RdpWrapperManagerPath = 'C:\Program Files\RDP Wrapper\rdpWrapper_x64.exe'
$script:RdpFileCacheRoot = $null

function global:Set-RdpManagerPaths {
    <#
        Called by the coordinator's Set-DashboardPaths whenever InstallRoot
        changes, so this module's derived paths stay in sync without this
        module needing to own $script:ConfigRoot itself.
    #>
    param([Parameter(Mandatory)][string]$ConfigRoot)
    $script:RdpFileCacheRoot = Join-Path $ConfigRoot 'RdpFiles'
}

# Initialize from whatever the kernel's default ConfigRoot is at load time;
# Set-RdpManagerPaths keeps this in sync if Set-DashboardPaths is called
# later (e.g. by the installer with a custom -InstallRoot).
if (Get-Command -Name Get-DashboardConfigRoot -ErrorAction SilentlyContinue) {
    Set-RdpManagerPaths -ConfigRoot (Get-DashboardConfigRoot)
}

function global:Get-RdpEndpoint {
    return "$($script:RdpHost):$($script:RdpPort)"
}

function global:Install-RemoteDesktopPlus {
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

function global:Resolve-RemoteDesktopPlusPath {
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

function global:New-DashboardRdpFile {
    <#
        Remote Desktop Plus (rdp.exe) accepts an .rdp settings file as a
        positional argument alongside its own /u: /p: overrides, so any
        setting normally only available in an .rdp file -- like
        "smart sizing:i:1" -- goes here instead of trying to invent a
        CLI flag for it that rdp.exe doesn't have.
    #>
    param([Parameter(Mandatory)][string]$Username)

    if ([string]::IsNullOrWhiteSpace($script:RdpFileCacheRoot)) {
        Set-RdpManagerPaths -ConfigRoot (Get-DashboardConfigRoot)
    }
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

function global:Set-DashboardWindowMinimized {
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
        # No -UsingNamespace: Add-Type -MemberDefinition already includes
        # `using System.Runtime.InteropServices;` by default, and passing
        # it again fails to compile (CS0105) -- see the matching comment
        # in SessionManager.psm1's Add-DashboardWtsApiType, where this was
        # actually caught.
        Add-Type -Namespace BetterRdp -Name Window -MemberDefinition @'
[DllImport("user32.dll")]
public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'@
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

function global:Invoke-DashboardRdpBootstrap {
    <#
        Launches a fully automated RDP login for a dashboard-managed account
        via Remote Desktop Plus, then verifies (does not assume) that the
        session actually came up by polling the real, live-detected session
        ID via Wait-DashboardRdpSession. Connecting to the SAME endpoint for
        a user who already has a disconnected session reconnects it --
        standard RDP behavior -- so this doubles as both a fresh connect and
        any later reconnect. No tscon, no console hand-off.

        -Minimize is used by Start-DashboardHeadlessLoopback to arm a
        background/anchor connection that keeps the session alive without
        an RDP window sitting in the operator's way; a later interactive
        Connect-DashboardRdp call reconnects the same session with a new,
        visible client, which displaces (disconnects) the minimized one
        automatically -- standard RDP behavior, not something this script
        has to orchestrate itself.

        Meant to be called from a background runspace (it blocks for up to
        45 seconds waiting for the session to come up) -- see this module's
        header comment and Start-DashboardBackgroundTask.
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
    # /batch is RDP+'s own documented "script mode" flag: it prevents RDP+
    # from showing its own error messages/prompts, which is what was
    # popping up instead of an instant, silent connect -- confirmed against
    # RDP+'s actual documented command-line syntax (donkz.nl), not assumed.
    $rdpFile = New-DashboardRdpFile -Username $Username
    $arguments = @(
        "`"$rdpFile`"",
        "/u:.\$Username",
        "/p:$Username",
        '/batch'
    )

    Write-Host "Starting Remote Desktop Plus for '$Username' at 1920x1080."
    $process = Start-Process -FilePath $rdpPlusPath -ArgumentList $arguments -PassThru

    # 45s, not 30s: a first-ever logon (profile creation, GPU/driver init)
    # can genuinely take longer than 30s. This is a blocking wait, which is
    # exactly why this whole function must run off the UI thread.
    $session = Wait-DashboardRdpSession -Username $Username -TimeoutSeconds 45
    if ($null -eq $session) {
        # This exact timeout has been reported as a false failure before --
        # `query session` independently shows the account Active while this
        # wait still times out. Rather than guess again at what's wrong with
        # detection, dump exactly what Get-UserSessions/Get-AllUserSessions
        # actually saw for this user (every session found, whatever its
        # state, plus which detection path -- WTS or the quser fallback --
        # served it) directly into the error, so the next report is a
        # diagnosis instead of a repeat of the same unexplained symptom.
        $sourceInfo = Get-DashboardSessionSourceInfo
        $observedSessions = @(Get-UserSessions -Username $Username)
        $dump = if ($observedSessions.Count -eq 0) {
            'none'
        } else {
            ($observedSessions | ForEach-Object {
                "SessionId=$($_.SessionId) SessionName='$($_.SessionName)' State=$($_.State) Online=$($_.Online) IsRdp=$($_.IsRdp)"
            }) -join '; '
        }
        $fallbackNote = if ($sourceInfo.FallbackReason) { " (fell back because: $($sourceInfo.FallbackReason))" } else { '' }
        throw "RDP login for '$Username' did not produce an active RDP session within 45 seconds. Detection source: $($sourceInfo.Source)$fallbackNote. Sessions observed for '$Username': $dump. Run 'query session' to compare against what Windows itself reports."
    }

    if ($Minimize) { Set-DashboardWindowMinimized -ProcessId $process.Id }

    return [pscustomobject]@{
        Username  = $session.Username
        SessionId = $session.SessionId
        ProcessId = $process.Id
    }
}

function global:Open-DashboardRdpWrapperManager {
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

Export-ModuleMember -Function *
