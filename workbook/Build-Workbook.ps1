<#
.SYNOPSIS
    Generates the standalone AMA Heartbeat workbook files from the AzLabBuilder workbook builder.
.DESCRIPTION
    Output (next to this script):
      azuredeploy.json          ARM template - deploys only the workbook, bound to an existing Log Analytics workspace
      createUiDefinition.json   Portal UI with a workspace picker (used by the Deploy to Azure button)
      workbook.json             Gallery template - paste into Workbooks > New > Advanced Editor
    Re-run after changing the KQL or the workbook layout in scenarios\AmaHeartbeat\AmaHeartbeat.ps1.
#>
[CmdletBinding()]
param([int]$ThresholdMinutes = 10, [int]$StartupGraceMinutes = 10)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\scenarios\AmaHeartbeat\AmaHeartbeat.ps1')

$token = '__WORKSPACE_ID__'
$common = @{ SubscriptionId = '*'; ResourceGroupName = '*'; ThresholdMinutes = $ThresholdMinutes; StartupGraceMinutes = $StartupGraceMinutes }

# Gallery template: no workspace preset, the user picks one in the Workspace parameter
$gallery = New-AmaHeartbeatWorkbookJson @common | ConvertFrom-Json | ConvertTo-Json -Depth 40
Set-Content -Path (Join-Path $PSScriptRoot 'workbook.json') -Value $gallery -Encoding utf8

# ARM template: workspace id is injected at deployment time via replace()
$serialized = New-AmaHeartbeatWorkbookJson @common -WorkspaceResourceId $token
$template = [ordered]@{
    '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'
    contentVersion = '1.0.0.0'
    metadata       = @{ description = 'AMA Heartbeat Health workbook - running VMs vs. Azure Monitor Agent heartbeats (Heartbeat table + Azure Resource Graph, no extra data collection).' }
    parameters     = [ordered]@{
        workspaceResourceId = @{ type = 'string'; metadata = @{ description = 'Resource ID of the existing Log Analytics workspace that receives the AMA Heartbeat data.' } }
        workbookDisplayName = @{ type = 'string'; defaultValue = 'AMA Heartbeat Health'; metadata = @{ description = 'Display name of the workbook.' } }
        location            = @{ type = 'string'; defaultValue = '[resourceGroup().location]'; metadata = @{ description = 'Location of the workbook resource.' } }
    }
    variables      = @{ serializedData = $serialized }
    resources      = @(
        [ordered]@{
            type       = 'Microsoft.Insights/workbooks'
            apiVersion = '2022-04-01'
            name       = "[guid(resourceGroup().id, parameters('workbookDisplayName'))]"
            location   = "[parameters('location')]"
            kind       = 'shared'
            properties = [ordered]@{
                displayName    = "[parameters('workbookDisplayName')]"
                category       = 'workbook'
                sourceId       = "[toLower(parameters('workspaceResourceId'))]"
                serializedData = "[replace(variables('serializedData'), '$token', parameters('workspaceResourceId'))]"
            }
        }
    )
    outputs        = @{ workbookId = @{ type = 'string'; value = "[resourceId('Microsoft.Insights/workbooks', guid(resourceGroup().id, parameters('workbookDisplayName')))]" } }
}
Set-Content -Path (Join-Path $PSScriptRoot 'azuredeploy.json') -Value ($template | ConvertTo-Json -Depth 20) -Encoding utf8

# Portal UI: workspace picker across all subscriptions
$ui = [ordered]@{
    '$schema'  = 'https://schema.management.azure.com/schemas/0.1.2-preview/CreateUIDefinition.MultiVm.json#'
    handler    = 'Microsoft.Azure.CreateUIDef'
    version    = '0.1.2-preview'
    parameters = [ordered]@{
        basics  = @(
            [ordered]@{
                name         = 'workspace'
                type         = 'Microsoft.Solutions.ResourceSelector'
                label        = 'Log Analytics workspace'
                toolTip      = 'Workspace that receives the Azure Monitor Agent Heartbeat data of your VMs.'
                resourceType = 'Microsoft.OperationalInsights/workspaces'
                options      = @{ filter = @{ subscription = 'all'; location = 'all' } }
            }
            [ordered]@{
                name         = 'workbookName'
                type         = 'Microsoft.Common.TextBox'
                label        = 'Workbook name'
                defaultValue = 'AMA Heartbeat Health'
                constraints  = @{ required = $true }
            }
            [ordered]@{
                name    = 'info'
                type    = 'Microsoft.Common.InfoBox'
                options = @{ icon = 'Info'; text = 'Only the workbook is deployed. It reads the existing Heartbeat table and Azure Resource Graph - no data collection is changed.' }
            }
        )
        steps   = @()
        outputs = [ordered]@{
            workspaceResourceId = "[basics('workspace').id]"
            workbookDisplayName = "[basics('workbookName')]"
            location            = '[location()]'
        }
    }
}
Set-Content -Path (Join-Path $PSScriptRoot 'createUiDefinition.json') -Value ($ui | ConvertTo-Json -Depth 20) -Encoding utf8
Write-Host "Generated azuredeploy.json, createUiDefinition.json and workbook.json in $PSScriptRoot"
