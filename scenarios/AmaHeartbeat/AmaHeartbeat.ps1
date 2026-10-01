# AzLabBuilder scenario: AMA Heartbeat lab
# N x cheapest Linux VM + Azure Monitor Agent + DCR -> Log Analytics + Azure Monitor workbook (health dashboard)

$script:AmaHbScenarioTag = 'AmaHeartbeat'
$script:AmaHbTemplate = Join-Path $PSScriptRoot 'main.json'

function Get-LabDeterministicGuid {
    # Stable GUID from a string so re-deployments update the same workbook
    param([Parameter(Mandatory)][string]$Seed)
    $md5 = [System.Security.Cryptography.MD5]::Create()
    $bytes = $md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Seed.ToLowerInvariant()))
    $md5.Dispose()
    return ([guid]::new($bytes)).ToString()
}

function New-CountTile {
    # Tile settings for a single big number with title/subtitle
    param([string]$CountColumn, [string]$Palette)
    @{
        titleContent    = @{ columnMatch = 'Title'; formatter = 1 }
        leftContent     = @{ columnMatch = $CountColumn; formatter = 12; formatOptions = @{ palette = $Palette }; numberFormat = @{ unit = 17; options = @{ style = 'decimal'; maximumFractionDigits = 0 } } }
        subtitleContent = @{ columnMatch = 'Subtitle' }
        showBorder      = $true
        size            = 'full'
    }
}

