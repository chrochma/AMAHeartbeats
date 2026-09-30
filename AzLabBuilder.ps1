<#
.SYNOPSIS
    AzLabBuilder - PowerShell TUI to deploy ready-to-use Azure lab scenarios.

.DESCRIPTION
    Validates (or creates) the Azure authentication context and offers lab scenarios.
    Scenario 1 "AMA Heartbeat lab": N x cheapest Linux VM in Sweden Central with the
    Azure Monitor Agent, a DCR to Log Analytics and an Azure Monitor workbook that shows
    running VMs and VMs without AMA heartbeat for more than 10 minutes.

.PARAMETER UseDeviceAuthentication
    Use device code sign-in (e.g. on machines without a browser).

.EXAMPLE
    .\AzLabBuilder.ps1
#>
[CmdletBinding()]
param(
    [switch]$UseDeviceAuthentication
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# Load UI, auth, Azure helpers and scenarios
. (Join-Path $PSScriptRoot 'lib\Tui.ps1')
. (Join-Path $PSScriptRoot 'lib\Auth.ps1')
. (Join-Path $PSScriptRoot 'lib\Azure.ps1')
. (Join-Path $PSScriptRoot 'scenarios\AmaHeartbeat\AmaHeartbeat.ps1')

# Scenario registry - add new scenarios here
$scenarios = @(
    [pscustomobject]@{
        Name      = 'AMA Heartbeat lab'
        Summary   = '10x cheapest Linux VM + AMA + heartbeat health dashboard'
        Deploy    = { Invoke-AmaHeartbeatDeploy }
        Health    = { Show-AmaHeartbeatHealth }
        Crash     = { Invoke-AmaHeartbeatCrashSim }
        Dashboard = { Open-AmaHeartbeatDashboard }
        Remove    = { Remove-AmaHeartbeatLab }
    }
)

function Invoke-LabAction {
    # Runs a menu action and keeps the TUI alive on errors
    param([scriptblock]$Action)
    try { & $Action } catch { Write-LabStatus -Level Error -Message $_.Exception.Message }
    Wait-LabKey
}

function Select-LabScenario {
    param([string]$Purpose)
    if ($scenarios.Count -eq 1) { return $scenarios[0] }
    $menu = [ordered]@{}
    for ($i = 0; $i -lt $scenarios.Count; $i++) { $menu["$($i + 1)"] = $scenarios[$i].Name }
    $menu['B'] = 'Back'
    $pick = Show-LabMenu -Title $Purpose -Items $menu
    if ($pick -eq 'B') { return $null }
    return $scenarios[[int]$pick - 1]
}

Write-LabBanner
if (-not (Test-LabModules)) { Write-LabStatus -Level Error -Message 'Required modules missing. Exiting.'; return }
try {
    if (-not (Initialize-LabAuthentication -UseDeviceAuthentication:$UseDeviceAuthentication)) {
        Write-LabStatus -Level Error -Message 'No valid Azure context. Exiting.'; return
    }
} catch {
    Write-LabStatus -Level Error -Message ('Authentication failed: {0}' -f $_.Exception.Message); return
}

while ($true) {
    Write-LabBanner
    Write-LabContext
    $menu = [ordered]@{}
    for ($i = 0; $i -lt $scenarios.Count; $i++) { $menu["$($i + 1)"] = 'Deploy: {0} - {1}' -f $scenarios[$i].Name, $scenarios[$i].Summary }
    $menu['H'] = 'Health check (running VMs vs. AMA heartbeat)'
    $menu['C'] = 'Simulate AMA outage (block heartbeat via NSG) / restore'
    $menu['D'] = 'Open Azure Monitor dashboard (workbook)'
    $menu['R'] = 'Remove a lab'
    $menu['A'] = 'Account: re-authenticate / switch subscription'
    $menu['Q'] = 'Quit'

    $choice = Show-LabMenu -Title 'Main menu' -Items $menu
    switch -Regex ($choice) {
        '^\d+$' { $s = $scenarios[[int]$choice - 1]; Invoke-LabAction -Action $s.Deploy }
        '^H$' { $s = Select-LabScenario -Purpose 'Health check'; if ($s) { Invoke-LabAction -Action $s.Health } }
        '^C$' { $s = Select-LabScenario -Purpose 'AMA outage'; if ($s) { Invoke-LabAction -Action $s.Crash } }
        '^D$' { $s = Select-LabScenario -Purpose 'Dashboard'; if ($s) { Invoke-LabAction -Action $s.Dashboard } }
        '^R$' { $s = Select-LabScenario -Purpose 'Remove lab'; if ($s) { Invoke-LabAction -Action $s.Remove } }
        '^A$' { Invoke-LabAction -Action { Initialize-LabAuthentication -UseDeviceAuthentication:$UseDeviceAuthentication | Out-Null } }
        '^Q$' { Write-Host ''; Write-LabStatus -Level Info -Message 'Bye.'; return }
    }
}
