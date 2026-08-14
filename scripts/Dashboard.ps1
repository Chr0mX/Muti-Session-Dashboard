[CmdletBinding()]

param()



Add-Type -AssemblyName System.Windows.Forms

Add-Type -AssemblyName System.Drawing

Add-Type -AssemblyName Microsoft.VisualBasic



# Defense in depth: an unhandled exception on any thread other than this
# one (e.g. a bug in a background runspace's completion handling) would
# otherwise take the whole process down instantly and silently -- no
# console output, no dialog, just the window vanishing. Show it instead of
# hiding it.
[System.AppDomain]::CurrentDomain.add_UnhandledException({
    param($senderObj, $eventArgs)
    $exceptionMessage = try { $eventArgs.ExceptionObject.ToString() } catch { 'Unknown unhandled exception.' }
    try {
        [Windows.Forms.MessageBox]::Show($exceptionMessage, 'Multi Session Dashboard - Unhandled Error') | Out-Null
    } catch {
        Write-Host "UNHANDLED EXCEPTION: $exceptionMessage" -ForegroundColor Red
    }
})



$module = Join-Path $PSScriptRoot 'MultiSessionDashboard.psm1'

if (-not (Test-Path -LiteralPath $module)) { $module = 'C:\Program Files\Muti Session Dashboard\MultiSessionDashboard.psm1' }

try {
    Import-Module $module -Force -ErrorAction Stop
} catch {
    [Windows.Forms.MessageBox]::Show("Failed to load $module`:`n`n$($_.Exception.Message)", 'Multi Session Dashboard - Startup Error') | Out-Null
    throw
}



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
    @{ Name='RdpConnectionStatus'; Header='RDP Status'; Width=120 },
    @{ Name='LastHeadlessArmError'; Header='Last Error'; Width=380 }
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



# This dashboard runs every RDP launch, session wait, and headless re-arm on
# a background runspace (Start-DashboardBackgroundTask, in
# MultiSessionDashboard.psm1) so none of them ever block this UI thread or
# the WinForms message loop. Everything below this point is presentation
# only: it decides what a button click or a monitor tick dispatches, and
# how the result gets painted -- it holds no session-management logic of
# its own. $script:DashboardActionInProgress still exists so the monitor
# timer skips a tick while a foreground button action is in flight, exactly
# as before.
$script:DashboardActionInProgress = $false
$script:MonitorTaskInFlight = $false

function Set-Status([string]$Text) { $status.Text = $Text; $form.Refresh() }

function Get-SelectedUsername {

    if ($grid.SelectedRows.Count -eq 0) { throw 'Select a user first.' }

    return [string]$grid.SelectedRows[0].Cells['Username'].Value

}

function Refresh-Grid {
    # Local group membership + reading sessions.json are fast, local, non-
    # blocking calls (no RDP launch, no session wait) -- unlike Start/
    # Connect/Stop and the monitor tick, this stays a plain synchronous UI
    # action, same as before.
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
            $grid.Rows[$row].Cells['LastHeadlessArmError'].Value = $entry.LastHeadlessArmError
        }

        Save-DashboardState -State $state
        Set-Status ("Detected {0} user(s) in 'Remote Desktop Users'. Select a row to Connect RDP." -f $users.Count)
    } catch {
        $grid.Rows.Clear()
        Set-Status ("User list failed: {0}" -f $_.Exception.Message)
    }
}

function Set-DashboardGridFromState {
    # Updates existing rows in place from an already-computed state
    # hashtable (as returned by Update-DashboardMonitorState), so the
    # user's current row selection is never disturbed. Pure rendering --
    # no session-management decisions happen here, those already happened
    # in the background task that produced $State.
    param([hashtable]$State)
    if ($null -eq $State) { return }
    foreach ($row in $grid.Rows) {
        $name = [string]$row.Cells['Username'].Value
        if ([string]::IsNullOrWhiteSpace($name) -or -not $State.ContainsKey($name)) { continue }
        $entry = $State[$name]
        $row.Cells['RdpSessionId'].Value = $entry.RdpSessionId
        $row.Cells['SessionState'].Value = $entry.SessionState
        $row.Cells['RdpConnectionStatus'].Value = $entry.RdpConnectionStatus
        $row.Cells['LastHeadlessArmError'].Value = $entry.LastHeadlessArmError
    }
}