function Get-AmaHeartbeatKql {
    <#
      Returns the dashboard KQL (Log Analytics, reads ARG via arg("") - no extra ingestion). Built for 40k+ VMs:
      arg() transfers max. 1000 rows, so ARG data is either aggregated inside Resource Graph or packed into
      a few rows with make_list() and expanded locally.
      Workbook placeholders: {Subscription}, {ResourceGroup}, {ThresholdMin}, {StartupGraceMin}, {ChartHours}.
    No {TimeRange:start}: the portal renders it in the browser locale (e.g. 30.09.2026 14:05), which todatetime() can't parse.
    #>

    # Resource Health annotations: power-on, restart (VM stays on) and power-off
    $start = "'VirtualMachineStartInitiatedByControlPlane','VirtualMachineAllocated'"
    $restart = "'VirtualMachineRestarted','VirtualMachineRebootInitiatedByControlPlane','VirtualMachineRebootInitiatedForPlannedMaintenance','VirtualMachineRedeployInitiatedByControlPlane','VirtualMachineHostRebootedForRepair','VirtualMachineMigrationInitiatedForRepair','VirtualMachineCrashed','VirtualMachineHostCrashed'"
    $off = "'VirtualMachineDeallocationInitiated','VirtualMachineStopInitiatedByControlPlane','VirtualMachineStoppedInternally','VirtualMachinePreempted'"

    $tokens = @{
        '__SCOPE__'   = "| where '{Subscription}' == '*' or subscriptionId =~ '{Subscription}'`n        | where '{ResourceGroup}' == '*' or resourceGroup =~ '{ResourceGroup}'"
        '__HBSCOPE__' = "| where Category == 'Azure Monitor Agent' and _ResourceId has '/providers/microsoft.compute/virtualmachines/'`n    | where '{Subscription}' == '*' or _ResourceId startswith strcat('/subscriptions/', '{Subscription}', '/')`n    | where '{ResourceGroup}' == '*' or _ResourceId contains strcat('/resourcegroups/', '{ResourceGroup}', '/')"
        '__START__'   = $start
        '__BOOT__'    = "$start,$restart"
        '__OFF__'     = $off
    }
    $expand = { param([string]$Kql) foreach ($k in $tokens.Keys) { $Kql = $Kql.Replace($k, $tokens[$k]) }; $Kql }

    # Current state per VM. All VMs are packed into one row inside ARG (P = power, N = created within grace).
    $state = & $expand @'
let T = {ThresholdMin}m;
let Grace = {StartupGraceMin}m;
let vms = datatable(k:int)[1]
    | join kind=inner hint.remote=left (arg("").Resources
        | where type =~ 'microsoft.compute/virtualmachines'
        __SCOPE__
        | extend PS = tostring(properties.extended.instanceView.powerState.code)
        | extend P = case(PS =~ 'PowerState/running', 'R', PS =~ 'PowerState/deallocated', 'D', PS =~ 'PowerState/stopped', 'S', 'O'),
                 N = iff(todatetime(properties.timeCreated) > ago({StartupGraceMin}m), '1', '0')
        | summarize L = make_list(strcat(P, N, id))
        | extend k = 1) on k
    | mv-expand L to typeof(string)
    | extend Id = substring(L, 2)
    | extend Parts = split(Id, '/')
    | project VmId = tolower(Id), VM = tostring(Parts[8]), ResourceGroup = tolower(tostring(Parts[4])), SubscriptionId = tostring(Parts[2]),
              Power = case(L startswith 'R', 'Running', L startswith 'D', 'Deallocated', L startswith 'S', 'Stopped', 'Other'),
              NewVm = substring(L, 1, 1) == '1';
// Any start/restart within the grace period (changes + current annotation), packed into one row
let boots = datatable(k:int)[1]
    | join kind=inner hint.remote=left (arg("").healthresourcechanges
        __SCOPE__
        | where tostring(properties.targetResourceType) =~ 'microsoft.resourcehealth/resourceannotations'
        | where tostring(properties.changes['properties.annotationName'].newValue) in (__BOOT__)
        | extend Ts = todatetime(properties.changeAttributes.timestamp)
        | where Ts > ago({StartupGraceMin}m)
        | summarize L = make_list(strcat(tostring(Ts), '|', tolower(tostring(properties.targetResourceId))))
        | extend k = 1) on k
    | mv-expand L to typeof(string)
    | project LastBoot = todatetime(tostring(split(L, '|')[0])), VmId = tostring(split(tostring(split(L, '|')[1]), '/providers/microsoft.resourcehealth/')[0]);
let bootsNow = datatable(k:int)[1]
    | join kind=inner hint.remote=left (arg("").healthresources
        | where type =~ 'microsoft.resourcehealth/resourceannotations'
        __SCOPE__
        | where tostring(properties.annotationName) in (__BOOT__)
        | extend Ts = todatetime(properties.occurredTime)
        | where Ts > ago({StartupGraceMin}m)
        | summarize L = make_list(strcat(tostring(Ts), '|', tolower(tostring(properties.targetResourceId))))
        | extend k = 1) on k
    | mv-expand L to typeof(string)
    | project LastBoot = todatetime(tostring(split(L, '|')[0])), VmId = tostring(split(L, '|')[1]);
let recentBoot = union boots, bootsNow | summarize LastBoot = max(LastBoot) by VmId;
let lastHb = Heartbeat
    | where TimeGenerated > ago(1d)
    __HBSCOPE__
    | summarize LastHeartbeat = max(TimeGenerated) by VmId = tolower(_ResourceId);
let state = vms
    | join kind=leftouter recentBoot on VmId
    | join kind=leftouter lastHb on VmId
    | extend InGrace = NewVm or isnotnull(LastBoot)
    | extend MinutesSince = iff(isnull(LastHeartbeat), real(null), round((now() - LastHeartbeat) / 1m, 1))
    | extend Health = case(Power != 'Running', Power,
                           isnotnull(LastHeartbeat) and LastHeartbeat >= ago(T), 'Healthy',
                           InGrace, 'Starting', 'Unhealthy')
    | extend Detail = case(Health == 'Starting', 'Started within the grace period, waiting for the first heartbeat',
                           Power != 'Running', strcat('VM is ', tolower(Power)),
                           isnull(LastHeartbeat), 'Running, no AMA heartbeat in 24h',
                           strcat('Running, last heartbeat ', tostring(MinutesSince), ' min ago'))
    | project VmId, VM, SubscriptionId, ResourceGroup, Power, Health, LastBoot, LastHeartbeat, MinutesSince, Detail;
'@

    # Aggregated history - no per-VM rows. Running(t) = RunningNow - (power-ons after t) + (power-offs after t);
    # all VMs(t) = VMs now - creations after t + deletions after t (ARG resourcechanges, 14 days).
    $timeline = & $expand @'
let Grace = {StartupGraceMin};
let wStart = now() - {ChartHours}h;
// Bucket size: threshold, widened for long ranges (max. ~300 points)
let Bk = max_of({ThresholdMin}, toint(ceiling((now() - wStart) / 1m / 300.0)));
let nowB = tolong(now()) / 600000000 / Bk;
let firstB = tolong(wStart) / 600000000 / Bk;
let m2000 = tolong(datetime(2000-01-01)) / 600000000;
let current = datatable(k:int)[1]
    | join kind=inner hint.remote=left (arg("").Resources
        | where type =~ 'microsoft.compute/virtualmachines'
        __SCOPE__
        | summarize RunningNow = sum(iff(tostring(properties.extended.instanceView.powerState.code) =~ 'PowerState/running', 1, 0)), TotalNow = count()
        | extend k = 1) on k
    | project k, RunningNow, TotalNow;
// Power-state changes + create/delete from ARG change history (14 days), packed per day as one number per event:
// E = VM hash * 100000 + minute of day * 16 + NewRun * 8 + PrevRun * 4 + (1 = create, 2 = delete).
// Only events touching the running state are sent; an unknown previous state is treated as unchanged.
let ev = datatable(k:int)[1]
    | join kind=inner hint.remote=left (arg("").resourcechanges
        __SCOPE__
        | where tostring(properties.targetResourceType) =~ 'microsoft.compute/virtualmachines'
        | extend C = tostring(properties.changeType), Ts = todatetime(properties.changeAttributes.timestamp),
                 NewP = tostring(properties.changes['properties.extended.instanceView.powerState.code'].newValue),
                 PrevP = tostring(properties.changes['properties.extended.instanceView.powerState.code'].previousValue)
        | where Ts >= ago({ChartHours}h) - {StartupGraceMin}m - {ThresholdMin}m
        | extend Life = case(C == 'Create', 1, C == 'Delete', 2, 0)
        | extend NewRun = iff(NewP =~ 'PowerState/running', 1, 0)
        | extend PrevRun = case(Life == 1, 0, isempty(PrevP), NewRun, PrevP =~ 'PowerState/running', 1, 0)
        | where Life > 0 or (isnotempty(NewP) and (NewRun == 1 or PrevRun == 1))
        | extend M = tolong(Ts) / 600000000
        | extend D = M / 1440
        | summarize L = make_list(hash(tolower(tostring(properties.targetResourceId)), 1000000000) * 100000 + (M % 1440) * 16 + NewRun * 8 + PrevRun * 4 + Life) by D
        | extend k = 1) on k
    | mv-expand L to typeof(long)
    | extend Vm = L / 100000, R = L % 100000
    | project Vm, M = D * 1440 + R / 16, NewRun = iff(R % 16 >= 8, 1, 0), PrevRun = iff(R % 8 >= 4, 1, 0), Life = R % 4
    // Deleted VMs are no longer running; state before a VM's first event = its previous value
    | extend NewRun = iff(Life == 2, 0, NewRun)
    | order by Vm asc, M asc
    | extend Before = iff(prev(Vm) == Vm, prev(NewRun), PrevRun)
    | project M, Up = iff(NewRun > Before, 1, 0), Down = iff(NewRun < Before, 1, 0), Cr = iff(Life == 1, 1, 0), De = iff(Life == 2, 1, 0);
let net = ev | summarize NetRun = sum(Up - Down), NetAll = sum(Cr - De) by B = M / Bk;
// Power-ons count as "Starting" for every bucket that ends within the grace period after them
let starting = ev
    | where Up == 1
    | extend Bs = range(M / Bk, (M + Grace) / Bk - 1, 1)
    | mv-expand Bs to typeof(long)
    | summarize Starting = count() by B = Bs;
let healthy = Heartbeat
    | where TimeGenerated >= wStart - {ThresholdMin}m
    __HBSCOPE__
    | summarize by B = tolong(TimeGenerated) / 600000000 / Bk, _ResourceId
    | summarize Healthy = count() by B;
range B from firstB to nowB step 1
| join kind=leftouter net on B
| order by B desc
| extend Cum = row_cumsum(coalesce(NetRun, 0)), CumAll = row_cumsum(coalesce(NetAll, 0))
| extend AfterRun = Cum - coalesce(NetRun, 0), AfterAll = CumAll - coalesce(NetAll, 0)
| where B < nowB
| extend k = 1
| join kind=inner current on k
| join kind=leftouter healthy on B
| join kind=leftouter starting on B
| extend Running = max_of(0, RunningNow - AfterRun), All = max_of(0, TotalNow - AfterAll)
| extend Healthy = min_of(coalesce(Healthy, 0), Running)
| extend Starting = min_of(coalesce(Starting, 0), Running - Healthy)
| project TimeGenerated = datetime(2000-01-01) + ((B + 1) * Bk - m2000) * 1m,
          Running, Healthy, Unhealthy = Running - Healthy - Starting, Starting, Deallocated = max_of(0, All - Running)
| order by TimeGenerated asc
'@

    @{
        State    = $state
        Timeline = $timeline
        Counts   = $state + @'

state
| summarize Running = sum(iff(Power == 'Running', 1, 0)), Healthy = sum(iff(Health == 'Healthy', 1, 0)),
            Unhealthy = sum(iff(Health == 'Unhealthy', 1, 0)), Starting = sum(iff(Health == 'Starting', 1, 0)),
            Deallocated = sum(iff(Power == 'Deallocated', 1, 0)), Total = count()
'@
        Groups   = $state + @'

state
| summarize Total = count(), Running = sum(iff(Power == 'Running', 1, 0)), Healthy = sum(iff(Health == 'Healthy', 1, 0)),
            Unhealthy = sum(iff(Health == 'Unhealthy', 1, 0)), Starting = sum(iff(Health == 'Starting', 1, 0)),
            Deallocated = sum(iff(Power == 'Deallocated', 1, 0)) by SubscriptionId, ResourceGroup
| extend UnhealthyPct = iff(Running == 0, 0.0, round(100.0 * Unhealthy / Running, 1))
| order by Unhealthy desc, Running desc
'@
    }
}

