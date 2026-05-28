#Requires -Version 5.1
# Phase-schema-3 smoke — frontend assertions:
#   - CSS bumped (minmax 320, padding 18)
#   - SVG symbols for new chip icons present
#   - Card chip strip markup present
#   - hubApp() helper methods defined
#   - New widget templates in form pane
#   - paramPreview is reaching the client via /api/items

[CmdletBinding()]
param(
    [string]$HubScript = (Join-Path (Split-Path -Parent $PSScriptRoot) 'Hub.ps1'),
    [int]$BootTimeoutSeconds = 12
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:Failures = New-Object 'System.Collections.Generic.List[string]'
$Script:HubProc  = $null
$Script:Fixtures = Join-Path $PSScriptRoot 'fixtures'
$Script:HubPort  = 8765

function Write-Step { param([string]$Msg) Write-Host ('  [..] ' + $Msg) -ForegroundColor DarkGray }
function Write-Pass { param([string]$Msg) Write-Host ('  [OK] ' + $Msg) -ForegroundColor Green }
function Write-Fail { param([string]$Msg) Write-Host ('  [FAIL] ' + $Msg) -ForegroundColor Red; $Script:Failures.Add($Msg) }

function Wait-HubReady {
    param([int]$TimeoutSeconds)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $r = Invoke-WebRequest -Uri "http://127.0.0.1:$Script:HubPort/api/health" -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
            if ($r.StatusCode -eq 200) { return $true }
        } catch { Start-Sleep -Milliseconds 300 }
    }
    return $false
}

function Stop-Hub {
    if ($Script:HubProc -and -not $Script:HubProc.HasExited) {
        & taskkill.exe /T /F /PID $Script:HubProc.Id 2>$null | Out-Null
    }
    $Script:HubProc = $null
}

function Start-HubProcess {
    Start-Process pwsh -ArgumentList "-NoProfile -Sta -ExecutionPolicy Bypass -File `"$HubScript`" -ExtraScanRoots `"$Script:Fixtures`"" -PassThru -WindowStyle Hidden
}

function Assert-Contains {
    param([string]$Haystack, [string]$Needle, [string]$Label)
    if ($Haystack -match [regex]::Escape($Needle)) { Write-Pass $Label }
    else { Write-Fail ("$Label — missing: $Needle") }
}

foreach ($f in @('hub-error.log','hub.port')) {
    try { [System.IO.File]::Delete((Join-Path $env:TEMP $f)) } catch { }
}

Write-Host ''
Write-Host 'Phase-schema-3 smoke (frontend cards + chip strip + new widgets)' -ForegroundColor Cyan

try {
    $Script:HubProc = Start-HubProcess
    if (-not (Wait-HubReady -TimeoutSeconds $BootTimeoutSeconds)) {
        Write-Fail "Hub did not boot"; Stop-Hub; exit 1
    }
    Write-Pass 'Hub booted'

    $base = "http://127.0.0.1:$Script:HubPort"

    # ===========================================================
    # CSS bump
    # ===========================================================
    Write-Host ''
    Write-Host 'style.css — bigger cards'
    $css = (Invoke-WebRequest -Uri "$base/style.css" -UseBasicParsing).Content
    Assert-Contains $css 'minmax(320px'   'items-grid minmax bumped to 320px'
    Assert-Contains $css 'padding: 18px 18px 16px' 'item-card padding bumped to 18'
    Assert-Contains $css '.item-card-params' 'chip strip class defined'
    Assert-Contains $css '.param-chip'        'param-chip styled'
    Assert-Contains $css '.param-chip-required' 'required chip styled'
    Assert-Contains $css '.param-chip-raw'    'raw chip styled'
    Assert-Contains $css '.form-unsupported'  'form-unsupported styled'

    # ===========================================================
    # SVG symbols + chip strip markup + new form widgets
    # ===========================================================
    Write-Host ''
    Write-Host 'index.html — sprite + chip strip + new widget templates'
    $html = (Invoke-WebRequest -Uri "$base/" -UseBasicParsing).Content
    Assert-Contains $html 'id="i-hash"'      'icon i-hash present'
    Assert-Contains $html 'id="i-lock"'      'icon i-lock present'
    Assert-Contains $html 'id="i-calendar"'  'icon i-calendar present'
    Assert-Contains $html 'id="i-link"'      'icon i-link present'
    Assert-Contains $html 'id="i-toggle"'    'icon i-toggle present'
    Assert-Contains $html 'id="i-list-multi"' 'icon i-list-multi present'
    Assert-Contains $html 'id="i-select"'    'icon i-select present'
    Assert-Contains $html 'id="i-puzzle"'    'icon i-puzzle present'
    Assert-Contains $html 'class="item-card-params"' 'card chip-strip div'
    Assert-Contains $html 'param-chip-raw'    'raw chip in markup'
    Assert-Contains $html 'paramChipTags(item)' 'paramChipTags invocation'
    Assert-Contains $html 'type="password"'   'password widget template'
    Assert-Contains $html 'type="datetime-local"' 'datetime-local widget template'
    Assert-Contains $html 'type="url"'        'url widget template'
    Assert-Contains $html 'form-unsupported'  'unsupported widget renderer'
    Assert-Contains $html 'form-aliases'      'aliases label slot'

    # ===========================================================
    # app.js — helper methods present
    # ===========================================================
    Write-Host ''
    Write-Host 'app.js — helper methods'
    $js = (Invoke-WebRequest -Uri "$base/app.js" -UseBasicParsing).Content
    Assert-Contains $js 'paramChipTags(item)'       'paramChipTags method'
    Assert-Contains $js 'isRawCard(item)'           'isRawCard method'
    Assert-Contains $js 'fieldGroupedBySet'         'fieldGroupedBySet method'
    Assert-Contains $js 'textareaCountHint'         'textareaCountHint method'

    # ===========================================================
    # paramPreview arrives via /api/items (round-trip)
    # ===========================================================
    Write-Host ''
    Write-Host 'paramPreview round-trip on /api/items'
    $catalog = Invoke-RestMethod -Uri "$base/api/items" -TimeoutSec 5
    $items = @($catalog.items)
    $allw  = $items | Where-Object { $_.name -eq 'all-widgets' } | Select-Object -First 1
    if (-not $allw) { Write-Fail 'all-widgets fixture missing from catalog' }
    elseif ($null -eq $allw.paramPreview) { Write-Fail 'all-widgets paramPreview null on /api/items' }
    else {
        Write-Pass ("paramPreview tags = [{0}]" -f ((@($allw.paramPreview.typeTags)) -join ','))
        if ([int]$allw.paramPreview.requiredCount -lt 1) { Write-Fail "requiredCount should be >= 1 (all-widgets has 2)" }
        else { Write-Pass "requiredCount = $($allw.paramPreview.requiredCount)" }
    }

} finally {
    Stop-Hub
}

Write-Host ''
if ($Script:Failures.Count -eq 0) {
    Write-Host 'Phase-schema-3 smoke PASS' -ForegroundColor Green
    exit 0
} else {
    Write-Host ("Phase-schema-3 smoke FAIL ({0} issues)" -f $Script:Failures.Count) -ForegroundColor Red
    foreach ($f in $Script:Failures) { Write-Host "  - $f" -ForegroundColor Red }
    exit 1
}