function Complete-DashboardMonitorTick {
    # Plain top-level function, not a closure -- see Complete-DashboardAction's
    # comment for why $script: writes belong here rather than directly
    # inside a .GetNewClosure()'d scriptblock.
    $script:MonitorTaskInFlight = $false
}

function Invoke-DashboardMonitorTick {
    # Fires every 2 seconds from $sessionTimer. Dispatches the entire
    # monitoring pass -- including any headless re-arm it decides to do --
    # to a background runspace via Start-DashboardBackgroundTask, so a
    # re-arm's own RDP wait can never freeze this window. Skips a tick
    # while a foreground action is in flight (same guard as before) or
    # while a previous monitor tick's background task hasn't finished yet,
    # so ticks never pile up on top of each other.
    if ($script:DashboardActionInProgress -or $script:MonitorTaskInFlight) { return }
    $script:MonitorTaskInFlight = $true

    # See Invoke-DashboardActionAsync's comment: named function calls made
    # directly inside a .GetNewClosure()'d scriptblock are not reliable on
    # Windows PowerShell 5.1, so functions are captured as scriptblock
    # references and invoked with `&` here too, for consistency and
    # defense-in-depth (this scriptblock doesn't strictly need
    # .GetNewClosure() itself today since it has no local closure
    # variables, but keeping the same safe shape everywhere avoids relying
    # on that distinction staying true).
    $setGridStateRef = ${function:Set-DashboardGridFromState}
    $completeTickRef = ${function:Complete-DashboardMonitorTick}

    Start-DashboardBackgroundTask -Command 'Update-DashboardMonitorState' -Control $form `
        -OnSuccess { param($Result) & $setGridStateRef -State $Result }.GetNewClosure() `
        -OnError { param($ErrorMessage) Write-Verbose "Monitor tick failed: $ErrorMessage" } `
        -OnComplete { & $completeTickRef }.GetNewClosure()
}

function Complete-DashboardAction {
    <#
        Does the actual "an action just finished" work: clears the
        in-progress flag and re-enables the buttons. Called from
        Invoke-DashboardActionAsync's -OnComplete closure rather than
        having that closure set $script:DashboardActionInProgress itself
        -- confirmed by reproducing it: a `$script:X = value` assignment
        made *directly inside* a scriptblock that has had .GetNewClosure()
        called on it does not write back to the real script-scope
        variable (it silently goes to a detached copy), even though the
        very same assignment made inside an ordinary function -- called
        FROM a closure, rather than being part of one -- works correctly.
        Keeping this as a plain top-level function sidesteps that
        entirely: it isn't a closure itself, so its own `$script:` write
        resolves normally regardless of how deeply nested the closure
        chain that called it is.
    #>
    param($Buttons)
    $script:DashboardActionInProgress = $false
    foreach ($button in $Buttons) { $button.Enabled = $true }
}

function Invoke-DashboardActionAsync {
    <#
        Runs a module command that can legitimately block for seconds (RDP
        launch/wait, sign-off + verify) on a background runspace, keeping
        the UI fully responsive throughout. Buttons are disabled for the
        duration -- same UX as before -- but the window itself never stops
        repainting or reports "Not Responding", because nothing here runs
        on this thread.
    #>
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][hashtable]$Params,
        [Parameter(Mandatory)][string]$Success
    )
    $actionButtons = @($create, $start, $rdp, $stop, $refresh, $openWrapper, $tweaks)
    foreach ($button in $actionButtons) { $button.Enabled = $false }
    $script:DashboardActionInProgress = $true
    if ($Params.ContainsKey('Username')) { Set-Status "Working on $($Params.Username)..." } else { Set-Status 'Working...' }

    # .GetNewClosure() is required here, not optional: this function
    # returns as soon as Start-DashboardBackgroundTask has been called
    # (it dispatches to a background runspace and returns immediately),
    # well before -OnSuccess/-OnError/-OnComplete are actually invoked.
    # A plain scriptblock literal does not keep this function's local
    # variables ($actionButtons, $Success) reachable once this call has
    # returned -- confirmed by reproducing it: without .GetNewClosure(),
    # $actionButtons silently becomes $null by the time -OnComplete runs
    # (this script has no Set-StrictMode, so that's not even an error --
    # `foreach ($button in $null)` just does nothing), which is exactly
    # what left every button permanently disabled after an action finished.
    #
    # Named function calls made *directly inside* a .GetNewClosure()'d
    # scriptblock are NOT reliable on the real target platform (Windows
    # PowerShell 5.1) -- confirmed by a live crash report: calling
    # Set-Status by name from inside such a scriptblock threw
    # "The term 'Set-Status' is not recognized", even though the very
    # same scriptblock's captured *variables* resolved fine. Captured
    # ordinary variables and `&`-invoking a scriptblock already held in a
    # variable are both reliable (this is the same mechanism
    # Start-DashboardBackgroundTask itself uses to invoke -OnSuccess/
    # -OnError/-OnComplete), so functions are captured as scriptblock
    # references via ${function:Name} here and invoked with `&`, never by
    # bare name, from inside any closure.
    $setStatusRef = ${function:Set-Status}
    $refreshGridRef = ${function:Refresh-Grid}
    $completeActionRef = ${function:Complete-DashboardAction}

    $onSuccess = { & $setStatusRef $Success; & $refreshGridRef }.GetNewClosure()
    $onError = { param($ErrorMessage) & $setStatusRef $ErrorMessage; [Windows.Forms.MessageBox]::Show($ErrorMessage, 'Multi Session Dashboard') | Out-Null }.GetNewClosure()
    $onComplete = { & $completeActionRef -Buttons $actionButtons }.GetNewClosure()

    Start-DashboardBackgroundTask -Command $Command -Params $Params -Control $form `
        -OnSuccess $onSuccess -OnError $onError -OnComplete $onComplete
}