function New-AmaHeartbeatWorkbookJson {
    # Builds the serialized Azure Monitor workbook (dashboard) - reads existing data only (arg() + Heartbeat)
    # Portable: the workspace is a picker parameter; empty WorkspaceResourceId = user selects it
    param(
        [string]$SubscriptionId = '*',
        [string]$WorkspaceResourceId = '',
        [string]$ResourceGroupName = '*',
        [int]$ThresholdMinutes = 10,
        [int]$StartupGraceMinutes = 10
    )

    $kql = Get-AmaHeartbeatKql

    # One single-row query per tile (keeps each tile's colour)
    $tile = { param($Title, $Subtitle, $Column) $kql.Counts + "`n| project Title = '$Title', Subtitle = '$Subtitle', Count = $Column" }

    $timelineQuery = $kql.Timeline + "`n| project TimeGenerated, Running, Healthy, Unhealthy, Deallocated, Starting"

    $groupsQuery = $kql.Groups + "`n| project ResourceGroup, SubscriptionId, Running, Healthy, Unhealthy, UnhealthyPct, Starting, Deallocated, Total"

    $detailQuery = $kql.State + @'

state
| where Health in ('Unhealthy', 'Starting')
| order by Health desc, VM asc
| take 5000
| project Health, VM, ResourceGroup, SubscriptionId, LastBoot, LastHeartbeat, MinutesSince, Detail
'@

    $laCommon = @{
        version                 = 'KqlItem/1.0'
        queryType               = 0
        resourceType            = 'microsoft.operationalinsights/workspaces'
        crossComponentResources = @('{Workspace}')
        timeContext             = @{ durationMs = 86400000 }
    }
    $countTile = {
        param($Name, $Title, $Subtitle, $Column, $Palette)
        @{
            type        = 3
            name        = $Name
            customWidth = '20'
            content     = $laCommon + @{
                query         = (& $tile $Title $Subtitle $Column)
                size          = 4
                visualization = 'tiles'
                tileSettings  = (New-CountTile -CountColumn 'Count' -Palette $Palette)
            }
        }
    }
    $healthIcon = @{
        columnMatch   = 'Health'
        formatter     = 18
        formatOptions = @{
            thresholdsOptions = 'icons'
            thresholdsGrid    = @(
                @{ operator = '=='; thresholdValue = 'Unhealthy'; representation = '4'; text = '{0}{1}' }
                @{ operator = '=='; thresholdValue = 'Starting'; representation = 'pending'; text = '{0}{1}' }
                @{ operator = '=='; thresholdValue = 'Healthy'; representation = 'success'; text = '{0}{1}' }
                @{ operator = 'Default'; thresholdValue = $null; representation = 'Unknown'; text = '{0}{1}' }
            )
        }
    }
    $paramId = { param($n) Get-LabDeterministicGuid "$ResourceGroupName-$n" }

    $items = @(
        @{
            type    = 1
            name    = 'header'
            content = @{ json = "## AMA Heartbeat Health`nA running VM is **healthy** when the Azure Monitor Agent sent a heartbeat within the threshold. Without a heartbeat it is **Starting** during the startup grace period after a start/restart, and **unhealthy** afterwards. Deallocated/stopped VMs are counted separately.`n`n_Source: Azure Resource Graph (power state, change history, Resource Health) via ``arg()`` + Log Analytics ``Heartbeat`` table - no additional data is collected. Aggregated for 40k+ VMs; set Subscription/Resource group to ``*`` for all. github.com/chrochma/AMAHeartbeats_" }
        }
        @{
            type    = 9
            name    = 'parameters'
            content = @{
                version      = 'KqlParameterItem/1.0'
                style        = 'pills'
                queryType    = 0
                resourceType = 'microsoft.operationalinsights/workspaces'
                parameters   = @(
                    @{
                        id = (& $paramId 'p6'); version = 'KqlParameterItem/1.0'; name = 'Workspace'; label = 'Log Analytics workspace'; type = 5; isRequired = $true
                        value                   = $(if ($WorkspaceResourceId) { $WorkspaceResourceId } else { $null })
                        query                   = "resources | where type =~ 'microsoft.operationalinsights/workspaces' | project id"
                        crossComponentResources = @('value::all')
                        typeSettings            = @{ resourceTypeFilter = @{ 'microsoft.operationalinsights/workspaces' = $true }; additionalResourceOptions = @(); showDefault = $false }
                        queryType               = 1
                        resourceType            = 'microsoft.resourcegraph/resources'
                    }
                    @{ id = (& $paramId 'p5'); version = 'KqlParameterItem/1.0'; name = 'Subscription'; label = 'Subscription ID (* = all)'; type = 1; isRequired = $true; value = $SubscriptionId }
                    @{ id = (& $paramId 'p1'); version = 'KqlParameterItem/1.0'; name = 'ThresholdMin'; label = 'Heartbeat threshold (min)'; type = 1; isRequired = $true; value = "$ThresholdMinutes" }
                    @{ id = (& $paramId 'p3'); version = 'KqlParameterItem/1.0'; name = 'StartupGraceMin'; label = 'Startup grace (min)'; type = 1; isRequired = $true; value = "$StartupGraceMinutes" }
                    @{ id = (& $paramId 'p2'); version = 'KqlParameterItem/1.0'; name = 'ResourceGroup'; label = 'Resource group (* = all)'; type = 1; isRequired = $true; value = $ResourceGroupName }
                    @{
                        # Fixed hour values (locale independent) instead of a time range picker
                        id = (& $paramId 'p7'); version = 'KqlParameterItem/1.0'; name = 'ChartHours'; label = 'Chart time range'; type = 2; isRequired = $true
                        value        = '24'
                        jsonData     = (@(
                                @{ value = '1'; label = 'Last hour' }, @{ value = '4'; label = 'Last 4 hours' }, @{ value = '12'; label = 'Last 12 hours' },
                                @{ value = '24'; label = 'Last 24 hours' }, @{ value = '72'; label = 'Last 3 days' }, @{ value = '168'; label = 'Last 7 days' }, @{ value = '336'; label = 'Last 14 days' }
                            ) | ConvertTo-Json -Compress)
                        typeSettings = @{ additionalResourceOptions = @(); showDefault = $false }
                    }
                )
            }
        }
        (& $countTile 'running-count' 'Running' 'VMs in running state' 'Running' 'blue')
        (& $countTile 'healthy-count' 'Healthy' 'AMA heartbeat within {ThresholdMin} min' 'Healthy' 'green')
        (& $countTile 'unhealthy-count' 'Unhealthy' 'past grace, no heartbeat > {ThresholdMin} min' 'Unhealthy' 'redBright')
        (& $countTile 'starting-count' 'Starting' 'started < {StartupGraceMin} min ago, no heartbeat yet' 'Starting' 'gray')
        (& $countTile 'deallocated-count' 'Deallocated' 'VMs currently deallocated' 'Deallocated' 'purple')
        @{
            type    = 3
            name    = 'health-timeline'
            content = @{
                version                 = 'KqlItem/1.0'
                title                   = 'Running VMs: healthy vs. unhealthy, plus deallocated (bucket = threshold, wider for long ranges)'
                query                   = $timelineQuery
                size                    = 0
                queryType               = 0
                resourceType            = 'microsoft.operationalinsights/workspaces'
                crossComponentResources = @('{Workspace}')
                # 15 days: covers the longest chart range plus the threshold lookback
                timeContext             = @{ durationMs = 1296000000 }
                visualization           = 'linechart'
                chartSettings           = @{
                    seriesLabelSettings = @(
                        @{ seriesName = 'Running'; label = 'Running'; color = 'blue' }
                        @{ seriesName = 'Healthy'; label = 'Healthy'; color = 'green' }
                        @{ seriesName = 'Unhealthy'; label = 'Unhealthy'; color = 'redBright' }
                        @{ seriesName = 'Deallocated'; label = 'Deallocated / stopped'; color = 'purple' }
                        @{ seriesName = 'Starting'; label = 'Starting (grace)'; color = 'gray' }
                    )
                }
            }
        }
        @{
            type    = 3
            name    = 'groups'
            content = $laCommon + @{
                title         = 'Health grouped by resource group'
                query         = $groupsQuery
                size          = 0
                visualization = 'table'
                gridSettings  = @{
                    formatters = @(
                        @{ columnMatch = 'Healthy'; formatter = 4; formatOptions = @{ palette = 'green' } }
                        @{ columnMatch = 'Unhealthy'; formatter = 4; formatOptions = @{ palette = 'red' } }
                        @{ columnMatch = 'UnhealthyPct'; formatter = 0; numberFormat = @{ unit = 1; options = @{ style = 'decimal'; maximumFractionDigits = 1 } } }
                        @{ columnMatch = 'Deallocated'; formatter = 4; formatOptions = @{ palette = 'purple' } }
                    )
                    filter        = $true
                    labelSettings = @(@{ columnId = 'UnhealthyPct'; label = 'Unhealthy % of running' })
                }
            }
        }
        @{
            type    = 3
            name    = 'vm-details'
            content = $laCommon + @{
                title         = 'Running VMs that are not healthy (unhealthy + starting, max. 5000 - use the groups table to narrow the scope)'
                query         = $detailQuery
                size          = 0
                visualization = 'table'
                noDataMessage = 'All running VMs are healthy.'
                gridSettings  = @{
                    formatters = @(
                        $healthIcon
                        @{ columnMatch = 'MinutesSince'; formatter = 0; numberFormat = @{ unit = 0; options = @{ style = 'decimal'; maximumFractionDigits = 1 } } }
                    )
                    filter        = $true
                    labelSettings = @(@{ columnId = 'MinutesSince'; label = 'Heartbeat age (min)' })
                }
            }
        }
    )

    $workbook = [ordered]@{
        version             = 'Notebook/1.0'
        items               = $items
        fallbackResourceIds = @(if ($WorkspaceResourceId) { $WorkspaceResourceId } else { 'Azure Monitor' })
        '$schema'           = 'https://github.com/Microsoft/Application-Insights-Workbooks/blob/master/schema/workbook.json'
    }
    return ($workbook | ConvertTo-Json -Depth 30 -Compress)
}

