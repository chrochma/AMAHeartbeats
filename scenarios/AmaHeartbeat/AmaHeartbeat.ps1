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
      Returns the dashboard KQL (Log Analytics, using arg("") for ARG data - no extra ingestion).
      Workbook placeholders: {ThresholdMin}, {StartupGraceMin}, {ResourceGroup}, {TimeRange:start}.
      Startup = latest Resource Health "VM started/allocated/restarted" annotation (healthresourcechanges,
      healthresources) or the VM creation time. A running VM is only Unhealthy after the grace period.
    #>
    param([Parameter(Mandatory)][string]$SubscriptionId)

    $boot = "'VirtualMachineStartInitiatedByControlPlane','VirtualMachineAllocated','VirtualMachineRestarted','VirtualMachineRebootInitiatedByControlPlane','VirtualMachineRebootInitiatedForPlannedMaintenance','VirtualMachineRedeployInitiatedByControlPlane','VirtualMachineHostRebootedForRepair','VirtualMachineMigrationInitiatedForRepair','VirtualMachineCrashed','VirtualMachineHostCrashed'"
    $off = "'VirtualMachineDeallocationInitiated','VirtualMachineStopInitiatedByControlPlane','VirtualMachineStoppedInternally','VirtualMachinePreempted'"
    $scope = "| where subscriptionId == '$SubscriptionId'`n    | where '{ResourceGroup}' == '*' or resourceGroup =~ '{ResourceGroup}'"

    $vms = @"
let T = {ThresholdMin}m;
let Grace = {StartupGraceMin}m;
let vms = arg("").Resources
    | where type =~ 'microsoft.compute/virtualmachines'
    $scope
    | project VmId = tolower(id), VM = name, ResourceGroup = resourceGroup, Size = tostring(properties.hardwareProfile.vmSize),
              PowerState = tostring(properties.extended.instanceView.powerState.code), Created = todatetime(properties.timeCreated);
"@

    # Current state per VM: power state, last startup, last AMA heartbeat
    $state = $vms + @"

let bootChanges = arg("").healthresourcechanges
    $scope
    | where tostring(properties.targetResourceType) =~ 'microsoft.resourcehealth/resourceannotations'
    | where tostring(properties.changes['properties.annotationName'].newValue) in ($boot)
    | summarize LastBoot = max(todatetime(properties.changeAttributes.timestamp)) by Target = tolower(tostring(properties.targetResourceId));
let bootCurrent = arg("").healthresources
    | where type =~ 'microsoft.resourcehealth/resourceannotations'
    $scope
    | where tostring(properties.annotationName) in ($boot)
    | project Target = tolower(tostring(properties.targetResourceId)), LastBoot = todatetime(properties.occurredTime);
let boots = union bootChanges, bootCurrent
    | extend VmId = tostring(split(Target, '/providers/microsoft.resourcehealth/')[0])
    | summarize LastBoot = max(LastBoot) by VmId;
let lastHb = Heartbeat
    | where TimeGenerated > ago(1d)
    | where Category == 'Azure Monitor Agent'
    | summarize LastHeartbeat = max(TimeGenerated) by VmId = tolower(_ResourceId);
let state = vms
    | join kind=leftouter boots on VmId
    | join kind=leftouter lastHb on VmId
    | extend LastBoot = iff(isnull(LastBoot) or Created > LastBoot, Created, LastBoot)
    | extend Power = case(PowerState =~ 'PowerState/running', 'Running', PowerState =~ 'PowerState/deallocated', 'Deallocated',
                          PowerState =~ 'PowerState/stopped', 'Stopped', isempty(PowerState), 'Unknown', replace_string(PowerState, 'PowerState/', ''))
    | extend UptimeMin = iff(Power == 'Running' and isnotnull(LastBoot), round((now() - LastBoot) / 1m, 1), real(null))
    | extend MinutesSince = iff(isnull(LastHeartbeat), real(null), round((now() - LastHeartbeat) / 1m, 1))
    | extend Health = case(Power != 'Running', Power,
                           isnotnull(LastBoot) and LastBoot > ago(Grace), 'Starting',
                           isnull(LastHeartbeat) or LastHeartbeat < ago(T), 'Unhealthy', 'Healthy')
    | extend Detail = case(Health == 'Starting', strcat('Started ', tostring(UptimeMin), ' min ago (startup grace)'),
                           Power != 'Running', strcat('VM is ', tolower(Power)),
                           isnull(LastHeartbeat), strcat('Up ', tostring(UptimeMin), ' min, no AMA heartbeat in 24h'),
                           strcat('Up ', tostring(UptimeMin), ' min, last heartbeat ', tostring(MinutesSince), ' min ago'))
    | project VmId, VM, ResourceGroup, Size, Power, Health, LastBoot, UptimeMin, LastHeartbeat, MinutesSince, Detail;
