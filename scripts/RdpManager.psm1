<#
    RdpManager.psm1 -- RDP launching and the Remote Desktop Plus dependency.

    Owns everything about actually starting an automated RDP client
    connection: locating/installing Remote Desktop Plus, generating the
    per-user .rdp settings file (smart sizing and friends), launching it,
    titling its window ("RDP-<user>-Headless" for an armed headless
    loopback, "RDP-<user>" for a real interactive session), and minimizing
    it for a headless loopback connection. Also owns the "Open RDP
    Wrapper" manager-launch helper, since that's RDP tooling too.

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

function global:Set-DashboardWindowProperties {
    <#
        Best-effort title-set and/or minimize of an rdp.exe process's main
        window. Used for two things:
          - Giving every RDP+ window a distinguishable title
            ("RDP-<user>-Headless" for an armed headless loopback,
            "RDP-<user>" for a real interactive session), via SetWindowText.
          - Keeping an "armed" headless loopback connection out of the
            operator's way, via ShowWindow(SW_MINIMIZE), when -Minimize is
            passed. This is the ONLY minimize mechanism -Minimize uses --
            see Invoke-DashboardRdpBootstrap's comment for why Start-Process
            -WindowStyle Minimized was tried and reverted (it crashes RDP+
            outright, a real bug in RDP+'s own startup code).

        A single one-shot "find the handle once, apply, and stop" was not
        enough in practice for minimizing: a window that appears late (or
        gets replaced/re-shown partway through RDP negotiation) can end up
        visible anyway. The same reasoning applies to the title, so this
        keeps re-applying whatever was requested for the whole timeout
        window -- cheap and idempotent -- rather than a single pass.
        Failure here is still non-fatal -- the RDP session itself is what
        matters; a window whose title/minimize state couldn't be set is
        just a cosmetic miss.
    #>
    param(
        [Parameter(Mandatory)][int]$ProcessId,
        [string]$Title,
        [switch]$Minimize,
        [int]$TimeoutSeconds = 15
    )

    if (-not ('BetterRdp.Window' -as [type])) {
        # No -UsingNamespace: Add-Type -MemberDefinition already includes
        # `using System.Runtime.InteropServices;` by default, and passing
        # it again fails to compile (CS0105) -- see the matching comment
        # in SessionManager.psm1's Add-DashboardWtsApiType, where this was
        # actually caught.
        Add-Type -Namespace BetterRdp -Name Window -MemberDefinition @'
[DllImport("user32.dll")]
public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

[DllImport("user32.dll", CharSet = CharSet.Auto)]
public static extern bool SetWindowText(IntPtr hWnd, string lpString);
'@
    }
    $SW_MINIMIZE = 6

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        try {
            $proc = Get-Process -Id $ProcessId -ErrorAction Stop
            $proc.Refresh()
            if ($proc.MainWindowHandle -ne [IntPtr]::Zero) {
                if (-not [string]::IsNullOrEmpty($Title)) {
                    [BetterRdp.Window]::SetWindowText($proc.MainWindowHandle, $Title) | Out-Null
                }
                if ($Minimize) {
                    [BetterRdp.Window]::ShowWindow($proc.MainWindowHandle, $SW_MINIMIZE) | Out-Null
                }
            }
        } catch {
            return
        }
        Start-Sleep -Milliseconds 500
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
    #
    # /batch and /log were added here at one point on the belief that they
    # were RDP+'s own documented flags. They were not: that "documentation"
    # came from a fetch against RDP+'s installer .msi binary, which the
    # fetch tool itself said had no readable docs -- yet it returned a
    # suspiciously complete-looking syntax reference anyway, a hallucination
    # this project trusted for too long. A real web search plus fetching
    # donkz.nl's actual settings/companion-tools pages directly turned up no
    # mention of /batch or /log anywhere. Passing unrecognized switches is
    # the likely reason RDP+ went from "connects but shows its own window"
    # to "never completes the connection at all" (the session landing in
    # Disconnected with no session name -- rdp.exe never got that far).
    # Removed both; back to the minimal, verifiable command line.
    # /v: is added explicitly here, not just relied on via the .rdp file's
    # own "full address:" line, because of what was actually observed:
    # without it, RDP+ shows its main connect dialog pre-filled with the
    # right target/user/password but waiting for someone to click
    # "Connect" -- it never auto-connects. That matches the documented
    # syntax's own pattern (`rdp ["connection file"] [/v:computer...]
    # [/u:...] [/p:...] ...`), where /v: on the command line is what
    # actually triggers a direct/automatic connect; a target that only
    # exists inside the referenced file appears to just pre-fill the GUI
    # for manual confirmation instead.
    $rdpFile = New-DashboardRdpFile -Username $Username
    $arguments = @(
        "`"$rdpFile`"",
        "/v:$($script:RdpHost):$($script:RdpPort)",
        "/u:.\$Username",
        "/p:$Username"
    )

    Write-Host "Starting Remote Desktop Plus for '$Username' at 1920x1080."
    # -Minimize deliberately does NOT use Start-Process -WindowStyle
    # Minimized, even though that's normally the more reliable mechanism
    # for this. It was tried and reverted: it crashes RDP+ outright with
    # "System.ArgumentException: Parameter is not valid" inside
    # System.Drawing.Bitmap..ctor, thrown from RDP+'s own Form.OnLoad --
    # a real bug in RDP+ itself, where it allocates a bitmap sized to its
    # client area during startup without handling the client area being
    # zero-sized, which is exactly what a window created already-minimized
    # has. Creating the window NORMAL-sized first and minimizing it
    # afterward (once it already has real dimensions) avoids ever
    # triggering that path. Set-DashboardWindowProperties below is that
    # after-the-fact minimize (and title-set), kept persistent (re-applies
    # for its whole timeout window) specifically so it still catches a
    # window that appears late or gets replaced during connection
    # negotiation, without needing the startup-minimized approach that
    # crashes this particular app.
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

        # Still real, verifiable diagnostic info: whether rdp.exe is even
        # still alive, and its exit code if not, gathered directly from the
        # process object -- unlike the removed /log flag, this needs no
        # unverified RDP+-specific switch.
        $processNote = try {
            $proc = Get-Process -Id $process.Id -ErrorAction Stop
            "rdp.exe (PID $($process.Id)) is still running."
        } catch {
            "rdp.exe (PID $($process.Id)) has already exited (exit code $($process.ExitCode))."
        }

        throw "RDP login for '$Username' did not produce an active RDP session within 45 seconds. $processNote Detection source: $($sourceInfo.Source)$fallbackNote. Sessions observed for '$Username': $dump. Run 'query session' to compare against what Windows itself reports."
    }

    # Title always gets set, whether this is a headless anchor or a real
    # interactive session, so the two are distinguishable (e.g. in Task
    # Manager or Alt-Tab) -- only minimizing is conditional on -Minimize.
    $windowTitle = if ($Minimize) { "RDP-$Username-Headless" } else { "RDP-$Username" }
    Set-DashboardWindowProperties -ProcessId $process.Id -Title $windowTitle -Minimize:$Minimize

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
