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

function global:Add-DashboardWindowType {
    <#
        Shared by Set-DashboardWindowProperties and
        Start-DashboardHeadlessWindowWatcher -- split out so the watcher's
        background runspace (which imports this module fresh, same as
        every Start-DashboardBackgroundTask consumer) can call it too
        without duplicating the Add-Type block.
    #>
    if (-not ('BetterRdp.Window' -as [type])) {
        # No -UsingNamespace: Add-Type -MemberDefinition already includes
        # `using System.Runtime.InteropServices;` by default, and passing
        # it again fails to compile (CS0105) -- see the matching comment
        # in SessionManager.psm1's Add-DashboardWtsApiType, where this was
        # actually caught. EnumWindowsProc is a nested delegate type here
        # (valid C# inside a class body), the same pattern already used for
        # BetterRdp.Wts+WTS_SESSION_INFO's nested struct in
        # SessionManager.psm1.
        Add-Type -Namespace BetterRdp -Name Window -MemberDefinition @'
public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

[DllImport("user32.dll")]
public static extern bool EnumWindows(EnumWindowsProc enumProc, IntPtr lParam);

[DllImport("user32.dll")]
public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

[DllImport("user32.dll")]
public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

[DllImport("user32.dll", CharSet = CharSet.Auto)]
public static extern bool SetWindowText(IntPtr hWnd, string lpString);
'@
    }
}

function global:Update-DashboardWindowOnce {
    <#
        Single pass: enumerate every top-level window owned by $ProcessId
        (via EnumWindows + GetWindowThreadProcessId, not
        Process.MainWindowHandle -- see Set-DashboardWindowProperties'
        comment for why) and apply -Title/-Minimize to each match. Returns
        the number of matching windows found, so callers can tell "process
        alive but genuinely has no window yet" apart from "found some and
        applied to them".
    #>
    param(
        [Parameter(Mandatory)][int]$ProcessId,
        [string]$Title,
        [switch]$Minimize
    )
    Add-DashboardWindowType
    $SW_HIDE = 0

    $handles = [System.Collections.Generic.List[IntPtr]]::new()
    $callback = [BetterRdp.Window+EnumWindowsProc]{
        param([IntPtr]$hWnd, [IntPtr]$lParam)
        $ownerPid = [uint32]0
        [void][BetterRdp.Window]::GetWindowThreadProcessId($hWnd, [ref]$ownerPid)
        if ($ownerPid -eq [uint32]$ProcessId) { [void]$handles.Add($hWnd) }
        return $true
    }.GetNewClosure()
    [void][BetterRdp.Window]::EnumWindows($callback, [IntPtr]::Zero)

    foreach ($handle in $handles) {
        if (-not [string]::IsNullOrEmpty($Title)) {
            [BetterRdp.Window]::SetWindowText($handle, $Title) | Out-Null
        }
        if ($Minimize) {
            [BetterRdp.Window]::ShowWindow($handle, $SW_HIDE) | Out-Null
        }
    }
    return $handles.Count
}

