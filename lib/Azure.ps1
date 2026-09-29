# AzLabBuilder - shared Azure helpers (SKU selection, quota, providers, secrets)

function Get-LabSkuCapability {
    param($Sku, [string]$Name)
    $cap = $Sku.Capabilities | Where-Object Name -eq $Name | Select-Object -First 1
    if ($cap) { return $cap.Value }
    return $null
}

function Get-LabVmSkuCandidates {
    # Returns unrestricted, x64, Gen2 capable SKUs in the region matching the size limits
    param(
        [Parameter(Mandatory)][string]$Location,
        [double]$MinMemoryGB = 1,
        [double]$MaxMemoryGB = 4,
        [int]$MaxVCpus = 2
    )
    $skus = Get-AzComputeResourceSku -Location $Location -ErrorAction Stop |
        Where-Object { $_.ResourceType -eq 'virtualMachines' -and $_.Name -like 'Standard_*' }

    foreach ($sku in $skus) {
        # Skip SKUs blocked for this subscription in the region
        $blocked = $sku.Restrictions | Where-Object { $_.Type -eq 'Location' -and $_.ReasonCode -eq 'NotAvailableForSubscription' }
        if ($blocked) { continue }
        $vcpu = [int](Get-LabSkuCapability $sku 'vCPUs')
        $mem = [double](Get-LabSkuCapability $sku 'MemoryGB')
        $arch = Get-LabSkuCapability $sku 'CpuArchitectureType'
        $gens = Get-LabSkuCapability $sku 'HyperVGenerations'
        $cvm = Get-LabSkuCapability $sku 'ConfidentialComputingType'
        if ($vcpu -lt 1 -or $vcpu -gt $MaxVCpus) { continue }
        if ($mem -lt $MinMemoryGB -or $mem -gt $MaxMemoryGB) { continue }
        if ($arch -and $arch -ne 'x64') { continue }
        if ($gens -notmatch 'V2') { continue }
        if ($cvm) { continue }
        [pscustomobject]@{ Name = $sku.Name; Family = $sku.Family; vCPUs = $vcpu; MemoryGB = $mem; HourlyUSD = $null }
    }
}

function Get-LabRetailPrices {
    # Linux pay-as-you-go hourly prices from the public Azure Retail Prices API (no auth needed)
    param([Parameter(Mandatory)][string]$Location, [Parameter(Mandatory)][string[]]$SkuNames)
    $prices = @{}
    # Keep the OData filter short by chunking the SKU list
    for ($i = 0; $i -lt $SkuNames.Count; $i += 15) {
        $chunk = $SkuNames[$i..([Math]::Min($i + 14, $SkuNames.Count - 1))]
        $skuFilter = ($chunk | ForEach-Object { "armSkuName eq '$_'" }) -join ' or '
        $filter = "serviceName eq 'Virtual Machines' and armRegionName eq '$Location' and priceType eq 'Consumption' and ($skuFilter)"
        $uri = 'https://prices.azure.com/api/retail/prices?$filter=' + [uri]::EscapeDataString($filter)
        while ($uri) {
            $resp = Invoke-RestMethod -Uri $uri -Method Get -ErrorAction Stop
            foreach ($item in $resp.Items) {
                if ($item.productName -match 'Windows' -or $item.skuName -match 'Spot|Low Priority') { continue }
                if ($item.unitOfMeasure -ne '1 Hour') { continue }
                if (-not $prices.ContainsKey($item.armSkuName) -or $item.retailPrice -lt $prices[$item.armSkuName]) {
                    $prices[$item.armSkuName] = [double]$item.retailPrice
                }
            }
            $uri = $resp.NextPageLink
        }
    }
    return $prices
}

function Test-LabVmQuota {
    # Checks family and regional vCPU quota for the requested number of VMs
    param([Parameter(Mandatory)][string]$Location, [Parameter(Mandatory)]$Sku, [int]$VmCount, $Usage)
    if (-not $Usage) { $Usage = Get-AzVMUsage -Location $Location -ErrorAction Stop }
    $need = $Sku.vCPUs * $VmCount
    $family = $Usage | Where-Object { $_.Name.Value -eq $Sku.Family } | Select-Object -First 1
    $regional = $Usage | Where-Object { $_.Name.Value -eq 'cores' } | Select-Object -First 1
    $famFree = if ($family) { $family.Limit - $family.CurrentValue } else { 0 }
    $regFree = if ($regional) { $regional.Limit - $regional.CurrentValue } else { [int]::MaxValue }
    [pscustomobject]@{
        Ok             = ($famFree -ge $need -and $regFree -ge $need)
        Needed         = $need
        FamilyFree     = $famFree
        RegionalFree   = $regFree
    }
}

