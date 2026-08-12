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
$form.Size = New-Object Drawing.Size(980, 520)
$form.StartPosition = 'CenterScreen'

$grid = New-Object Windows.Forms.DataGridView
$grid.Location = New-Object Drawing.Point(12, 12)
$grid.Size = New-Object Drawing.Size(940, 340)
$grid.SelectionMode = 'FullRowSelect'
$grid.MultiSelect = $false
$grid.AutoGenerateColumns = $true
$form.Controls.Add($grid)

$status = New-Object Windows.Forms.Label
$status.Location = New-Object Drawing.Point(12, 455)
$status.Size = New-Object Drawing.Size(940, 24)
$status.Text = 'Ready'
$form.Controls.Add($status)

function Set-Status([string]$Text) { $status.Text = $Text; $form.Refresh() }
function Get-SelectedUsername {
    if ($grid.SelectedRows.Count -eq 0) { throw 'Select a user first.' }
    return [string]$grid.SelectedRows[0].Cells['Username'].Value
}
function Refresh-Grid {
    $state = Get-DashboardState
    $rows = foreach ($key in $state.Keys) {
        [pscustomobject]@{
            Username = $key
            RdpSessionId = $state[$key].RdpSessionId
            SessionState = $state[$key].SessionState
            SunshineState = $state[$key].SunshineState
            SunshinePort = $state[$key].SunshinePort
            RdpConnectionStatus = $state[$key].RdpConnectionStatus
        }
    }
    $grid.DataSource = @($rows)
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
    $password = [Microsoft.VisualBasic.Interaction]::InputBox('Password (leave blank only if intended):', 'Create User', '')
    $allowBlank = $false
    if ([string]::IsNullOrEmpty($password)) {
        $answer = [Windows.Forms.MessageBox]::Show('Blank-password RDP may require weakening Windows security policy. Allow the dashboard to change that policy if required?', 'Blank password warning', 'YesNo', 'Warning')
        $allowBlank = ($answer -eq 'Yes')
    }
    Invoke-DashboardAction { New-DashboardUser -Username $username -Password $password -AllowBlankPasswordPolicyChange:$allowBlank } "Created $username"
})
$form.Controls.Add($create)

$start = New-Object Windows.Forms.Button
$start.Text = 'Start'
$start.Location = New-Object Drawing.Point(155, 370)
$start.Size = New-Object Drawing.Size(110, 36)
$start.Add_Click({ Invoke-DashboardAction { Start-DashboardSession -Username (Get-SelectedUsername) } 'Session running' })
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

Refresh-Grid
[void]$form.ShowDialog()