function global:Set-DashboardWindowProperties {
    <#
        Best-effort title-set and/or hide of every top-level window owned by
        an rdp.exe process, re-applied every 500ms for up to $TimeoutSeconds.
        Used right after a connect for immediate feedback -- see
        Start-DashboardHeadlessWindowWatcher for the persistent, whole-
        lifetime version of this used for headless loopback connections,
        which this bounded call alone was NOT enough for in practice (a
        real report: the headless window stayed visible indefinitely, not
        just briefly -- RDP+ apparently can (re)show/restore its own window
        well after this function's fixed window has already elapsed, and
        nothing was left watching for that).

        Deliberately does NOT use Process.MainWindowHandle: that's a .NET
        heuristic that picks (at most) one window per process by its own
        rules, isn't guaranteed to track the actual final/visible window if
        the process shows more than one top-level window over its lifetime
        (e.g. an initial dialog later replaced by the real session view),
        and was the previous approach here -- confirmed not reliably
        working for hiding the window even after several rounds of
        persistence/timeout tuning. This instead walks every top-level
        window on the system via EnumWindows, matches by owning process ID
        via GetWindowThreadProcessId (not any single-window heuristic), and
        applies to every match, not just one.
    #>
    param(
        [Parameter(Mandatory)][int]$ProcessId,
        [string]$Title,
        [switch]$Minimize,
        [int]$TimeoutSeconds = 20
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        try {
            $null = Get-Process -Id $ProcessId -ErrorAction Stop
        } catch {
            return
        }

        Update-DashboardWindowOnce -ProcessId $ProcessId -Title $Title -Minimize:$Minimize | Out-Null

        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
}

function global:Start-DashboardHeadlessWindowWatcher {
    <#
        Keeps re-hiding (and re-titling) an armed headless loopback's
        window for as long as its rdp.exe process is alive -- not just for
        a bounded window right after connect. A headless connection can
        stay armed for a long time (until an interactive Connect displaces
        it or Stop tears it down), and a real report confirmed the bounded
        Set-DashboardWindowProperties call alone wasn't enough: the window
        was still visible, not just briefly flashing before being hidden --
        so whatever shows/restores it can happen well outside any fixed
        timeout this function's caller might pick. This has no such limit;
        it just keeps polling every 750ms until the process itself exits,
        at which point the loop (and this background runspace) ends on its
        own -- nothing else needs to stop it.

        Fire-and-forget by design, same shape as
        Start-DashboardBackgroundTask's use of a dedicated MTA runspace,
        except there's no -OnSuccess/-OnError/-OnComplete to wire up here:
        nothing needs to observe this loop's completion, only its ongoing
        side effect (the window staying hidden). Started from
        Invoke-DashboardRdpBootstrap immediately after the existing bounded
        Set-DashboardWindowProperties call, only when -Minimize was used.
    #>
    param([Parameter(Mandatory)][int]$ProcessId, [string]$Title)

    # Prefer this module file's own directory (works from a local checkout
    # too, not just an installed copy), same reasoning as
    # Start-DashboardBackgroundTask in MultiSessionDashboard.psm1 -- but
    # unlike that function, this one can't fall back to $script:InstallRoot
    # directly: that variable belongs to MultiSessionDashboard.psm1's own
    # script scope, not this module's, and Set-StrictMode -Version Latest
    # throws on referencing it from here (confirmed by reproducing it).
    # Get-DashboardInstallRoot is the kernel's own accessor for the same
    # value, safe to call from any module.
    $moduleRoot = Get-DashboardInstallRoot
    if ($PSScriptRoot) { $moduleRoot = $PSScriptRoot }

    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.ApartmentState = [System.Threading.ApartmentState]::MTA
    $runspace.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
    $runspace.Open()

    $ps = [powershell]::Create()
    $ps.Runspace = $runspace
    [void]$ps.AddScript({
        param($ModuleRoot, $ProcessId, $Title)
        Import-Module (Join-Path $ModuleRoot 'MultiSessionDashboard.psm1') -Force
        while ($true) {
            try { $null = Get-Process -Id $ProcessId -ErrorAction Stop } catch { break }
            try { Update-DashboardWindowOnce -ProcessId $ProcessId -Title $Title -Minimize | Out-Null } catch {}
            Start-Sleep -Milliseconds 750
        }
    })
    [void]$ps.AddArgument($moduleRoot)
    [void]$ps.AddArgument($ProcessId)
    [void]$ps.AddArgument($Title)

    # Intentionally not tracked/EndInvoke'd/disposed: this loop's own exit
    # condition (the process going away) is its only defined lifetime, and
    # nothing here needs to react to that beyond the loop just stopping.
    # $ps/$runspace stay referenced by the in-flight async operation itself
    # until the script block returns, then become eligible for normal GC.
    [void]$ps.BeginInvoke()
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
    #
    # /title: sets the window title -- distinguishing a headless anchor
    # ("RDP-<user>-Headless") from a real interactive session
    # ("RDP-<user>"), e.g. in Task Manager or Alt-Tab. This is on the
    # command line, not just via the after-the-fact SetWindowText in
    # Set-DashboardWindowProperties (kept below as a harmless backup):
    # SetWindowText alone did not reliably show up, and /title: is a real,
    # user-confirmed RDP+ flag (verified by direct testing, not fetched
    # "documentation" -- see the /batch and /log note further up).
    $windowTitle = if ($Minimize) { "RDP-$Username-Headless" } else { "RDP-$Username" }
    $rdpFile = New-DashboardRdpFile -Username $Username
    $arguments = @(
        "`"$rdpFile`"",
        "/v:$($script:RdpHost):$($script:RdpPort)",
        "/u:.\$Username",
        "/p:$Username",
        "/title:`"$windowTitle`""
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

    # Backup title-set (see the /title: comment above) plus the real
    # minimize; only minimizing is conditional on -Minimize.
    Set-DashboardWindowProperties -ProcessId $process.Id -Title $windowTitle -Minimize:$Minimize

    # A bounded pass right after connect isn't enough on its own for a
    # headless anchor -- confirmed by a real report where the window
    # stayed visible, not just briefly, well past when the call above
    # would have stopped trying. A headless connection can also sit armed
    # for a long time before anything displaces it, so keep watching (and
    # re-hiding) it for as long as its process lives, not just for the
    # first ~20 seconds after connect.
    if ($Minimize) {
        Start-DashboardHeadlessWindowWatcher -ProcessId $process.Id -Title $windowTitle
    }

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

function global:Invoke-DashboardBetterRdpTweak {
    <#
        Runs the installed copy of BetterRDP.ps1 (scripts/BetterRDP/, see
        Install-MultiSessionDashboard.ps1's copy step and install.ps1's
        staging step -- neither wired this in until the "RDP Tweaks" button
        needed it) non-interactively for the "RDP Tweaks" button.

        Shells out to a child powershell.exe rather than dot-sourcing the
        script into this runspace: BetterRDP.ps1 declares a `class` at its
        top level, and PowerShell throws if a class with the same name is
        defined a second time in a runspace that's already loaded it once
        -- which background runspaces here are, since
        Start-DashboardBackgroundTask reuses its thread/runspace machinery
        across calls. A child process sidesteps that entirely and also
        keeps BetterRDP.ps1's own #Requires -RunAsAdministrator check and
        machine-wide registry writes cleanly isolated from this process.
        The child inherits this process's elevation token automatically
        (no separate UAC prompt), since the dashboard itself already
        requires an elevated session (Assert-Administrator below).

        Returns the script's captured Write-Host/output text as a single
        string, which Dashboard.ps1's "RDP Tweaks" button shows directly in
        a MessageBox -- Validate-Optimizations' pass/fail summary and
        Apply-RDPOptimizations'/Apply-GamingRDPOptimizations' "reboot is
        required" note are both meant to be read, not just acted on.
    #>
    param([Parameter(Mandatory)][ValidateSet('Backup', 'Apply', 'ApplyGaming', 'Validate')][string]$Action)
    Assert-Administrator

    $scriptPath = Join-Path (Get-DashboardInstallRoot) 'BetterRDP\BetterRDP.ps1'
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        throw "BetterRDP tweaks script was not found at '$scriptPath'. Re-run the installer (irm ... | iex, or Install-MultiSessionDashboard.ps1 from a checkout) to fetch it."
    }

    $psExe = Join-Path $PSHOME 'powershell.exe'
    if (-not (Test-Path -LiteralPath $psExe)) { $psExe = 'powershell.exe' }

    $output = & $psExe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -Action $Action 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        throw "BetterRDP tweaks ($Action) exited with code ${LASTEXITCODE}:`n$output"
    }
    return $output.Trim()
}

Export-ModuleMember -Function *
