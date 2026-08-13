[CmdletBinding()]

param()



Add-Type -AssemblyName System.Windows.Forms

Add-Type -AssemblyName System.Drawing

Add-Type -AssemblyName Microsoft.VisualBasic



$module = Join-Path $PSScriptRoot 'MultiSessionDashboard.psm1'

if (-not (Test-Path -LiteralPath $module)) { $module = 'C:\Program Files\Muti Session Dashboard\MultiSessionDashboard.psm1' }

Import-Module $module -Force



$form = New-Object Windows.Forms.Form

$form.Text = 'Multi Session Dashboard'

$form.Size = New-Object Drawing.Size(1080, 520)

$form.StartPosition = 'CenterScreen'



$grid = New-Object Windows.Forms.DataGridView

$grid.Location = New-Object Drawing.Point(12, 12)

$grid.Size = New-Object Drawing.Size(1040, 340)

$grid.SelectionMode = 'FullRowSelect'

$grid.MultiSelect = $false

$grid.AutoGenerateColumns = $false
$grid.AllowUserToAddRows = $false
$grid.ReadOnly = $true
$grid.RowHeadersVisible = $false

foreach ($column in @(
    @{ Name='Username'; Header='Username'; Width=160 },
    @{ Name='RdpHostPort'; Header='RDP Endpoint'; Width=140 },
    @{ Name='RdpSessionId'; Header='RDP Session'; Width=90 },
    @{ Name='SessionState'; Header='Session'; Width=90 },
    @{ Name='RdpConnectionStatus'; Header='RDP Status'; Width=120 }
)) {
    $columnObject = New-Object Windows.Forms.DataGridViewTextBoxColumn
    $columnObject.Name = $column.Name
    $columnObject.HeaderText = $column.Header
    $columnObject.Width = $column.Width
    $grid.Columns.Add($columnObject) | Out-Null
}

$form.Controls.Add($grid)



$status = New-Object Windows.Forms.Label

$status.Location = New-Object Drawing.Point(12, 455)

$status.Size = New-Object Drawing.Size(1040, 24)

$status.Text = 'Ready'

$form.Controls.Add($status)



$script:DashboardActionInProgress = $false

function Set-Status([string]$Text) { $status.Text = $Text; $form.Refresh() }

function Get-SelectedUsername {

    if ($grid.SelectedRows.Count -eq 0) { throw 'Select a user first.' }

    return [string]$grid.SelectedRows[0].Cells['Username'].Value

}

function Refresh-Grid {
    try {
        $users = @(Get-RemoteDesktopUsers)
        $dashboardUsers = @(Get-DashboardUsers)
        $state = Get-DashboardState

        # Do not make user rendering depend on RDP endpoint detection.
        # The Remote Desktop Users group is the source of truth for this list.
        $endpoint = try { Get-RdpEndpoint } catch { '' }

        $grid.Rows.Clear()

        foreach ($user in $users) {
            $key = [string]$user.Username
            if ([string]::IsNullOrWhiteSpace($key)) { continue }

            if (-not $state.ContainsKey($key)) {
                $state[$key] = Get-DefaultDashboardStateEntry -Username $key -AccountName $user.AccountName
            }

            $entry = $state[$key]
            $row = $grid.Rows.Add()
            $grid.Rows[$row].Cells['Username'].Value = $key
            $grid.Rows[$row].Cells['RdpHostPort'].Value = $endpoint
            $grid.Rows[$row].Cells['RdpSessionId'].Value = $entry.RdpSessionId
            $grid.Rows[$row].Cells['SessionState'].Value = $entry.SessionState
            $grid.Rows[$row].Cells['RdpConnectionStatus'].Value = $entry.RdpConnectionStatus
        }

        Save-DashboardState -State $state
        Set-Status ("Detected {0} user(s) in 'Remote Desktop Users'. Select a row to Connect RDP." -f $users.Count)
    } catch {
        $grid.Rows.Clear()
        Set-Status ("User list failed: {0}" -f $_.Exception.Message)
    }
}