"@

    # Per-bin (size = heartbeat threshold) state from Resource Health power events + AMA heartbeats
    $timeline = $vms + @"

let wStart = bin(todatetime('{TimeRange:start}'), T);
let wEnd = bin(now(), T);
let bins = range BinStart from wStart to wEnd - T step T | extend k = 1;
// Power events inside the window only; state is inferred backwards from the current power state.
// arg() transfers at most 1000 rows -> events are packed into one list per VM inside Resource Graph and expanded locally
let events = datatable(k:int)[1]
    | join kind=inner hint.remote=left (arg("").healthresourcechanges
        $scope
        | where tostring(properties.targetResourceType) =~ 'microsoft.resourcehealth/resourceannotations'
        | extend A = tostring(properties.changes['properties.annotationName'].newValue)
        | where A in ($boot) or A in ($off)
        | extend VmId = tostring(split(tolower(tostring(properties.targetResourceId)), '/providers/microsoft.resourcehealth/')[0]),
                 Ts = todatetime(properties.changeAttributes.timestamp)
        | where Ts >= todatetime('{TimeRange:start}') - {StartupGraceMin}m - {ThresholdMin}m
        | extend E = strcat(iff(A in ($boot), '1', '0'), '|', tostring(Ts))
        | summarize Ev = make_list(E) by VmId
        | extend k = 1) on k
    | mv-expand Ev to typeof(string)
    | project VmId, IsBoot = toint(substring(Ev, 0, 1)), Ts = todatetime(substring(Ev, 2));
let hb = Heartbeat
    | where TimeGenerated >= wStart
    | where Category == 'Azure Monitor Agent'
    | summarize by VmId = tolower(_ResourceId), BinStart = bin(TimeGenerated, T)
    | extend HasHb = 1;
bins
| join kind=inner hint.remote=left (vms | project VmId, PowerState, Created | extend k = 1) on k
| extend BinEnd = BinStart + T
| join kind=leftouter hint.remote=left events on VmId
| summarize LastBootTs = max(iff(IsBoot == 1 and Ts < BinEnd, Ts, datetime(null))),
            NextBootTs = min(iff(IsBoot == 1 and Ts >= BinEnd, Ts, datetime(null))),
            NextOffTs = min(iff(IsBoot == 0 and Ts >= BinEnd, Ts, datetime(null)))
            by BinStart, BinEnd, VmId, PowerState, Created
| extend Exists = isnull(Created) or Created < BinEnd
| extend LastBootTs = iff(isnotnull(Created) and Created < BinEnd and (isnull(LastBootTs) or Created > LastBootTs), Created, LastBootTs)
// Next power event after the bin tells the state during the bin (off event -> was running); none -> current state
| extend Running = case(not(Exists), false,
                        isnotnull(NextBootTs) or isnotnull(NextOffTs), coalesce(NextOffTs, datetime(2999-01-01)) < coalesce(NextBootTs, datetime(2999-01-01)),
                        PowerState =~ 'PowerState/running')
| extend Eligible = Running and (isnull(LastBootTs) or LastBootTs <= BinEnd - Grace)
| join kind=leftouter hb on VmId, BinStart
| extend HasHb = coalesce(HasHb, 0)
| summarize Running = sum(iff(Running, 1, 0)),
            Healthy = sum(iff(Eligible and HasHb == 1, 1, 0)),
            Unhealthy = sum(iff(Eligible and HasHb == 0, 1, 0)),
            Starting = sum(iff(Running and not(Eligible), 1, 0)),
            Deallocated = sum(iff(Exists and not(Running), 1, 0))
            by TimeGenerated = BinEnd
| order by TimeGenerated asc
"@

    @{
        State    = $state
        Timeline = $timeline
        Counts   = $state + @"

state
| summarize Running = sum(iff(Power == 'Running', 1, 0)), Healthy = sum(iff(Health == 'Healthy', 1, 0)),
            Unhealthy = sum(iff(Health == 'Unhealthy', 1, 0)), Starting = sum(iff(Health == 'Starting', 1, 0)),
            Deallocated = sum(iff(Power == 'Deallocated', 1, 0)), Total = count()
"@
    }
}

