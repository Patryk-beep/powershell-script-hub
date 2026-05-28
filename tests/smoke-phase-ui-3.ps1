#Requires -Version 5.1
# P-ui-3 smoke — command-K palette state + markup + CSS.

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

function Assert-Contains { param([string]$Hay,[string]$Needle,[string]$Label) if ($Hay -match [regex]::Escape($Needle)) { Write-Pass $Label } else { Write-Fail "$Label — missing '$Needle'" } }

foreach ($f in @('hub-error.log','hub.port')) {
    try { [System.IO.File]::Delete((Join-Path $env:TEMP $f)) } catch { }
}

Write-Host ''
Write-Host 'P-ui-3 smoke (command-K palette)' -ForegroundColor Cyan

try {
    $Script:HubProc = Start-HubProcess
    if (-not (Wait-HubReady -TimeoutSeconds $BootTimeoutSeconds)) {
        Write-Fail "Hub did not boot"; Stop-Hub; exit 1
    }
    Write-Pass "Hub booted"

    $base = "http://127.0.0.1:$Script:HubPort"

    Write-Host ''
    Write-Host 'app.js palette state + methods'
    $js = (Invoke-WebRequest -Uri "$base/app.js" -UseBasicParsing).Content
    Assert-Contains $js 'paletteOpen: false'      'paletteOpen state'
    Assert-Contains $js 'paletteQuery'            'paletteQuery state'
    Assert-Contains $js 'paletteIndex'            'paletteIndex state'
    Assert-Contains $js 'get paletteResults()'    'paletteResults getter'
    Assert-Contains $js 'openPalette()'           'openPalette method'
    Assert-Contains $js 'closePalette()'          'closePalette method'
    Assert-Contains $js 'selectPaletteItem()'     'selectPaletteItem method'
    Assert-Contains $js 'movePaletteIndex'        'movePaletteIndex method'

    Write-Host ''
    Write-Host 'app.js keybinding'
    Assert-Contains $js '(ev.ctrlKey || ev.metaKey)'  'ctrl/cmd modifier check'
    Assert-Contains $js "toLowerCase() === 'k'"        'k key check'
    Assert-Contains $js 'ev.preventDefault()'          'preventDefault on K'

    Write-Host ''
    Write-Host 'index.html palette markup'
    $html = (Invoke-WebRequest -Uri "$base/" -UseBasicParsing).Content
    Assert-Contains $html 'x-if="paletteOpen"'           'palette x-if guard'
    Assert-Contains $html 'palette-dialog"'              'palette dialog class'
    Assert-Contains $html 'palette-input'                 'palette input class'
    Assert-Contains $html 'palette-item-active'           'palette active item class'
    Assert-Contains $html '@keydown.enter.prevent="selectPaletteItem()"'  'enter handler'

    Write-Host ''
    Write-Host 'style.css palette rules'
    $css = (Invoke-WebRequest -Uri "$base/style.css" -UseBasicParsing).Content
    Assert-Contains $css '.palette-dialog'        'palette-dialog rule'
    Assert-Contains $css '.palette-input'         'palette-input rule'
    Assert-Contains $css '.palette-item-active'   'palette-item-active rule'
    Assert-Contains $css '.palette-item-path'     'palette-item-path rule'

} finally {
    Stop-Hub
}

Write-Host ''
if ($Script:Failures.Count -eq 0) {
    Write-Host 'P-ui-3 smoke PASS' -ForegroundColor Green
    exit 0
} else {
    Write-Host ("P-ui-3 smoke FAIL ({0} issues)" -f $Script:Failures.Count) -ForegroundColor Red
    foreach ($f in $Script:Failures) { Write-Host "  - $f" -ForegroundColor Red }
    exit 1
}