function Update-SessionMonitor {
    # Invoke-DashboardAction's Wait-DashboardRdpSession polling pumps the
    # WinForms message loop internally so the window stays responsive, which
    # means this timer's own Tick can fire while an action is still
    # mid-flight. Skip this tick rather than let it read/write sessions.json
    # concurrently with the in-flight action's own state calls.
    if ($script:DashboardActionInProgress) { return }
    try {
        $state = Get-DashboardState

        # Poll every Remote Desktop Users member's actual Windows session
        # state, not just the ones the dashboard itself connected -- this is
        # what makes a manual RDP connection (outside the dashboard) show up
        # correctly too. Purely a status reflection: nothing here acts on
        # the session (no console hand-off), each user just keeps their own
        # ordinary RDP session, reconnecting to it the normal way.
        $users = @(Get-RemoteDesktopUsers)
        foreach ($user in $users) {
            $key = [string]$user.Username
            if ([string]::IsNullOrWhiteSpace($key)) { continue }
            if (-not $state.ContainsKey($key)) {
                $state[$key] = Get-DefaultDashboardStateEntry -Username $key -AccountName $user.AccountName
            }
            $entry = $state[$key]
            $wasInteractive = ($entry.SessionState -eq 'Running')

            try {
                $session = Get-UserSession -Username $key
                if ($null -eq $session) {
                    $entry.RdpSessionId = $null
                    $entry.RdpConnectionStatus = 'Disconnected'
                    if ($entry.SessionState -ne 'Stopped') { $entry.SessionState = 'Stopped' }
                } else {
                    $entry.RdpSessionId = $session.SessionId
                    if ($session.Online) {
                        # A headless-armed entry whose session shows Online
                        # again with no interactive Connect having happened
                        # is just the loopback itself reconnecting; treat it
                        # as still armed rather than clobbering that state.
                        if (-not $entry.HeadlessArmed) {
                            $entry.RdpConnectionStatus = 'Connected'
                            $entry.SessionState = 'Running'
                        }
                    } else {
                        $entry.RdpConnectionStatus = 'Disconnected'
                    }
                }
            } catch {
                # Keep the dashboard alive even if a single user's session
                # temporarily cannot be queried.
                $entry.RdpConnectionStatus = 'Error'
            }

            # Headless RDP Loopback re-arm: once the interactive client that
            # displaced a headless connection disconnects (session goes
            # fully offline), automatically start a fresh headless loopback
            # so the user is HEADLESS READY again for the next Connect,
            # exactly as the flow requires -- no operator action needed.
            $justWentOffline = ($wasInteractive -and $entry.SessionState -eq 'Stopped' -and -not $entry.HeadlessArmed -and -not $entry.StopRequested)
            if ($justWentOffline) {
                $script:DashboardActionInProgress = $true
                try {
                    Start-DashboardHeadlessLoopback -Username $key | Out-Null
                    $entry = $state[$key]
                } catch {
                    Write-Verbose "Auto re-arm of headless loopback for '$key' failed: $($_.Exception.Message)"
                } finally {
                    $script:DashboardActionInProgress = $false
                }
            }
        }
        Save-DashboardState -State $state
        # Update existing rows in place so the user's selection is not lost.
        foreach ($row in $grid.Rows) {
            $name = [string]$row.Cells['Username'].Value
            if ([string]::IsNullOrWhiteSpace($name) -or -not $state.ContainsKey($name)) { continue }
            $entry = $state[$name]
            $row.Cells['RdpSessionId'].Value = $entry.RdpSessionId
            $row.Cells['SessionState'].Value = $entry.SessionState
            $row.Cells['RdpConnectionStatus'].Value = $entry.RdpConnectionStatus
        }
    } catch {
        # Timer errors must never terminate the GUI.
    }
}

