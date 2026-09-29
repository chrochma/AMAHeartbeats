# AzLabBuilder - module check and Azure authentication

$script:LabRequiredModules = @('Az.Accounts', 'Az.Resources', 'Az.Compute', 'Az.OperationalInsights')

function Test-LabModules {
    # Ensures the required Az modules are available, offers installation otherwise
    $missing = $script:LabRequiredModules | Where-Object { -not (Get-Module -ListAvailable -Name $_) }
    if (-not $missing) {
        foreach ($m in $script:LabRequiredModules) { Import-Module $m -ErrorAction Stop -WarningAction SilentlyContinue }
        Write-LabStatus -Level Ok -Message 'Az PowerShell modules available.'
        return $true
    }
    Write-LabStatus -Level Warn -Message ('Missing modules: {0}' -f ($missing -join ', '))
    if (-not (Read-LabConfirm -Prompt 'Install missing modules for the current user now?' -Default $true)) { return $false }
    foreach ($m in $missing) {
        Write-LabStatus -Level Step -Message "Installing $m ..."
        Install-Module -Name $m -Scope CurrentUser -Repository PSGallery -Force -AllowClobber -ErrorAction Stop
    }
    foreach ($m in $script:LabRequiredModules) { Import-Module $m -ErrorAction Stop -WarningAction SilentlyContinue }
    return $true
}

function Test-LabAzContext {
    # Returns the context only if it exists AND the token still works against ARM
    $ctx = Get-AzContext -ErrorAction SilentlyContinue
    if (-not $ctx -or -not $ctx.Account) { return $null }
    try {
        if ($ctx.Subscription) {
            Get-AzSubscription -SubscriptionId $ctx.Subscription.Id -TenantId $ctx.Tenant.Id -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null
        } else {
            Get-AzSubscription -TenantId $ctx.Tenant.Id -ErrorAction Stop -WarningAction SilentlyContinue | Select-Object -First 1 | Out-Null
        }
        return $ctx
    } catch {
        Write-LabStatus -Level Warn -Message ('Cached context is not usable: {0}' -f $_.Exception.Message)
        return $null
    }
}

function Connect-LabAzure {
    param([switch]$UseDeviceAuthentication, [string]$TenantId)
    $params = @{ ErrorAction = 'Stop'; WarningAction = 'SilentlyContinue' }
    if ($UseDeviceAuthentication) { $params.UseDeviceAuthentication = $true }
    if ($TenantId) { $params.TenantId = $TenantId }
    Write-LabStatus -Level Step -Message 'Signing in to Azure ...'
    Connect-AzAccount @params | Out-Null
    Write-LabStatus -Level Ok -Message ('Signed in as {0}' -f (Get-AzContext).Account.Id)
}

function Select-LabSubscription {
    # Lets the user pick a subscription from the signed-in tenant(s)
    $subs = @(Get-AzSubscription -WarningAction SilentlyContinue -ErrorAction Stop | Where-Object State -eq 'Enabled' | Sort-Object Name)
    if ($subs.Count -eq 0) { throw 'No enabled subscriptions found for this account.' }
    $current = (Get-AzContext).Subscription.Id
    Write-LabSection -Title 'Subscriptions'
    for ($i = 0; $i -lt $subs.Count; $i++) {
        $mark = if ($subs[$i].Id -eq $current) { '*' } else { ' ' }
        Write-Host ('   [{0,2}]{1} {2}  ({3})' -f ($i + 1), $mark, $subs[$i].Name, $subs[$i].Id)
    }
    $defaultIdx = [Math]::Max(1, ([array]::IndexOf(@($subs.Id), $current) + 1))
    $pick = Read-LabValue -Prompt 'Subscription number' -Default "$defaultIdx" -Pattern '^\d+$' -PatternHint 'Enter a number.'
    $idx = [int]$pick - 1
    if ($idx -lt 0 -or $idx -ge $subs.Count) { Write-LabStatus -Level Warn -Message 'Out of range, keeping current.'; return }
    Set-AzContext -SubscriptionId $subs[$idx].Id -TenantId $subs[$idx].TenantId -WarningAction SilentlyContinue | Out-Null
    Write-LabStatus -Level Ok -Message ('Using subscription {0}' -f $subs[$idx].Name)
}

function Initialize-LabAuthentication {
    # Validates an existing context and asks: keep / re-authenticate, or signs in first
    param([switch]$UseDeviceAuthentication)
    Write-LabSection -Title 'Authentication'
    $ctx = Test-LabAzContext
    if ($ctx) {
        Write-LabStatus -Level Ok -Message 'Existing Azure authentication context found:'
        Write-Host ('      Account      : {0}' -f $ctx.Account.Id)
        Write-Host ('      Tenant       : {0}' -f $ctx.Tenant.Id)
        Write-Host ('      Subscription : {0} ({1})' -f $ctx.Subscription.Name, $ctx.Subscription.Id)
        $menu = [ordered]@{ '1' = 'Continue with this context'; '2' = 'Re-authenticate'; '3' = 'Switch subscription' }
        switch (Show-LabMenu -Title 'Use this context?' -Items $menu) {
            '1' { }
            '2' {
                Disconnect-AzAccount -ErrorAction SilentlyContinue | Out-Null
                Connect-LabAzure -UseDeviceAuthentication:$UseDeviceAuthentication
                Select-LabSubscription
            }
            '3' { Select-LabSubscription }
        }
    } else {
        Write-LabStatus -Level Warn -Message 'No valid Azure authentication context. Please authenticate first.'
        if (-not (Read-LabConfirm -Prompt 'Sign in now?' -Default $true)) { return $false }
        $tenant = Read-Host '  Tenant ID or domain (Enter = home tenant)'
        Connect-LabAzure -UseDeviceAuthentication:$UseDeviceAuthentication -TenantId $tenant.Trim()
        Select-LabSubscription
    }
    return [bool](Test-LabAzContext)
}
