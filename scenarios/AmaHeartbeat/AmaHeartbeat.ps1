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

function New-AmaHeartbeatWorkbookJson {
    # Builds the serialized Azure Monitor workbook (dashboard)
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$WorkspaceResourceId,
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [int]$ThresholdMinutes = 10
    )

    # Native Azure Resource Graph query: count of running VMs
    $argRunning = @'
resources
| where type =~ 'microsoft.compute/virtualmachines'
| where '{ResourceGroup}' == '*' or resourceGroup =~ '{ResourceGroup}'
| extend PowerState = tostring(properties.extended.instanceView.powerState.code)
| extend IsRunning = iff(PowerState =~ 'PowerState/running', 1, 0)
| summarize Running = sum(IsRunning), Total = count()
| extend Title = 'VMs in running state', Subtitle = strcat('of ', Total, ' VMs in scope')
'@

    # Log Analytics query: running VMs (via arg("")) joined with the latest AMA heartbeat
    $base = @'
let threshold = {ThresholdMin}m;
let runningVms = arg("").Resources
    | where type =~ 'microsoft.compute/virtualmachines'
    | where subscriptionId == '__SUBSCRIPTION_ID__'
    | where '{ResourceGroup}' == '*' or resourceGroup =~ '{ResourceGroup}'
    | where tostring(properties.extended.instanceView.powerState.code) =~ 'PowerState/running'
    | project VmId = tolower(id), VM = name, ResourceGroup = resourceGroup, Size = tostring(properties.hardwareProfile.vmSize);
let lastHb = Heartbeat
    | where TimeGenerated > ago(1d)
    | where Category == 'Azure Monitor Agent'
    | summarize LastHeartbeat = max(TimeGenerated) by VmId = tolower(_ResourceId);
runningVms
| join kind=leftouter lastHb on VmId
| extend MinutesSince = iff(isnull(LastHeartbeat), real(null), round((now() - LastHeartbeat) / 1m, 1))
| extend Health = iff(isnull(LastHeartbeat) or LastHeartbeat < ago(threshold), 'Unhealthy', 'Healthy')
| extend Detail = iff(isnull(LastHeartbeat), 'No AMA heartbeat in the last 24h', strcat('Last heartbeat ', tostring(MinutesSince), ' min ago'))
'@
    $base = $base.Replace('__SUBSCRIPTION_ID__', $SubscriptionId)

    # mv-expand is not supported with arg() cross-service queries -> one single-row query per tile
    $countQuery = $base + @'

| extend U = iff(Health == 'Unhealthy', 1, 0)
| summarize Running = count(), Unhealthy = sum(U)
| extend Unhealthy = coalesce(Unhealthy, 0)
| extend Healthy = Running - Unhealthy
'@
    $healthyQuery = $countQuery + "`n| project Title = 'Healthy', Subtitle = 'AMA heartbeat within {ThresholdMin} min', Count = Healthy"
    $unhealthyCountQuery = $countQuery + "`n| project Title = 'Unhealthy', Subtitle = 'running, no AMA heartbeat > {ThresholdMin} min', Count = Unhealthy"

    $unhealthyQuery = $base + @'

| where Health == 'Unhealthy'
| project VM, Health, Detail, ResourceGroup
| order by VM asc
'@

    $detailQuery = $base + @'