function Select-AmaHeartbeatLab {
    # Lets the user pick an existing lab resource group (tagged by AzLabBuilder)
    $labs = @(Get-AzResourceGroup -Tag @{ AzLabBuilderScenario = $script:AmaHbScenarioTag } -ErrorAction SilentlyContinue | Sort-Object ResourceGroupName)
    if ($labs.Count -eq 0) { Write-LabStatus -Level Warn -Message 'No AMA Heartbeat lab found in this subscription.'; return $null }
    if ($labs.Count -eq 1) { Write-LabStatus -Level Info -Message ('Lab: {0} ({1})' -f $labs[0].ResourceGroupName, $labs[0].Location); return $labs[0].ResourceGroupName }
    Write-LabSection -Title 'AMA Heartbeat labs'
    for ($i = 0; $i -lt $labs.Count; $i++) { Write-Host ('   [{0}] {1} ({2})' -f ($i + 1), $labs[$i].ResourceGroupName, $labs[$i].Location) }
    $pick = Read-LabValue -Prompt 'Lab number' -Default '1' -Pattern '^\d+$' -PatternHint 'Enter a number.'
    $idx = [int]$pick - 1
    if ($idx -lt 0 -or $idx -ge $labs.Count) { return $null }
    return $labs[$idx].ResourceGroupName
}

