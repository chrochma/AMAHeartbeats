# AzLabBuilder - console UI helpers (PowerShell 5.1 / 7 compatible, ASCII only)

$script:LabWidth = 78

function Write-LabBanner {
    try { Clear-Host } catch { }
    $line = '=' * $script:LabWidth
    Write-Host $line -ForegroundColor DarkCyan
    Write-Host '     _        _          _     ____        _ _     _           ' -ForegroundColor Cyan
    Write-Host '    / \   ___| |    __ _| |__ | __ ) _   _(_) | __| | ___ _ __ ' -ForegroundColor Cyan
    Write-Host '   / _ \ |_  / |   / _` | ''_ \|  _ \| | | | | |/ _` |/ _ \ ''__|' -ForegroundColor Cyan
    Write-Host '  / ___ \ / /| |__| (_| | |_) | |_) | |_| | | | (_| |  __/ |   ' -ForegroundColor Cyan
    Write-Host ' /_/   \_\___|_____\__,_|_.__/|____/ \__,_|_|_|\__,_|\___|_|   ' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  Azure lab scenarios, deployed in minutes.' -ForegroundColor Gray
    Write-Host $line -ForegroundColor DarkCyan
}

function Write-LabContext {
    # Status line with the active Azure context
    $ctx = Get-AzContext -ErrorAction SilentlyContinue
    if ($ctx -and $ctx.Account) {
        Write-Host ('  Account      : {0}' -f $ctx.Account.Id) -ForegroundColor DarkGray
        Write-Host ('  Subscription : {0} ({1})' -f $ctx.Subscription.Name, $ctx.Subscription.Id) -ForegroundColor DarkGray
        Write-Host ('  Tenant       : {0}' -f $ctx.Tenant.Id) -ForegroundColor DarkGray
    } else {
        Write-Host '  Not signed in.' -ForegroundColor DarkYellow
    }
    Write-Host ('-' * $script:LabWidth) -ForegroundColor DarkCyan
}

function Write-LabSection {
    param([Parameter(Mandatory)][string]$Title)
    Write-Host ''
    Write-Host ("  [ {0} ]" -f $Title) -ForegroundColor Cyan
    Write-Host ('  ' + ('-' * ($Title.Length + 4))) -ForegroundColor DarkCyan
}

function Write-LabStatus {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('Info', 'Ok', 'Warn', 'Error', 'Step')][string]$Level = 'Info'
    )
    $map = @{
        Info  = @{ Tag = '[i]'; Color = 'Gray' }
        Ok    = @{ Tag = '[+]'; Color = 'Green' }
        Warn  = @{ Tag = '[!]'; Color = 'Yellow' }
        Error = @{ Tag = '[x]'; Color = 'Red' }
        Step  = @{ Tag = '[>]'; Color = 'Cyan' }
    }
    Write-Host ('  {0} {1}' -f $map[$Level].Tag, $Message) -ForegroundColor $map[$Level].Color
}

function Show-LabMenu {
    # Renders a menu and returns the selected key (upper case)
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][System.Collections.Specialized.OrderedDictionary]$Items
    )
    Write-LabSection -Title $Title
    foreach ($key in $Items.Keys) {
        Write-Host ('   {0,3}  ' -f "[$key]") -ForegroundColor Yellow -NoNewline
        Write-Host $Items[$key]
    }
    Write-Host ''
    while ($true) {
        $choice = (Read-Host '  Select').Trim().ToUpperInvariant()
        if ($Items.Contains($choice)) { return $choice }
        Write-LabStatus -Level Warn -Message "Invalid choice '$choice'."
    }
}

function Read-LabValue {
    # Prompt with a default value and optional validation regex
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [string]$Default,
        [string]$Pattern,
        [string]$PatternHint
    )
    while ($true) {
        $label = if ($Default) { "  $Prompt [$Default]" } else { "  $Prompt" }
        $value = Read-Host $label
        if ([string]::IsNullOrWhiteSpace($value)) { $value = $Default }
        if ([string]::IsNullOrWhiteSpace($value)) { Write-LabStatus -Level Warn -Message 'A value is required.'; continue }
        if ($Pattern -and $value -notmatch $Pattern) {
            Write-LabStatus -Level Warn -Message ("Invalid value. {0}" -f $PatternHint)
            continue
        }
        return $value.Trim()
    }
}

function Read-LabConfirm {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [bool]$Default = $false
    )
    $suffix = if ($Default) { '[Y/n]' } else { '[y/N]' }
    $answer = (Read-Host "  $Prompt $suffix").Trim()
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    return $answer -match '^(y|yes|j|ja)$'
}

function Wait-LabKey {
    Write-Host ''
    Read-Host '  Press Enter to continue' | Out-Null
}

function Write-LabTable {
    # Writes rows with a colored column chosen by a scriptblock
    param(
        [Parameter(Mandatory)][object[]]$Rows,
        [Parameter(Mandatory)][string[]]$Columns,
        [scriptblock]$ColorSelector
    )
    $widths = @{}
    foreach ($c in $Columns) {
        $max = ($Rows | ForEach-Object { ([string]$_.$c).Length } | Measure-Object -Maximum).Maximum
        $widths[$c] = [Math]::Max($c.Length, [int]$max)
    }
    $header = ($Columns | ForEach-Object { $_.PadRight($widths[$_]) }) -join '  '
    Write-Host ('  ' + $header) -ForegroundColor Cyan
    Write-Host ('  ' + ('-' * $header.Length)) -ForegroundColor DarkCyan
    foreach ($r in $Rows) {
        $color = if ($ColorSelector) { & $ColorSelector $r } else { 'Gray' }
        $text = ($Columns | ForEach-Object { ([string]$r.$_).PadRight($widths[$_]) }) -join '  '
        Write-Host ('  ' + $text) -ForegroundColor $color
    }
}
