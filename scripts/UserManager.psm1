<#
    UserManager.psm1 -- local user/RDS group management and session sign-off.

    Owns creating dashboard-managed local accounts, reading the "Remote
    Desktop Users" group, and signing a user's session off (with
    verification that it's actually gone). See SessionManager.psm1's header
    comment for why every function here is `function global:Verb-Noun`.
    This module is meant to be loaded through MultiSessionDashboard.psm1,
    not imported standalone -- it calls kernel functions (Get-DashboardState,
    Save-DashboardState, Assert-Administrator, Get-DashboardUsersRoot,
    Test-RdpWrapperConfiguration) and other managers' functions
    (Get-UserSession, Wait-DashboardSessionClosed, Stop-DashboardHeadlessLoopback)
    that only exist once the coordinator has finished loading everything.
#>

Set-StrictMode -Version Latest

function global:Get-RemoteDesktopUsers {
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

function global:Get-DashboardUsers {
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

function global:New-DashboardUser {
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

    $userRoot = Join-Path (Get-DashboardUsersRoot) $Username
    New-DirectoryIfMissing -Path $userRoot
}

function global:Assert-DashboardConnectPreconditions {
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

function global:Stop-DashboardSession {
    <#
        STOP workflow: stop the headless loopback, sign the real Windows
        session off, then verify (poll, don't assume) that the session is
        actually gone before marking the dashboard state Stopped. No
        tscon, no console hand-off -- just the standard `logoff` of
        whatever real session ID Get-UserSession detects for this user.
    #>
    param([Parameter(Mandatory)][string]$Username)

    Stop-DashboardHeadlessLoopback -Username $Username

    $session = Get-UserSession -Username $Username
    if ($null -ne $session) { logoff $session.SessionId 2>$null }

    $closed = Wait-DashboardSessionClosed -Username $Username -TimeoutSeconds 20
    if (-not $closed) {
        Write-Warning "Session for '$Username' did not report closed within 20 seconds after logoff."
    }

    $state = Get-DashboardState
    if ($state.ContainsKey($Username)) {
        $state[$Username].SessionState = 'Stopped'
        $state[$Username].RdpConnectionStatus = 'Disconnected'
        $state[$Username].RdpSessionId = $null
        $state[$Username].StopRequested = $true
    }
    Save-DashboardState -State $state
}

Export-ModuleMember -Function *