function Get-AmaHeartbeatWorkbookUrl {
    param([Parameter(Mandatory)][string]$ResourceGroupName)
    $wb = Get-AzResource -ResourceGroupName $ResourceGroupName -ResourceType 'Microsoft.Insights/workbooks' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $wb) { return $null }
    return ('https://portal.azure.com/#@{0}/resource{1}/workbook' -f (Get-AzContext).Tenant.Id, $wb.ResourceId)
}

function Watch-LabDeployment {
    # Polls deployment operations while the background job runs
    param([Parameter(Mandatory)]$Job, [string]$ResourceGroupName, [string]$DeploymentName, [int]$ExpectedOps)
    $start = Get-Date
    while ($Job.State -in 'NotStarted', 'Running') {
        Start-Sleep -Seconds 10
        $ops = @(Get-AzResourceGroupDeploymentOperation -ResourceGroupName $ResourceGroupName -DeploymentName $DeploymentName -ErrorAction SilentlyContinue)
        $done = @($ops | Where-Object ProvisioningState -eq 'Succeeded').Count
        $failed = @($ops | Where-Object ProvisioningState -eq 'Failed').Count
        $pct = if ($ExpectedOps -gt 0) { [Math]::Min(100, [int](100 * $done / $ExpectedOps)) } else { 0 }
        $bar = ('#' * [int]($pct / 4)).PadRight(25, '.')
        $elapsed = (Get-Date) - $start
        Write-Host ("`r  [{0}] {1,3}%  {2}/{3} resources  failed:{4}  {5:mm\:ss}   " -f $bar, $pct, $done, $ExpectedOps, $failed, $elapsed) -NoNewline -ForegroundColor Cyan
    }
    Write-Host ''
}