| project Health, VM, ResourceGroup, Size, LastHeartbeat, MinutesSince
| order by Health desc, VM asc
'@

    $laCommon = @{
        version                 = 'KqlItem/1.0'
        queryType               = 0
        resourceType            = 'microsoft.operationalinsights/workspaces'
        crossComponentResources = @($WorkspaceResourceId)
        timeContext             = @{ durationMs = 86400000 }
    }
    $healthIcon = @{
        columnMatch   = 'Health'
        formatter     = 18
        formatOptions = @{
            thresholdsOptions = 'icons'
            thresholdsGrid    = @(
                @{ operator = '=='; thresholdValue = 'Unhealthy'; representation = '4'; text = '{0}{1}' }
                @{ operator = 'Default'; thresholdValue = $null; representation = 'success'; text = '{0}{1}' }
            )
        }
    }

    $items = @(
        @{
            type    = 1
            name    = 'header'
            content = @{ json = "## AMA Heartbeat Health`nRunning VMs are **unhealthy** when the Azure Monitor Agent has not sent a heartbeat for more than the threshold. Stopped/deallocated VMs are ignored.`n`n_Source: Azure Resource Graph (power state) + Log Analytics ``Heartbeat`` table. Deployed by AzLabBuilder._" }
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
                    @{ id = (Get-LabDeterministicGuid "$ResourceGroupName-p1"); version = 'KqlParameterItem/1.0'; name = 'ThresholdMin'; label = 'Heartbeat threshold (min)'; type = 1; isRequired = $true; value = "$ThresholdMinutes" }
                    @{ id = (Get-LabDeterministicGuid "$ResourceGroupName-p2"); version = 'KqlParameterItem/1.0'; name = 'ResourceGroup'; label = 'Resource group (* = all)'; type = 1; isRequired = $true; value = $ResourceGroupName }
                )
            }
        }
        @{
            type        = 3
            name        = 'running-vms'
            customWidth = '34'
            content     = @{
                version                 = 'KqlItem/1.0'
                title                   = 'Overall VMs in running state'
                query                   = $argRunning
                size                    = 4
                queryType               = 1
                resourceType            = 'microsoft.resourcegraph/resources'
                crossComponentResources = @("/subscriptions/$SubscriptionId")
                visualization           = 'tiles'
                tileSettings            = (New-CountTile -CountColumn 'Running' -Palette 'blue')
            }
        }
        @{
            type        = 3
            name        = 'healthy-count'
            customWidth = '33'
            content     = $laCommon + @{
                title         = 'Healthy running VMs'
                query         = $healthyQuery
                size          = 4
                visualization = 'tiles'
                tileSettings  = (New-CountTile -CountColumn 'Count' -Palette 'green')
            }
        }
        @{
            type        = 3
            name        = 'unhealthy-count'
            customWidth = '33'
            content     = $laCommon + @{
                title         = 'Unhealthy running VMs'
                query         = $unhealthyCountQuery
                size          = 4
                visualization = 'tiles'
                tileSettings  = (New-CountTile -CountColumn 'Count' -Palette 'redBright')
            }
        }
        @{
            type    = 3
            name    = 'unhealthy-vms'
            content = $laCommon + @{
                title              = 'Unhealthy VMs - running, no AMA heartbeat for more than {ThresholdMin} min'
                query              = $unhealthyQuery
                size               = 0
                visualization      = 'tiles'
                noDataMessage      = 'All running VMs sent an AMA heartbeat within the threshold.'
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
                title         = 'All running VMs and their last AMA heartbeat'
                query         = $detailQuery
                size          = 0
                visualization = 'table'
                gridSettings  = @{
                    formatters = @(
                        $healthIcon
                        @{ columnMatch = 'MinutesSince'; formatter = 0; numberFormat = @{ unit = 0; options = @{ style = 'decimal'; maximumFractionDigits = 1 } } }
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
    Write-Host ('   Dashboard      : Workbook "AzLabBuilder - AMA Heartbeat Health" (threshold {0} min)' -f $threshold)
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
    Write-LabStatus -Level Info -Message 'First AMA heartbeats arrive ~5-10 minutes after the agent install; until then VMs show as unhealthy.'
    Write-LabStatus -Level Info -Message 'VM admin user: labadmin (no public IP; use Serial Console / Bastion if needed).'
    if (Read-LabConfirm -Prompt 'Show the generated VM admin password once?') { Write-Host "  $password" -ForegroundColor Yellow }
    if (Read-LabConfirm -Prompt 'Open the dashboard in the browser?' -Default $true) { Start-Process $url }
}

function Get-AmaHeartbeatHealth {
    # Local health evaluation: VM power state (ARM) + last AMA heartbeat (Log Analytics)
    param([Parameter(Mandatory)][string]$ResourceGroupName, [int]$ThresholdMinutes = 10)
    $vms = @(Get-AzVM -ResourceGroupName $ResourceGroupName -Status -ErrorAction Stop)
    $ws = Get-AzOperationalInsightsWorkspace -ResourceGroupName $ResourceGroupName -ErrorAction Stop | Select-Object -First 1
    $hb = @{}
    if ($ws) {
        $q = "Heartbeat | where TimeGenerated > ago(1d) | where Category == 'Azure Monitor Agent' | summarize LastHeartbeat = max(TimeGenerated) by VmId = tolower(_ResourceId)"
        $res = Invoke-AzOperationalInsightsQuery -WorkspaceId $ws.CustomerId -Query $q -ErrorAction Stop
        foreach ($r in $res.Results) {
            $hb[$r.VmId] = [datetime]::Parse($r.LastHeartbeat, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal)
        }
    }
    $now = (Get-Date).ToUniversalTime()
    foreach ($vm in $vms | Sort-Object Name) {
        $running = $vm.PowerState -eq 'VM running'
        $last = $hb[$vm.Id.ToLowerInvariant()]
        $mins = if ($last) { [Math]::Round(($now - $last).TotalMinutes, 1) } else { $null }
        $health = if (-not $running) { 'n/a' } elseif ($null -eq $mins -or $mins -gt $ThresholdMinutes) { 'Unhealthy' } else { 'Healthy' }
        [pscustomobject]@{
            VM            = $vm.Name
            PowerState    = ($vm.PowerState -replace '^VM ', '')
            Health        = $health
            LastHeartbeat = if ($last) { $last.ToString('yyyy-MM-dd HH:mm:ss') + 'Z' } else { '-' }
            MinutesAgo    = if ($null -ne $mins) { $mins } else { '-' }
        }
    }
}

function Show-AmaHeartbeatHealth {
    $rg = Select-AmaHeartbeatLab
    if (-not $rg) { return }
    $threshold = [int](Read-LabValue -Prompt 'Heartbeat threshold (minutes)' -Default '10' -Pattern '^\d{1,3}$' -PatternHint 'Minutes.')
    $watch = Read-LabConfirm -Prompt 'Watch mode (refresh every 60s, Q to stop)?'
    do {
        Write-LabBanner
        Write-LabSection -Title ("Health of '{0}' - {1:HH:mm:ss}" -f $rg, (Get-Date))
        try {
            $rows = @(Get-AmaHeartbeatHealth -ResourceGroupName $rg -ThresholdMinutes $threshold)
        } catch {
            Write-LabStatus -Level Error -Message $_.Exception.Message; break
        }
        if ($rows.Count -eq 0) { Write-LabStatus -Level Warn -Message 'No VMs found.'; break }
        $running = @($rows | Where-Object PowerState -eq 'running')
        $unhealthy = @($rows | Where-Object Health -eq 'Unhealthy')
        Write-Host ('   VMs running : {0} / {1}' -f $running.Count, $rows.Count) -ForegroundColor Cyan
        Write-Host ('   Healthy     : {0}' -f ($running.Count - $unhealthy.Count)) -ForegroundColor Green
        Write-Host ('   Unhealthy   : {0}' -f $unhealthy.Count) -ForegroundColor $(if ($unhealthy.Count) { 'Red' } else { 'Green' })
        Write-Host ''
        Write-LabTable -Rows $rows -Columns @('VM', 'PowerState', 'Health', 'LastHeartbeat', 'MinutesAgo') -ColorSelector {
            param($r) switch ($r.Health) { 'Unhealthy' { 'Red' } 'Healthy' { 'Green' } default { 'DarkGray' } }
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