function Invoke-DashboardAction([scriptblock]$Action, [string]$Success) {
    # Connect RDP can block for tens of seconds inside $Action
    # (Wait-DashboardRdpSession polling), which pumps the WinForms message
    # loop internally (Invoke-DashboardUiPump) so the window doesn't appear
    # to hang. Pumping means input messages - including another button's
    # click - CAN be processed while $Action is still running, so disable
    # every action button here to make that reentrant click a no-op instead
    # of a second action racing the first.
    $actionButtons = @($create, $start, $rdp, $stop, $refresh, $openWrapper)
    foreach ($button in $actionButtons) { $button.Enabled = $false }
    $script:DashboardActionInProgress = $true
    $form.Refresh()

    try {
        & $Action
        Set-Status $Success
        Refresh-Grid
    } catch {
        Set-Status $_.Exception.Message
        [Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Multi Session Dashboard') | Out-Null
    } finally {
        $script:DashboardActionInProgress = $false
        foreach ($button in $actionButtons) { $button.Enabled = $true }
    }
}



$create = New-Object Windows.Forms.Button

$create.Text = 'Create User'

$create.Location = New-Object Drawing.Point(12, 370)

$create.Size = New-Object Drawing.Size(130, 36)

$create.Add_Click({

    $username = [Microsoft.VisualBasic.Interaction]::InputBox('Username:', 'Create User', '')

    if ([string]::IsNullOrWhiteSpace($username)) { return }

    # Dashboard accounts use the username as the initial Windows password.
    # Example: local1 -> password local1.
    $password = $username

    Invoke-DashboardAction { New-DashboardUser -Username $username -Password $password } "Created $username (password set to username)"

})

$form.Controls.Add($create)



$start = New-Object Windows.Forms.Button

$start.Text = 'Start'

$start.Location = New-Object Drawing.Point(155, 370)

$start.Size = New-Object Drawing.Size(100, 36)

# Headless RDP Loopback: arms a background/anchor RDP connection so the
# user's session comes up and stays "HEADLESS READY" without an RDP window
# ever appearing. Connect below reconnects the same session interactively,
# which displaces this automatically -- standard RDP behavior.
$start.Add_Click({ Invoke-DashboardAction { Start-DashboardHeadlessLoopback -Username (Get-SelectedUsername) } 'Headless loopback armed' })

$form.Controls.Add($start)



$rdp = New-Object Windows.Forms.Button

$rdp.Text = 'Connect RDP'

$rdp.Location = New-Object Drawing.Point(263, 370)

$rdp.Size = New-Object Drawing.Size(120, 36)

$rdp.Add_Click({ Invoke-DashboardAction { Connect-DashboardRdp -Username (Get-SelectedUsername) } 'RDP connected' })

$form.Controls.Add($rdp)



$stop = New-Object Windows.Forms.Button

$stop.Text = 'Stop'

$stop.Location = New-Object Drawing.Point(391, 370)

$stop.Size = New-Object Drawing.Size(90, 36)

$stop.Add_Click({ Invoke-DashboardAction { Stop-DashboardSession -Username (Get-SelectedUsername) } 'Session stopped' })

$form.Controls.Add($stop)



$refresh = New-Object Windows.Forms.Button

$refresh.Text = 'Refresh'

$refresh.Location = New-Object Drawing.Point(489, 370)

$refresh.Size = New-Object Drawing.Size(90, 36)

$refresh.Add_Click({ Refresh-Grid; Set-Status 'Refreshed' })

$form.Controls.Add($refresh)



$openWrapper = New-Object Windows.Forms.Button

$openWrapper.Text = 'Open RDP Wrapper'

$openWrapper.Location = New-Object Drawing.Point(587, 370)

$openWrapper.Size = New-Object Drawing.Size(160, 36)

$openWrapper.Add_Click({ Invoke-DashboardAction { Open-DashboardRdpWrapperManager } 'RDP Wrapper manager opened' })

$form.Controls.Add($openWrapper)



# Poll Windows sessions continuously so the grid reflects real state,
# including RDP connections made outside the dashboard (e.g. a manual
# mstsc/rdp.exe connection) -- pure status reflection, no session hand-off.
$sessionTimer = New-Object Windows.Forms.Timer
$sessionTimer.Interval = 2000
$sessionTimer.Add_Tick({ Update-SessionMonitor })
$sessionTimer.Start()

Refresh-Grid

[void]$form.ShowDialog()
