#Requires -Version 5.1
# P-ui-2 smoke — component primitives present in style.css.

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
Write-Host 'P-ui-2 smoke (component primitives + apply)' -ForegroundColor Cyan

try {
    $Script:HubProc = Start-HubProcess
    if (-not (Wait-HubReady -TimeoutSeconds $BootTimeoutSeconds)) {
        Write-Fail "Hub did not boot"; Stop-Hub; exit 1
    }
    Write-Pass "Hub booted"

    $base = "http://127.0.0.1:$Script:HubPort"
    $css = (Invoke-WebRequest -Uri "$base/style.css" -UseBasicParsing).Content

    Write-Host ''
    Write-Host 'Primitive class definitions'
    Assert-Contains $css ".card {"           '.card primitive'
    Assert-Contains $css ".btn {"            '.btn primitive'
    Assert-Contains $css ".btn-primary"      '.btn-primary variant'
    Assert-Contains $css ".btn-ghost"        '.btn-ghost variant'
    Assert-Contains $css ".btn-danger"       '.btn-danger variant'
    Assert-Contains $css ".input {"          '.input primitive'
    Assert-Contains $css ".badge {"          '.badge primitive'
    Assert-Contains $css ".dialog {"         '.dialog primitive'
    Assert-Contains $css ".dialog-backdrop"  '.dialog-backdrop'

    Write-Host ''
    Write-Host 'Token + motion plumbing'
    Assert-Contains $css "prefers-reduced-motion: no-preference"  'reduced-motion guarded hover'
    Assert-Contains $css "var(--accent-soft)"     'accent-soft focus ring'
    Assert-Contains $css "var(--bg-muted)"        'bg-muted (input bg)'

    Write-Host ''
    Write-Host 'No JS / markup changes for P2 (delegated to P3)'
    # quick markup-untouched sanity: index.html still has Alpine x-data
    $html = (Invoke-WebRequest -Uri "$base/" -UseBasicParsing).Content
    Assert-Contains $html 'x-data="hubApp()"'   'Alpine x-data root preserved'
    Assert-Contains $html 'items-grid'          'items-grid layout preserved'

} finally {
    Stop-Hub
}

Write-Host ''
if ($Script:Failures.Count -eq 0) {
    Write-Host 'P-ui-2 smoke PASS' -ForegroundColor Green
    exit 0
} else {
    Write-Host ("P-ui-2 smoke FAIL ({0} issues)" -f $Script:Failures.Count) -ForegroundColor Red
    foreach ($f in $Script:Failures) { Write-Host "  - $f" -ForegroundColor Red }
    exit 1
}
