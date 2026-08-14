<#
    HeadlessManager.psm1 -- headless RDP loopback: arm, tear down, re-arm.

    Owns the "Start" side of the Headless RDP Loopback flow: launching a
    minimized, automated RDP connection that keeps a user's session alive
    and ready, and tearing it down (without touching the underlying Windows
    session) when it's displaced by a real Connect or torn down by Stop.

    See SessionManager.psm1's header comment for why every function here is
    `function global:Verb-Noun`. This module is meant to be loaded through
    MultiSessionDashboard.psm1, not imported standalone -- it calls kernel
    functions (Assert-Administrator, Get-DashboardState, Save-DashboardState),
    UserManager's Assert-DashboardConnectPreconditions, and RdpManager's
    Invoke-DashboardRdpBootstrap.
#>

Set-StrictMode -Version Latest

function global:Stop-DashboardHeadlessLoopback {
    <#
        Kills a still-running headless loopback rdp.exe process for this
        user, if any, and clears the tracking fields. Safe to call even if
        nothing is armed. Does not sign the underlying Windows session off
        -- that stays alive across headless -> interactive handoffs; only
        Stop-DashboardSession (UserManager) does that.
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

function global:Start-DashboardHeadlessLoopback {
    <#
        START workflow: arm a background/anchor RDP connection for this
        user (the same automated login as Connect-DashboardRdp, but
        launched minimized so it never shows a window), then verify the
        session actually came up before reporting HEADLESS -- the
        verification happens inside Invoke-DashboardRdpBootstrap's own
        Wait-DashboardRdpSession call. This is the "Start" step in the
        Headless RDP Loopback flow: it exists to keep the user's session
        alive and ready ("HEADLESS"), not to be looked at. A later
        Connect-DashboardRdp call reconnects the same session with a real,
        visible client, which displaces this one automatically (standard
        RDP behavior).

        Blocks for as long as Invoke-DashboardRdpBootstrap does (up to 45s),
        so this must always be run from a background runspace -- see
        Start-DashboardBackgroundTask in MultiSessionDashboard.psm1.
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
        $state[$Username].LastHeadlessArmError = $null
        Save-DashboardState -State $state
    }
    return $rdp
}

Export-ModuleMember -Function *