function Invoke-DashboardBetterRdpTweaksAsync {
    <#
        Same shape as Invoke-DashboardActionAsync (background dispatch,
        buttons disabled for the duration, ${function:Name} + `&`
        invocation inside every .GetNewClosure()'d callback -- see that
        function's comment for why bare-name calls inside a closure aren't
        reliable on the real target platform), except -OnSuccess shows the
        BetterRDP script's own captured output in a MessageBox instead of a
        fixed status string: Validate's pass/fail summary and Apply's
        "reboot is required" note are the actual point of clicking this
        button, not just a generic "it worked".
    #>
    param([Parameter(Mandatory)][string]$Action)
    $actionButtons = @($create, $start, $rdp, $stop, $refresh, $openWrapper, $tweaks)
    foreach ($button in $actionButtons) { $button.Enabled = $false }
    $script:DashboardActionInProgress = $true
    Set-Status "Running BetterRDP tweaks ($Action)..."

    $setStatusRef = ${function:Set-Status}
    $completeActionRef = ${function:Complete-DashboardAction}

    $onSuccess = { param($Result) & $setStatusRef 'BetterRDP tweaks finished'; [Windows.Forms.MessageBox]::Show([string]$Result, 'BetterRDP Tweaks') | Out-Null }.GetNewClosure()
    $onError = { param($ErrorMessage) & $setStatusRef $ErrorMessage; [Windows.Forms.MessageBox]::Show($ErrorMessage, 'Multi Session Dashboard') | Out-Null }.GetNewClosure()
    $onComplete = { & $completeActionRef -Buttons $actionButtons }.GetNewClosure()

    Start-DashboardBackgroundTask -Command 'Invoke-DashboardBetterRdpTweak' -Params @{ Action = $Action } -Control $form `
        -OnSuccess $onSuccess -OnError $onError -OnComplete $onComplete
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
    Invoke-DashboardActionAsync -Command 'New-DashboardUser' -Params @{ Username = $username; Password = $username } -Success "Created $username (password set to username)"

})

$form.Controls.Add($create)



$start = New-Object Windows.Forms.Button

$start.Text = 'Start'

$start.Location = New-Object Drawing.Point(155, 370)

$start.Size = New-Object Drawing.Size(100, 36)

# START workflow: arm a background/anchor RDP connection so the user's
# session comes up and stays "HEADLESS" without an RDP window ever
# appearing. Connect below reconnects the same session interactively,
# which displaces this automatically -- standard RDP behavior.
$start.Add_Click({ Invoke-DashboardActionAsync -Command 'Start-DashboardHeadlessLoopback' -Params @{ Username = (Get-SelectedUsername) } -Success 'Headless loopback armed' })

$form.Controls.Add($start)



$rdp = New-Object Windows.Forms.Button

$rdp.Text = 'Connect RDP'

$rdp.Location = New-Object Drawing.Point(263, 370)

$rdp.Size = New-Object Drawing.Size(120, 36)

$rdp.Add_Click({ Invoke-DashboardActionAsync -Command 'Connect-DashboardRdp' -Params @{ Username = (Get-SelectedUsername) } -Success 'RDP connected' })

$form.Controls.Add($rdp)



$stop = New-Object Windows.Forms.Button

$stop.Text = 'Stop'

$stop.Location = New-Object Drawing.Point(391, 370)

$stop.Size = New-Object Drawing.Size(90, 36)

$stop.Add_Click({ Invoke-DashboardActionAsync -Command 'Stop-DashboardSession' -Params @{ Username = (Get-SelectedUsername) } -Success 'Session stopped' })

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

$openWrapper.Add_Click({ Invoke-DashboardActionAsync -Command 'Open-DashboardRdpWrapperManager' -Params @{} -Success 'RDP Wrapper manager opened' })

$form.Controls.Add($openWrapper)



$tweaks = New-Object Windows.Forms.Button

$tweaks.Text = 'RDP Tweaks'

$tweaks.Location = New-Object Drawing.Point(759, 370)

$tweaks.Size = New-Object Drawing.Size(150, 36)

# Runs scripts/BetterRDP/BetterRDP.ps1 (Upinel/BetterRDP's host-side RDP
# performance registry tweaks) via Invoke-DashboardBetterRdpTweak
# (RdpManager.psm1). Apply changes machine-wide registry settings and
# needs a reboot afterward to take effect, so it's asked for explicitly
# rather than being the default -- Validate is read-only and safe to run
# any time, including just to check whether Apply has already been run.
$tweaks.Add_Click({
    $choice = [Windows.Forms.MessageBox]::Show(
        "Yes = Apply RDP performance tweaks (machine-wide registry changes; a reboot is required afterward).`nNo = Validate only -- reports current tweak status, changes nothing.`nCancel = do nothing.",
        'BetterRDP Tweaks', 'YesNoCancel', 'Question')
    if ($choice -eq [Windows.Forms.DialogResult]::Cancel) { return }
    $action = if ($choice -eq [Windows.Forms.DialogResult]::Yes) { 'Apply' } else { 'Validate' }
    Invoke-DashboardBetterRdpTweaksAsync -Action $action
})

$form.Controls.Add($tweaks)



# Poll Windows sessions continuously so the grid reflects real state,
# including RDP connections made outside the dashboard (e.g. a manual
# mstsc/rdp.exe connection). Each tick's actual work runs in the background
# (see Invoke-DashboardMonitorTick) -- this timer only ever decides
# whether to dispatch one, never blocks itself.
$sessionTimer = New-Object Windows.Forms.Timer
$sessionTimer.Interval = 2000
$sessionTimer.Add_Tick({ Invoke-DashboardMonitorTick })
$sessionTimer.Start()

Refresh-Grid

[void]$form.ShowDialog()
