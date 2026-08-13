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
    @{ Name='Username'; Header='Username'; Width=180 },
    @{ Name='RdpHostPort'; Header='RDP Endpoint'; Width=150 },
    @{ Name='RdpSessionId'; Header='RDP Session'; Width=90 },
    @{ Name='SessionState'; Header='Session'; Width=100 },
    @{ Name='SunshineState'; Header='Sunshine'; Width=100 },
    @{ Name='SunshinePort'; Header='Sunshine Port'; Width=100 },
    @{ Name='SunshineLoopback'; Header='Moonlight Host'; Width=110 },
    @{ Name='RdpConnectionStatus'; Header='RDP Status'; Width=130 }
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
            $grid.Rows[$row].Cells['SunshineState'].Value = $entry.SunshineState
            $grid.Rows[$row].Cells['SunshinePort'].Value = $entry.SunshinePort
            $grid.Rows[$row].Cells['SunshineLoopback'].Value = $entry.SunshineLoopback
            $grid.Rows[$row].Cells['RdpConnectionStatus'].Value = $entry.RdpConnectionStatus
        }

        Save-DashboardState -State $state
        Set-Status ("Detected {0} user(s) in 'Remote Desktop Users'. Select a row to Start/Connect." -f $users.Count)
    } catch {
        $grid.Rows.Clear()
        Set-Status ("User list failed: {0}" -f $_.Exception.Message)
    }
}

function Update-SessionMonitor {
    try {
        $state = Get-DashboardState

        # Poll every Remote Desktop Users member's actual Windows session state,
        # not just the ones the dashboard itself started. This is what makes a
        # manual RDP connection (outside the dashboard) show up correctly, and
        # it keeps tscon handoff working for those sessions too.
        $users = @(Get-RemoteDesktopUsers)
        foreach ($user in $users) {
            $key = [string]$user.Username
            if ([string]::IsNullOrWhiteSpace($key)) { continue }
            if (-not $state.ContainsKey($key)) {
                $state[$key] = Get-DefaultDashboardStateEntry -Username $key -AccountName $user.AccountName
            }
            $entry = $state[$key]
            $hasWindowsSession = $false

            try {
                $session = Maintain-DashboardSession -Username $key
                if ($null -eq $session) {
                    $entry.RdpSessionId = $null
                    $entry.RdpConnectionStatus = 'Disconnected'
                    if ($entry.SessionState -eq 'Running') { $entry.SessionState = 'Stopped' }
                } else {
                    $hasWindowsSession = $true
                    $entry.RdpSessionId = $session.SessionId
                    if ($session.IsRdp -and $session.Online) {
                        # A live RDP reconnect is intentionally left alone so the
                        # operator can use the GUI. tscon is only applied after the
                        # RDP client disconnects.
                        $entry.RdpConnectionStatus = 'Connected'
                        $entry.SessionState = 'Running'
                    } elseif ($session.IsConsole -and $session.Online) {
                        $entry.RdpConnectionStatus = 'Online'
                        $entry.SessionState = 'Running'
                    } else {
                        $entry.RdpConnectionStatus = 'Disconnected'
                    }
                }
            } catch {
                # Keep the dashboard alive even if a single user's session
                # temporarily cannot be queried or handed off.
                $entry.RdpConnectionStatus = 'Error'
            }

            # Never trust the flag Start/Stop last set: re-derive SunshineState
            # from the actual process/owner/port every tick, same as the RDP
            # status above. Skip the check entirely when there's no Windows
            # session at all -- nothing meaningful can be running.
            if ($hasWindowsSession) {
                try {
                    $sunshineStatus = Test-UserSunshineRunning -Username $key
                    if ($sunshineStatus.Running) {
                        $entry.SunshineState = 'Running'
                        $entry.SunshineProcessId = $sunshineStatus.ProcessId
                    } else {
                        $entry.SunshineState = 'Stopped'
                        $entry.SunshineProcessId = $null
                    }
                } catch {
                    $entry.SunshineState = 'Error'
                }
            } elseif ($entry.SunshineState -ne 'Stopped') {
                $entry.SunshineState = 'Stopped'
                $entry.SunshineProcessId = $null
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
            $row.Cells['SunshineState'].Value = $entry.SunshineState
            $row.Cells['SunshinePort'].Value = $entry.SunshinePort
            $row.Cells['SunshineLoopback'].Value = $entry.SunshineLoopback
            $row.Cells['RdpConnectionStatus'].Value = $entry.RdpConnectionStatus
        }
    } catch {
        # Timer errors must never terminate the GUI.
    }
}

function Invoke-DashboardAction([scriptblock]$Action, [string]$Success) {

    try { & $Action; Set-Status $Success; Refresh-Grid } catch { Set-Status $_.Exception.Message; [Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Multi Session Dashboard') | Out-Null }

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

$start.Size = New-Object Drawing.Size(110, 36)

$start.Add_Click({
    Invoke-DashboardAction {
        $username = Get-SelectedUsername
        Start-DashboardSession -Username $username
    } 'Session running'
})

$form.Controls.Add($start)



$rdp = New-Object Windows.Forms.Button

$rdp.Text = 'Connect RDP'

$rdp.Location = New-Object Drawing.Point(278, 370)

$rdp.Size = New-Object Drawing.Size(130, 36)

$rdp.Add_Click({ Invoke-DashboardAction { Connect-DashboardRdp -Username (Get-SelectedUsername) } 'RDP reconnect requested' })

$form.Controls.Add($rdp)



$moonlight = New-Object Windows.Forms.Button

$moonlight.Text = 'Connect Moonlight'

$moonlight.Location = New-Object Drawing.Point(421, 370)

$moonlight.Size = New-Object Drawing.Size(160, 36)

$moonlight.Add_Click({ Invoke-DashboardAction { Connect-DashboardMoonlight -Username (Get-SelectedUsername) } 'Moonlight launched' })

$form.Controls.Add($moonlight)



$stop = New-Object Windows.Forms.Button

$stop.Text = 'Stop'

$stop.Location = New-Object Drawing.Point(594, 370)

$stop.Size = New-Object Drawing.Size(110, 36)

$stop.Add_Click({ Invoke-DashboardAction { Stop-DashboardSession -Username (Get-SelectedUsername) } 'Session stopped' })

$form.Controls.Add($stop)



$refresh = New-Object Windows.Forms.Button

$refresh.Text = 'Refresh'

$refresh.Location = New-Object Drawing.Point(717, 370)

$refresh.Size = New-Object Drawing.Size(110, 36)

$refresh.Add_Click({ Refresh-Grid; Set-Status 'Refreshed' })

$form.Controls.Add($refresh)



$updateSunshine = New-Object Windows.Forms.Button

$updateSunshine.Text = 'Update Sunshine'

$updateSunshine.Location = New-Object Drawing.Point(840, 370)

$updateSunshine.Size = New-Object Drawing.Size(140, 36)

$updateSunshine.Add_Click({ Invoke-DashboardAction { Update-DashboardUserSunshine -Username (Get-SelectedUsername) } 'Sunshine updated' })

$form.Controls.Add($updateSunshine)



# Poll Windows sessions continuously. This makes tscon a lifecycle handoff:
# Start -> RDP login -> tscon to console; Connect RDP -> GUI remains connected;
# when the RDP client disconnects, the monitor detects the disconnected RDP
# session and tscon hands it back to console so the Windows session stays alive.
$sessionTimer = New-Object Windows.Forms.Timer
$sessionTimer.Interval = 2000
$sessionTimer.Add_Tick({ Update-SessionMonitor })
$sessionTimer.Start()

Refresh-Grid

[void]$form.ShowDialog()