function Select-LabCheapestVmSku {
    # Finds the cheapest usable SKU (price + availability + quota) and lets the user confirm
    param([Parameter(Mandatory)][string]$Location, [int]$VmCount = 10, [double]$MinMemoryGB = 1)

    Write-LabStatus -Level Step -Message "Discovering VM SKUs available in $Location ..."
    $candidates = @(Get-LabVmSkuCandidates -Location $Location -MinMemoryGB $MinMemoryGB)
    if ($candidates.Count -eq 0) { throw "No suitable VM SKUs available for this subscription in $Location." }

    Write-LabStatus -Level Step -Message ('Fetching Linux retail prices for {0} candidate SKUs ...' -f $candidates.Count)
    try {
        $prices = Get-LabRetailPrices -Location $Location -SkuNames $candidates.Name
        foreach ($c in $candidates) { if ($prices.ContainsKey($c.Name)) { $c.HourlyUSD = $prices[$c.Name] } }
    } catch {
        Write-LabStatus -Level Warn -Message ('Retail Prices API unavailable ({0}). Falling back to size ordering.' -f $_.Exception.Message)
    }

    $usage = Get-AzVMUsage -Location $Location -ErrorAction Stop
    $ranked = $candidates |
        Sort-Object @{ Expression = { if ($null -eq $_.HourlyUSD) { [double]::MaxValue } else { $_.HourlyUSD } } }, vCPUs, MemoryGB |
        ForEach-Object {
            $q = Test-LabVmQuota -Location $Location -Sku $_ -VmCount $VmCount -Usage $usage
            $_ | Add-Member -NotePropertyName QuotaOk -NotePropertyValue $q.Ok -PassThru |
                 Add-Member -NotePropertyName FamilyFree -NotePropertyValue $q.FamilyFree -PassThru
        }
    $usable = @($ranked | Where-Object QuotaOk)
    if ($usable.Count -eq 0) {
        throw ("No candidate SKU has enough vCPU quota for {0} VMs in {1}. Request quota first (e.g. AzQuotaRequester)." -f $VmCount, $Location)
    }

    $top = @($usable | Select-Object -First 5)
    $rows = for ($i = 0; $i -lt $top.Count; $i++) {
        $price = if ($null -ne $top[$i].HourlyUSD) { '{0:N4}' -f $top[$i].HourlyUSD } else { 'n/a' }
        $month = if ($null -ne $top[$i].HourlyUSD) { '{0:N2}' -f ($top[$i].HourlyUSD * 730 * $VmCount) } else { 'n/a' }
        [pscustomobject]@{ '#' = $i + 1; SKU = $top[$i].Name; vCPU = $top[$i].vCPUs; RAM_GB = $top[$i].MemoryGB; 'USD/h' = $price; "USD/month x$VmCount" = $month; FreeFamilyCores = $top[$i].FamilyFree }
    }
    Write-LabSection -Title 'Cheapest usable SKUs (Linux PAYG, compute only)'
    Write-LabTable -Rows $rows -Columns @('#', 'SKU', 'vCPU', 'RAM_GB', 'USD/h', "USD/month x$VmCount", 'FreeFamilyCores') -ColorSelector { param($r) if ($r.'#' -eq 1) { 'Green' } else { 'Gray' } }
    $pick = Read-LabValue -Prompt 'Pick SKU' -Default '1' -Pattern ('^[1-{0}]$' -f $top.Count) -PatternHint "Enter 1-$($top.Count)."
    return $top[[int]$pick - 1]
}

function Register-LabResourceProviders {
    param([string[]]$Namespaces)
    foreach ($ns in $Namespaces) {
        $state = (Get-AzResourceProvider -ProviderNamespace $ns -ErrorAction Stop | Select-Object -First 1).RegistrationState
        if ($state -eq 'Registered') { continue }
        Write-LabStatus -Level Step -Message "Registering resource provider $ns ..."
        Register-AzResourceProvider -ProviderNamespace $ns -ErrorAction Stop | Out-Null
        $deadline = (Get-Date).AddMinutes(5)
        do {
            Start-Sleep -Seconds 5
            $state = (Get-AzResourceProvider -ProviderNamespace $ns | Select-Object -First 1).RegistrationState
        } while ($state -ne 'Registered' -and (Get-Date) -lt $deadline)
        if ($state -ne 'Registered') { Write-LabStatus -Level Warn -Message "$ns is still '$state' - deployment may fail." }
    }
}

function New-LabPassword {
    # Random password meeting Azure VM complexity rules
    param([int]$Length = 24)
    $sets = @('ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnpqrstuvwxyz', '23456789', '!@#%^*-_=+')
    $all = -join $sets
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $bytes = New-Object byte[] ($Length)
    $rng.GetBytes($bytes)
    $chars = for ($i = 0; $i -lt $Length; $i++) { $all[$bytes[$i] % $all.Length] }
    # Guarantee one character of each class
    for ($i = 0; $i -lt $sets.Count; $i++) { $chars[$i] = $sets[$i][$bytes[$i] % $sets[$i].Length] }
    $rng.Dispose()
    return (-join $chars)
}
