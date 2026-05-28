#Requires -Version 5.1
# smoke-phase3-ui.ps1 — Phase 3 UI smoke: workflow tab, editor, history tab, Ctrl+K.

[CmdletBinding()]
param(
    [string]$HubScript = (Join-Path (Split-Path -Parent $PSScriptRoot) 'Hub.ps1'),
    [int]$BootTimeoutSeconds = 15
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:Failures = New-Object 'System.Collections.Generic.List[string]'
$Script:HubProc  = $null
$Script:Fixtures = Join-Path $PSScriptRoot 'fixtures'
$Script:HubPort  = 8765
$Script:BaseUrl  = "http://127.0.0.1:$Script:HubPort"

function Write-Pass { param([string]$M) Write-Host ('  [OK] '   + $M) -ForegroundColor Green }
function Write-Fail { param([string]$M) Write-Host ('  [FAIL] ' + $M) -ForegroundColor Red; $Script:Failures.Add($M) }
function Assert-Has { param([string]$Hay,[string]$Needle,[string]$Label) if ($Hay -match [regex]::Escape($Needle)) { Write-Pass $Label } else { Write-Fail "$Label — missing '$Needle'" } }

function Stop-Hub {
    if ($Script:HubProc -and -not $Script:HubProc.HasExited) {
        & taskkill.exe /T /F /PID $Script:HubProc.Id 2>$null | Out-Null
    }
    $Script:HubProc = $null; Start-Sleep -Milliseconds 600
}

foreach ($f in @('hub-error.log','hub.port')) { try { [System.IO.File]::Delete((Join-Path $env:TEMP $f)) } catch { } }

Write-Host ''
Write-Host 'smoke-phase3-ui — workflow & history UI' -ForegroundColor Cyan

try {
    $Script:HubProc = Start-Process pwsh `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$HubScript`" -ExtraScanRoots `"$Script:Fixtures`"" `
        -PassThru -WindowStyle Hidden
    $deadline = (Get-Date).AddSeconds($BootTimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try { $r = Invoke-WebRequest "$Script:BaseUrl/api/health" -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop; if ($r.StatusCode -eq 200) { break } }
        catch { Start-Sleep -Milliseconds 300 }
    }
    Write-Pass 'Hub booted'

    $html = (Invoke-WebRequest "$Script:BaseUrl/" -UseBasicParsing -TimeoutSec 5).Content
    $js   = (Invoke-WebRequest "$Script:BaseUrl/app.js" -UseBasicParsing -TimeoutSec 5).Content
    $css  = (Invoke-WebRequest "$Script:BaseUrl/style.css" -UseBasicParsing -TimeoutSec 5).Content

    Write-Host ''
    Write-Host '--- index.html ---'
    Assert-Has $html 'tab-nav'             'Tab nav present'
    Assert-Has $html 'switchTab'           'switchTab binding'
    Assert-Has $html "activeTab === 'workflows'" 'Workflows tab if-guard'
    Assert-Has $html "activeTab === 'history'"   'History tab if-guard'
    Assert-Has $html 'wfNewForm'           'New Workflow button'
    Assert-Has $html 'wfTrigger'           'Run button'
    Assert-Has $html 'wfKill'             'Kill button'
    Assert-Has $html 'wfEditForm'         'Edit button'
    Assert-Has $html 'wfStepStatus'       'Step progress'
    Assert-Has $html 'hist-table'          'History table class'
    Assert-Has $html 'histPrevPage'        'History pagination prev'
    Assert-Has $html 'Export CSV'          'CSV export button'
    Assert-Has $html '_isWorkflow'         'Palette workflow discriminator'

    Write-Host ''
    Write-Host '--- app.js ---'
    Assert-Has $js 'activeTab'             'activeTab state'
    Assert-Has $js 'wfEditMode'           'wfEditMode state'
    Assert-Has $js 'wfForm'               'wfForm state'
    Assert-Has $js 'refreshWorkflows'     'refreshWorkflows method'
    Assert-Has $js 'wfTrigger'            'wfTrigger method'
    Assert-Has $js 'wfKill'              'wfKill method'
    Assert-Has $js 'wfSave'              'wfSave method'
    Assert-Has $js 'wfStepStatus'        'wfStepStatus method'
    Assert-Has $js 'refreshHistory'       'refreshHistory method'
    Assert-Has $js 'histFormatDuration'   'histFormatDuration helper'
    Assert-Has $js '_isWorkflow'          'palette workflow filter'
    Assert-Has $js 'bindTabWatch'         'bindTabWatch method'

    Write-Host ''
    Write-Host '--- style.css ---'
    Assert-Has $css '.tab-btn'            'tab-btn rule'
    Assert-Has $css '.wf-card'            'wf-card rule'
    Assert-Has $css '.wf-step-progress'   'wf-step-progress rule'
    Assert-Has $css '.hist-table'         'hist-table rule'
    Assert-Has $css '.wf-step-running'    'wf-step-running state'
    Assert-Has $css '.wf-step-done'       'wf-step-done state'

    Write-Host ''
    Write-Host '--- API contract: regression check ---'
    # GET /api/workflows still works (Phase 1 contract)
    $r = Invoke-RestMethod "$Script:BaseUrl/api/workflows" -TimeoutSec 5
    if ($null -ne $r -and $r -is [System.Array]) { Write-Pass 'GET /api/workflows returns array' }
    else { Write-Fail 'GET /api/workflows broken' }

    # GET /api/history returns expected shape
    $r = Invoke-RestMethod "$Script:BaseUrl/api/history" -TimeoutSec 5
    if ($null -ne $r.entries -and $null -ne $r.total) { Write-Pass 'GET /api/history shape intact' }
    else { Write-Fail 'GET /api/history shape broken' }

    # paletteOpen + paletteQuery still present (regression)
    Assert-Has $js 'paletteOpen: false' 'paletteOpen state (regression)'
    Assert-Has $js "toLowerCase() === 'k'" 'Ctrl+K binding (regression)'

} finally {
    Stop-Hub
}

Write-Host ''
if ($Script:Failures.Count -eq 0) {
    Write-Host 'smoke-phase3-ui PASS' -ForegroundColor Green
    exit 0
} else {
    Write-Host ("smoke-phase3-ui FAIL ({0} issue(s)):" -f $Script:Failures.Count) -ForegroundColor Red
    foreach ($f in $Script:Failures) { Write-Host "  - $f" -ForegroundColor Red }
    exit 1
}