function New-AmaHeartbeatWorkbookJson {
    # Builds the serialized Azure Monitor workbook (dashboard) - reads existing data only (arg() + Heartbeat)
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$WorkspaceResourceId,
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [int]$ThresholdMinutes = 10,
        [int]$StartupGraceMinutes = 10
    )

    $kql = Get-AmaHeartbeatKql -SubscriptionId $SubscriptionId

    # mv-expand is not supported on arg() results -> one single-row query per tile
    $tile = { param($Title, $Subtitle, $Column) $kql.Counts + "`n| project Title = '$Title', Subtitle = '$Subtitle', Count = $Column" }

    $timelineQuery = $kql.Timeline + "`n| project TimeGenerated, Running, Healthy, Unhealthy, Starting"

    $unhealthyQuery = $kql.State + @'

state
| where Health == 'Unhealthy'
| project VM, Health, Detail, ResourceGroup
| order by VM asc
'@

    $detailQuery = $kql.State + @'

state
| extend Order = case(Health == 'Unhealthy', 0, Health == 'Starting', 1, Health == 'Healthy', 2, 3)
| order by Order asc, VM asc
| project Health, VM, Power, ResourceGroup, Size, LastBoot, UptimeMin, LastHeartbeat, MinutesSince, Detail
'@

    $laCommon = @{
        version                 = 'KqlItem/1.0'
        queryType               = 0
        resourceType            = 'microsoft.operationalinsights/workspaces'
        crossComponentResources = @($WorkspaceResourceId)
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
            content = @{ json = "## AMA Heartbeat Health`nA running VM is **unhealthy** when it has been up longer than the startup grace period (last start from Resource Health) and the Azure Monitor Agent has not sent a heartbeat within the threshold. Freshly started VMs are shown as **Starting**; stopped/deallocated VMs are ignored.`n`n_Source: Azure Resource Graph (power state, Resource Health start/stop events) via ``arg()`` + Log Analytics ``Heartbeat`` table - no additional data is collected. Deployed by AzLabBuilder._" }
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
                    @{ id = (& $paramId 'p1'); version = 'KqlParameterItem/1.0'; name = 'ThresholdMin'; label = 'Heartbeat threshold (min)'; type = 1; isRequired = $true; value = "$ThresholdMinutes" }
                    @{ id = (& $paramId 'p3'); version = 'KqlParameterItem/1.0'; name = 'StartupGraceMin'; label = 'Startup grace (min)'; type = 1; isRequired = $true; value = "$StartupGraceMinutes" }
                    @{ id = (& $paramId 'p2'); version = 'KqlParameterItem/1.0'; name = 'ResourceGroup'; label = 'Resource group (* = all)'; type = 1; isRequired = $true; value = $ResourceGroupName }
                    @{
                        id = (& $paramId 'p4'); version = 'KqlParameterItem/1.0'; name = 'TimeRange'; label = 'Chart time range'; type = 4; isRequired = $true
                        value        = @{ durationMs = 86400000 }
                        typeSettings = @{
                            selectableValues = @(
                                @{ durationMs = 3600000 }, @{ durationMs = 14400000 }, @{ durationMs = 43200000 },
                                @{ durationMs = 86400000 }, @{ durationMs = 259200000 }, @{ durationMs = 604800000 }, @{ durationMs = 1209600000 }
                            )
                            allowCustom      = $false
                        }
                    }
                )
            }
        }
        (& $countTile 'running-count' 'Running' 'VMs in running state' 'Running' 'blue')
        (& $countTile 'healthy-count' 'Healthy' 'AMA heartbeat within {ThresholdMin} min' 'Healthy' 'green')
        (& $countTile 'unhealthy-count' 'Unhealthy' 'up > {StartupGraceMin} min, no heartbeat > {ThresholdMin} min' 'Unhealthy' 'redBright')
        (& $countTile 'starting-count' 'Starting' 'started < {StartupGraceMin} min ago' 'Starting' 'gray')
        (& $countTile 'deallocated-count' 'Deallocated' 'VMs currently deallocated' 'Deallocated' 'purple')
        @{
            type    = 3
            name    = 'health-timeline'
            content = @{
                version                 = 'KqlItem/1.0'
                title                   = 'Healthy vs. unhealthy out of running VMs ({ThresholdMin} min buckets)'
                query                   = $timelineQuery
                size                    = 0
                queryType               = 0
                resourceType            = 'microsoft.operationalinsights/workspaces'
                crossComponentResources = @($WorkspaceResourceId)
                timeContextFromParameter = 'TimeRange'
                visualization           = 'linechart'
                chartSettings           = @{
                    seriesLabelSettings = @(
                        @{ seriesName = 'Running'; label = 'Running'; color = 'blue' }
                        @{ seriesName = 'Healthy'; label = 'Healthy'; color = 'green' }
                        @{ seriesName = 'Unhealthy'; label = 'Unhealthy'; color = 'redBright' }
                        @{ seriesName = 'Starting'; label = 'Starting (grace)'; color = 'gray' }
                    )
                }
            }
        }
        @{
            type    = 3
            name    = 'unhealthy-vms'
            content = $laCommon + @{
                title              = 'Unhealthy VMs - up > {StartupGraceMin} min, no AMA heartbeat for more than {ThresholdMin} min'
                query              = $unhealthyQuery
                size               = 0
                visualization      = 'tiles'
                noDataMessage      = 'All running VMs (past startup grace) sent an AMA heartbeat within the threshold.'
                noDataMessageStyle = 3
                tileSettings       = @{
                    titleContent     = @{ columnMatch = 'VM'; formatter = 1 }
                    leftContent      = @{ columnMatch = 'Health'; formatter = 18; formatOptions = @{ thresholdsOptions = 'icons'; thresholdsGrid = @(@{ operator = 'Default'; thresholdValue = $null; representation = '4'; text = '' }) } }
                    subtitleContent  = @{ columnMatch = 'Detail' }
                    secondaryContent = @{ columnMatch = 'ResourceGroup' }
                    showBorder       = $true
                    size             = 'auto'
                }
            }
        }
        @{
            type    = 3
            name    = 'vm-details'
            content = $laCommon + @{
                title         = 'All VMs - power state, last start and last AMA heartbeat'
                query         = $detailQuery
                size          = 0
                visualization = 'table'
                gridSettings  = @{
                    formatters = @(
                        $healthIcon
                        @{ columnMatch = 'UptimeMin'; formatter = 0; numberFormat = @{ unit = 0; options = @{ style = 'decimal'; maximumFractionDigits = 1 } } }
                        @{ columnMatch = 'MinutesSince'; formatter = 0; numberFormat = @{ unit = 0; options = @{ style = 'decimal'; maximumFractionDigits = 1 } } }
                    )
                    labelSettings = @(
                        @{ columnId = 'UptimeMin'; label = 'Up (min)' }
                        @{ columnId = 'MinutesSince'; label = 'Heartbeat age (min)' }
                    )
                }
            }
        }
    )

    $workbook = [ordered]@{
        version             = 'Notebook/1.0'
        items               = $items
        fallbackResourceIds = @($WorkspaceResourceId)
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
    $sku = Select-LabCheapestVmSku -Location $location -VmCount $vmCount -MinMemoryGB 1

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
    $q = (Get-AmaHeartbeatKql -SubscriptionId $subId).State + "`nstate`n| order by VM asc"
    $q = $q.Replace('{ThresholdMin}', "$ThresholdMinutes").Replace('{StartupGraceMin}', "$StartupGraceMinutes").Replace('{ResourceGroup}', $ResourceGroupName)
    $res = Invoke-AzOperationalInsightsQuery -WorkspaceId $ws.CustomerId -Query $q -ErrorAction Stop
    if ($res.Error) { throw "Health query failed: $($res.Error.Message)" }
    foreach ($r in $res.Results) {
        [pscustomobject]@{
            VM            = $r.VM
            PowerState    = $r.Power
            Health        = $r.Health
            UpMin         = if ($r.UptimeMin) { $r.UptimeMin } else { '-' }
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
        Write-Host ('   Starting    : {0}  (started < {1} min ago)' -f (& $count 'Starting'), $grace) -ForegroundColor Gray
        Write-Host ('   Deallocated : {0}' -f (& $count 'Deallocated')) -ForegroundColor DarkGray
        Write-Host ''
        Write-LabTable -Rows $rows -Columns @('VM', 'PowerState', 'Health', 'UpMin', 'LastHeartbeat', 'MinutesAgo') -ColorSelector {
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
