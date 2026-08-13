<#
    SessionManager.psm1 -- Windows session detection and monitoring.

    Owns nothing but the ability to answer "what Terminal Services sessions
    exist on this machine right now, and what state are they in". No RDP
    launching, no user/group management, no headless-loopback bookkeeping.

    Every function here is defined as `function global:Verb-Noun` rather
    than relying on module export/import scoping. This project is a single
    WinForms desktop app that always loads every one of its modules into one
    shared runspace (via MultiSessionDashboard.psm1's coordinator import at
    the bottom of that file) -- not a general-purpose reusable library -- so
    plain global functions are the simplest, most robust way to make every
    module's functions callable from every other module and from background
    runspaces, without fighting PowerShell's per-module scope boundaries.
    This module is meant to be loaded through MultiSessionDashboard.psm1,
    not imported standalone.

    IMPORTANT: none of the Wait-* functions here pump a WinForms message
    loop. They are meant to run inside a background runspace (see
    Start-DashboardBackgroundTask in MultiSessionDashboard.psm1), never on
    the UI thread, so a plain Start-Sleep poll loop is correct and safe --
    calling Application.DoEvents() from a non-UI thread would be wrong.
#>

Set-StrictMode -Version Latest

# Diagnostic state for Get-DashboardSessionSourceInfo -- must exist from
# module load, not just after Get-AllUserSessions first runs, since
# Set-StrictMode throws on reading an unset $script: variable even inside
# an `if ($script:X)` truthiness check.
$script:LastSessionSource = $null
$script:LastSessionSourceError = $null

function global:Add-DashboardWtsApiType {
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
'@
    # No -UsingNamespace here: Add-Type -MemberDefinition already includes
    # `using System.Runtime.InteropServices;` in its generated wrapper by
    # default (that mode exists specifically for P/Invoke declarations), so
    # passing it again used to make every single call to this function
    # fail to compile with CS0105 ("using directive ... appeared
    # previously") -- confirmed by reproducing it in isolation. That
    # silently sent every session query down the quser text-parsing
    # fallback instead of the WTS API this function exists for.
}

function global:Get-AllUserSessions {
    <#
        Enumerates every Terminal Services session on this machine (all
        users, not just one) via the WTS API -- the primary, reliable
        source Get-UserSessions filters against. Falls back to parsing
        `quser` text output only if the WTS call itself fails outright
        (e.g. wtsapi32.dll unavailable), since a fragile text parse is
        still better than no data at all. The actual session ID always
        comes from this live enumeration -- nothing in this project ever
        hard-codes a session number.
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
        # Record which path actually produced data, and reset any stale
        # failure note from a previous call -- Get-DashboardSessionSourceInfo
        # lets a caller that hits an unexpected empty/missing result find
        # out, after the fact, whether WTS genuinely ran or silently fell
        # back, without having to pass -Verbose through a background
        # runspace (which nothing here does).
        $script:LastSessionSource = 'WTS'
        $script:LastSessionSourceError = $null
        return @($results)
    } catch {
        # This used to be Write-Verbose, which is invisible by default --
        # including inside the background runspaces every RDP
        # connect/wait/monitor pass now runs in, so a silent fallback here
        # was never actually seen by anyone. Write-Warning surfaces in the
        # PowerShell host's normal error/warning stream even from a
        # background runspace's captured streams, and the message is also
        # stashed for Get-DashboardSessionSourceInfo to report on-demand.
        $script:LastSessionSource = 'quser-fallback'
        $script:LastSessionSourceError = $_.Exception.Message
        Write-Warning "WTS session enumeration failed; falling back to quser text parsing. $($_.Exception.Message)"
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

function global:Get-DashboardSessionSourceInfo {
    <#
        Reports whether the most recent Get-AllUserSessions call was
        served by the primary WTS API path or fell back to parsing
        `quser` text output, and why, if it fell back. Purely a
        diagnostic -- used to enrich Invoke-DashboardRdpBootstrap's
        timeout error with enough detail to actually tell what happened
        instead of guessing.
    #>
    [pscustomobject]@{
        Source = if ($script:LastSessionSource) { $script:LastSessionSource } else { 'unknown (Get-AllUserSessions not yet called)' }
        FallbackReason = $script:LastSessionSourceError
    }
}

function global:Get-UserSessions {
    param([Parameter(Mandatory)][string]$Username)
    return @(Get-AllUserSessions | Where-Object { $_.Username -ieq $Username })
}

function global:Get-UserSession {
    param([Parameter(Mandatory)][string]$Username)
    $sessions = @(Get-UserSessions -Username $Username)
    if ($sessions.Count -eq 0) { return $null }
    $console = $sessions | Where-Object { $_.IsConsole -and $_.Online } | Select-Object -First 1
    if ($null -ne $console) { return $console }
    $active = $sessions | Where-Object { $_.Online } | Select-Object -First 1
    if ($null -ne $active) { return $active }
    return ($sessions | Select-Object -First 1)
}

function global:Get-UserRdpSessionId {
    param([Parameter(Mandatory)][string]$Username)
    return @(Get-UserSessions -Username $Username | Where-Object { $_.IsRdp } | Sort-Object SessionId | Select-Object -First 1)
}

function global:Wait-DashboardRdpSession {
    <#
        Polls (blocking) until the user's actual, live-detected session ID
        shows Online (Active/Connected), or the timeout elapses. Meant to
        be called from a background runspace -- see this module's header
        comment -- so it deliberately does not pump any UI message loop.

        Deliberately does NOT require IsRdp/a 'RDP-Tcp*' session-name match
        here: a dashboard-managed local account has no legitimate session
        type other than RDP in this architecture, so gating on the session
        name adds a possible false-negative (e.g. if RDP Wrapper ever
        reports a session name that doesn't match the expected pattern)
        without adding any real safety -- Online plus the right username is
        already a sufficient, unambiguous signal that the login succeeded.
    #>
    param([Parameter(Mandatory)][string]$Username,[int]$TimeoutSeconds=30,[int[]]$IgnoreSessionIds=@())
    $deadline=(Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $session=@(Get-UserSessions -Username $Username | Where-Object { $_.Online -and ($IgnoreSessionIds -notcontains $_.SessionId) } | Sort-Object SessionId | Select-Object -First 1)
        if ($null -ne $session -and @($session).Count -gt 0) { return $session[0] }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    return $null
}

function global:Wait-DashboardSessionClosed {
    <#
        Polls (blocking) until the user has no Online session left -- used
        by Stop-DashboardSession to verify the sign-off actually took
        effect, and by the dashboard's monitor to confirm an interactive
        session has really gone before re-arming a headless loopback for
        it. Returns $true once confirmed closed/offline, $false on timeout
        (the caller is still free to proceed; this is a verification step,
        not a hard gate). Meant to run inside a background runspace.
    #>
    param([Parameter(Mandatory)][string]$Username,[int]$TimeoutSeconds=20)
    $deadline=(Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $session = Get-UserSession -Username $Username
        if ($null -eq $session -or -not $session.Online) { return $true }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    return $false
}

Export-ModuleMember -Function *