function Invoke-AmaHeartbeatDeploy {
    Write-LabSection -Title 'Scenario: AMA Heartbeat lab'
    Write-Host '  Deploys N Linux VMs (cheapest usable SKU), Azure Monitor Agent, a DCR to a new'
    Write-Host '  Log Analytics workspace and an Azure Monitor workbook showing running VMs and'
    Write-Host '  VMs without AMA heartbeat for more than the threshold (default 10 min).'
    Write-Host ''

    $location = Read-LabValue -Prompt 'Region' -Default 'swedencentral' -Pattern '^[a-z0-9]+$' -PatternHint 'Use the region name, e.g. swedencentral.'
    $rgName = Read-LabValue -Prompt 'Resource group' -Default 'rg-azlab-amahb' -Pattern '^[\w\-\.\(\)]{1,90}$' -PatternHint 'Letters, digits, - _ . ( ) only.'
    $vmCount = [int](Read-LabValue -Prompt 'Number of VMs' -Default '10' -Pattern '^([1-9]|[1-4]\d|50)$' -PatternHint '1-50.')
    $vmPrefix = Read-LabValue -Prompt 'VM name prefix' -Default 'vm-amahb' -Pattern '^[a-z][a-z0-9\-]{1,11}$' -PatternHint '2-12 chars, lower case, digits, hyphen.'
    $threshold = [int](Read-LabValue -Prompt 'Heartbeat threshold (minutes)' -Default '10' -Pattern '^\d{1,3}$' -PatternHint 'Minutes, e.g. 10.')

    $existing = Get-AzResourceGroup -Name $rgName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-LabStatus -Level Warn -Message "Resource group '$rgName' already exists ($($existing.Location)). The deployment is incremental."
        if ($existing.Location -ne $location) { Write-LabStatus -Level Error -Message 'Existing resource group is in a different region.'; return }
        if (-not (Read-LabConfirm -Prompt 'Continue and update it?')) { return }
    }

    Register-LabResourceProviders -Namespaces @('Microsoft.Compute', 'Microsoft.Network', 'Microsoft.OperationalInsights', 'Microsoft.Insights')
    # 2 GB minimum: on 1 GB SKUs (B1s) AMA + Defender for Endpoint run the guest out of memory and hang it
    $sku = Select-LabCheapestVmSku -Location $location -VmCount $vmCount -MinMemoryGB 2

    $ctx = Get-AzContext
    $subId = $ctx.Subscription.Id
    $suffix = (Get-LabDeterministicGuid "$subId/$rgName").Substring(0, 6)
    $wsName = "law-azlab-amahb-$suffix"
    $dcrName = "dcr-azlab-amahb-$suffix"
    $wsId = "/subscriptions/$subId/resourceGroups/$rgName/providers/Microsoft.OperationalInsights/workspaces/$wsName"
    $workbookId = Get-LabDeterministicGuid "$subId/$rgName/workbook"

    Write-LabSection -Title 'Deployment plan'
    Write-Host ('   Subscription   : {0}' -f $ctx.Subscription.Name)
    Write-Host ('   Region / RG    : {0} / {1}' -f $location, $rgName)
    Write-Host ('   VMs            : {0} x {1} ({2} vCPU, {3} GB) Ubuntu 22.04, Standard HDD, no public IP' -f $vmCount, $sku.Name, $sku.vCPUs, $sku.MemoryGB)
    Write-Host ('   Monitoring     : AMA + DCR {0} -> {1}' -f $dcrName, $wsName)
    Write-Host ('   Dashboard      : Workbook "AzLabBuilder - AMA Heartbeat Health" (threshold {0} min, startup grace 10 min)' -f $threshold)
    if ($null -ne $sku.HourlyUSD) {
        Write-Host ('   Est. compute   : ~{0:N2} USD/day (disks, logs not included)' -f ($sku.HourlyUSD * 24 * $vmCount)) -ForegroundColor Yellow
    }
    if (-not (Read-LabConfirm -Prompt 'Deploy now?' -Default $true)) { return }

    $tags = @{ AzLabBuilderScenario = $script:AmaHbScenarioTag; CreatedBy = 'AzLabBuilder'; CreatedOn = (Get-Date -Format 'yyyy-MM-dd') }
    if (-not $existing) {
        Write-LabStatus -Level Step -Message "Creating resource group $rgName ..."
        New-AzResourceGroup -Name $rgName -Location $location -Tag $tags -ErrorAction Stop | Out-Null
    }

    $password = New-LabPassword
    $workbookJson = New-AmaHeartbeatWorkbookJson -SubscriptionId $subId -WorkspaceResourceId $wsId -ResourceGroupName $rgName -ThresholdMinutes $threshold
    $deploymentName = 'azlab-amahb-{0}' -f (Get-Date -Format 'yyyyMMddHHmmss')
    $params = @{
        location               = $location
        vmCount                = $vmCount
        vmPrefix               = $vmPrefix
        vmSize                 = $sku.Name
        adminUsername          = 'labadmin'
        # Plain value required by TemplateParameterObject; 'securestring' in the template keeps it out of logs
        adminPassword          = $password
        workspaceName          = $wsName
        dcrName                = $dcrName
        workbookId             = $workbookId
        workbookSerializedData = $workbookJson
        tags                   = $tags
    }

    Write-LabStatus -Level Step -Message "Starting deployment $deploymentName (typically 5-10 minutes) ..."
    $job = New-AzResourceGroupDeployment -Name $deploymentName -ResourceGroupName $rgName -TemplateFile $script:AmaHbTemplate `
        -TemplateParameterObject $params -AsJob -ErrorAction Stop
    # NIC, VM, AMA extension, DCR association per VM + workspace, DCR, NSG, VNet, workbook
    Watch-LabDeployment -Job $job -ResourceGroupName $rgName -DeploymentName $deploymentName -ExpectedOps (4 * $vmCount + 5)

    try {
        $result = Receive-Job -Job $job -Wait -AutoRemoveJob -ErrorAction Stop
    } catch {
        $result = $null
        Write-LabStatus -Level Error -Message $_.Exception.Message
    }
    if (-not $result -or $result.ProvisioningState -ne 'Succeeded') {
        Write-LabStatus -Level Error -Message 'Deployment failed. Failed operations:'
        Get-AzResourceGroupDeploymentOperation -ResourceGroupName $rgName -DeploymentName $deploymentName -ErrorAction SilentlyContinue |
            Where-Object ProvisioningState -eq 'Failed' |
            ForEach-Object { Write-Host ('    - {0}: {1}' -f $_.TargetResource, $_.StatusMessage) -ForegroundColor Red }
        return
    }

    Write-LabStatus -Level Ok -Message 'Deployment succeeded.'
    $url = Get-AmaHeartbeatWorkbookUrl -ResourceGroupName $rgName
    Write-Host ''
    Write-Host '  Dashboard (Azure Monitor > Workbooks):' -ForegroundColor Cyan
    Write-Host "  $url"
    Write-Host ''
    Write-LabStatus -Level Info -Message 'VMs show as "Starting" for the startup grace period; first AMA heartbeats arrive ~5-10 minutes after the agent install.'
    Write-LabStatus -Level Info -Message 'VM admin user: labadmin (no public IP; use Serial Console / Bastion if needed).'
    if (Read-LabConfirm -Prompt 'Show the generated VM admin password once?') { Write-Host "  $password" -ForegroundColor Yellow }
    if (Read-LabConfirm -Prompt 'Open the dashboard in the browser?' -Default $true) { Start-Process $url }
}

function Get-AmaHeartbeatHealth {
    # Same startup-aware logic as the dashboard (State KQL): ARG power state + Resource Health start events + AMA heartbeat
    param([Parameter(Mandatory)][string]$ResourceGroupName, [int]$ThresholdMinutes = 10, [int]$StartupGraceMinutes = 10)
    $ws = Get-AzOperationalInsightsWorkspace -ResourceGroupName $ResourceGroupName -ErrorAction Stop | Select-Object -First 1
    if (-not $ws) { throw "No Log Analytics workspace found in '$ResourceGroupName'." }
    $subId = (Get-AzContext).Subscription.Id
    $q = (Get-AmaHeartbeatKql).State + "`nstate`n| order by VM asc"
    $q = $q.Replace('{Subscription}', $subId).Replace('{ThresholdMin}', "$ThresholdMinutes").Replace('{StartupGraceMin}', "$StartupGraceMinutes").Replace('{ResourceGroup}', $ResourceGroupName)
    $res = Invoke-AzOperationalInsightsQuery -WorkspaceId $ws.CustomerId -Query $q -ErrorAction Stop
    if ($res.Error) { throw "Health query failed: $($res.Error.Message)" }
    foreach ($r in $res.Results) {
        [pscustomobject]@{
            VM            = $r.VM
            PowerState    = $r.Power
            Health        = $r.Health
            LastHeartbeat = if ($r.LastHeartbeat) { ([datetime]$r.LastHeartbeat).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss') + 'Z' } else { '-' }
            MinutesAgo    = if ($r.MinutesSince) { $r.MinutesSince } else { '-' }
        }
    }
}

function Show-AmaHeartbeatHealth {
    $rg = Select-AmaHeartbeatLab
    if (-not $rg) { return }
    $threshold = [int](Read-LabValue -Prompt 'Heartbeat threshold (minutes)' -Default '10' -Pattern '^\d{1,3}$' -PatternHint 'Minutes.')
    $grace = [int](Read-LabValue -Prompt 'Startup grace after VM start (minutes)' -Default '10' -Pattern '^\d{1,3}$' -PatternHint 'Minutes.')
    $watch = Read-LabConfirm -Prompt 'Watch mode (refresh every 60s, Q to stop)?'
    do {
        Write-LabBanner
        Write-LabSection -Title ("Health of '{0}' - {1:HH:mm:ss}" -f $rg, (Get-Date))
        try {
            $rows = @(Get-AmaHeartbeatHealth -ResourceGroupName $rg -ThresholdMinutes $threshold -StartupGraceMinutes $grace)
        } catch {
            Write-LabStatus -Level Error -Message $_.Exception.Message; break
        }
        if ($rows.Count -eq 0) { Write-LabStatus -Level Warn -Message 'No VMs found.'; break }
        $count = { param($h) @($rows | Where-Object Health -eq $h).Count }
        $unhealthy = & $count 'Unhealthy'
        Write-Host ('   VMs running : {0} / {1}' -f @($rows | Where-Object PowerState -eq 'Running').Count, $rows.Count) -ForegroundColor Cyan
        Write-Host ('   Healthy     : {0}' -f (& $count 'Healthy')) -ForegroundColor Green
        Write-Host ('   Unhealthy   : {0}' -f $unhealthy) -ForegroundColor $(if ($unhealthy) { 'Red' } else { 'Green' })
        Write-Host ('   Starting    : {0}  (started < {1} min ago, no heartbeat yet)' -f (& $count 'Starting'), $grace) -ForegroundColor Gray
        Write-Host ('   Deallocated : {0}' -f (& $count 'Deallocated')) -ForegroundColor DarkGray
        Write-Host ''
        # Large scopes: list only the VMs that need attention
        $list = if ($rows.Count -le 50) { $rows } else { @($rows | Where-Object Health -in 'Unhealthy', 'Starting' | Select-Object -First 50) }
        Write-LabTable -Rows $list -Columns @('VM', 'PowerState', 'Health', 'LastHeartbeat', 'MinutesAgo') -ColorSelector {
            param($r) switch ($r.Health) { 'Unhealthy' { 'Red' } 'Healthy' { 'Green' } 'Starting' { 'Yellow' } default { 'DarkGray' } }
        }
        if (-not $watch) { break }
        # Wait 60s, stop early on Q
        $stop = $false
        for ($i = 0; $i -lt 60 -and -not $stop; $i++) {
            Start-Sleep -Seconds 1
            try { if ([Console]::KeyAvailable -and [Console]::ReadKey($true).Key -eq 'Q') { $stop = $true } } catch { }
        }
    } while (-not $stop)
}

function Open-AmaHeartbeatDashboard {
    $rg = Select-AmaHeartbeatLab
    if (-not $rg) { return }
    $url = Get-AmaHeartbeatWorkbookUrl -ResourceGroupName $rg
    if (-not $url) { Write-LabStatus -Level Warn -Message 'Workbook not found in the lab resource group.'; return }
    Write-Host "  $url"
    Start-Process $url
}

$script:AmaHbCrashRule = 'AzLabBuilder-AmaCrash'

function Get-AmaHeartbeatCrashState {
    # Lab VMs with private IP, power state and whether the NSG rule currently blocks their AMA traffic
    param([Parameter(Mandatory)][string]$ResourceGroupName)
    $nsg = Get-AzNetworkSecurityGroup -ResourceGroupName $ResourceGroupName -ErrorAction Stop | Select-Object -First 1
    if (-not $nsg) { throw "No network security group found in '$ResourceGroupName'." }
    $rule = $nsg.SecurityRules | Where-Object Name -eq $script:AmaHbCrashRule
    $blocked = @(if ($rule) { $rule.SourceAddressPrefix })
    $power = @{}
    Get-AzVM -ResourceGroupName $ResourceGroupName -Status -ErrorAction Stop | ForEach-Object { $power[$_.Name] = ($_.PowerState -replace '^VM ', '') }
    $vms = foreach ($nic in Get-AzNetworkInterface -ResourceGroupName $ResourceGroupName -ErrorAction Stop | Where-Object { $_.VirtualMachine }) {
        $name = ($nic.VirtualMachine.Id -split '/')[-1]
        $ip = $nic.IpConfigurations[0].PrivateIpAddress
        [pscustomobject]@{ VM = $name; IP = $ip; PowerState = $power[$name]; AmaBlocked = ($ip -in $blocked) }
    }
    [pscustomobject]@{ Nsg = $nsg; Rule = $rule; VMs = @($vms | Sort-Object VM) }
}

function Set-AmaHeartbeatCrash {
    # Writes the deny rule (outbound to service tag AzureMonitor) for the given IPs; no IPs = remove the rule
    param([Parameter(Mandatory)]$Nsg, [string[]]$SourceIps)
    $SourceIps = @($SourceIps | Where-Object { $_ })
    if ($Nsg.SecurityRules | Where-Object Name -eq $script:AmaHbCrashRule) {
        $Nsg = Remove-AzNetworkSecurityRuleConfig -NetworkSecurityGroup $Nsg -Name $script:AmaHbCrashRule
    }
    if ($SourceIps) {
        $Nsg = Add-AzNetworkSecurityRuleConfig -NetworkSecurityGroup $Nsg -Name $script:AmaHbCrashRule `
            -Description 'AzLabBuilder: simulated AMA outage (blocks heartbeat to Azure Monitor)' `
            -Direction Outbound -Access Deny -Priority 100 -Protocol '*' `
            -SourceAddressPrefix @($SourceIps | Where-Object { $_ } | Sort-Object -Unique) -SourcePortRange '*' `
            -DestinationAddressPrefix 'AzureMonitor' -DestinationPortRange '*'
    }
    Set-AzNetworkSecurityGroup -NetworkSecurityGroup $Nsg -ErrorAction Stop | Out-Null
}

function Invoke-AmaHeartbeatCrashSim {
    # Simulates an AMA failure: the VM keeps running, but its heartbeat can no longer reach Azure Monitor
    $rg = Select-AmaHeartbeatLab
    if (-not $rg) { return }
    while ($true) {
        Write-LabSection -Title "Simulate AMA outage in '$rg'"
        Write-LabStatus -Level Step -Message 'Reading VMs and NSG ...'
        $state = Get-AmaHeartbeatCrashState -ResourceGroupName $rg
        Write-LabTable -Rows $state.VMs -Columns @('VM', 'IP', 'PowerState', 'AmaBlocked') -ColorSelector {
            param($r) if ($r.AmaBlocked) { 'Red' } elseif ($r.PowerState -eq 'running') { 'Green' } else { 'DarkGray' }
        }
        $blocked = @($state.VMs | Where-Object AmaBlocked)
        $candidates = @($state.VMs | Where-Object { -not $_.AmaBlocked -and $_.PowerState -eq 'running' })
        Write-Host ''
        Write-Host ('   Blocked: {0}   Running and not blocked: {1}' -f $blocked.Count, $candidates.Count) -ForegroundColor Cyan
        Write-Host '   [S] Start outage on more VMs   [R] Restore all VMs   [B] Back'
        switch -Regex ((Read-Host '  Choice').Trim()) {
            '^[sS]$' {
                if ($candidates.Count -eq 0) { Write-LabStatus -Level Warn -Message 'No running VM left to block.'; continue }
                $n = [int](Read-LabValue -Prompt "On how many VMs (1-$($candidates.Count))" -Default '1' -Pattern '^\d+$' -PatternHint 'Enter a single number, e.g. 26.')
                if ($n -lt 1 -or $n -gt $candidates.Count) { Write-LabStatus -Level Warn -Message 'Out of range.'; continue }
                $pick = @($candidates | Get-Random -Count $n)
                Write-LabStatus -Level Step -Message ('Blocking AMA on: {0}' -f (($pick | ForEach-Object VM | Sort-Object) -join ', '))
                # ForEach-Object instead of .IP: member access on an empty array fails under StrictMode
                Set-AmaHeartbeatCrash -Nsg $state.Nsg -SourceIps @(@($blocked) + @($pick) | ForEach-Object IP)
                Write-LabStatus -Level Ok -Message 'NSG rule set. Heartbeats stop within ~2 min; VMs show as Unhealthy once the threshold has passed.'
            }
            '^[rR]$' {
                if (-not $state.Rule) { Write-LabStatus -Level Info -Message 'No outage active.'; continue }
                Write-LabStatus -Level Step -Message 'Removing NSG rule ...'
                Set-AmaHeartbeatCrash -Nsg $state.Nsg -SourceIps @()
                Write-LabStatus -Level Ok -Message 'Restored. Heartbeats resume within ~2-5 min.'
            }
            default { return }
        }
    }
}

function Remove-AmaHeartbeatLab {
    $rg = Select-AmaHeartbeatLab
    if (-not $rg) { return }
    Write-LabStatus -Level Warn -Message "This deletes resource group '$rg' and ALL resources in it."
    $confirm = Read-Host "  Type the resource group name to confirm"
    if ($confirm -ne $rg) { Write-LabStatus -Level Info -Message 'Cancelled.'; return }
    Write-LabStatus -Level Step -Message "Deleting $rg in the background ..."
    Remove-AzResourceGroup -Name $rg -Force -AsJob | Out-Null
    Write-LabStatus -Level Ok -Message 'Deletion started (takes a few minutes). Check the portal or re-run the health check.'
}
