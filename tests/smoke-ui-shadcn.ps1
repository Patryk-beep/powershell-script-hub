#Requires -Version 5.1
# Aggregate UI smoke — runs P-ui-1..3 + adds 8 contract assertions.

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

Write-Host ''
Write-Host '=== smoke-ui-shadcn — aggregate verification ===' -ForegroundColor Cyan

foreach ($sub in @('smoke-phase-ui-1.ps1','smoke-phase-ui-2.ps1','smoke-phase-ui-3.ps1')) {
    Write-Host ''
    Write-Host "--- $sub ---" -ForegroundColor Yellow
    pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot $sub)
    if ($LASTEXITCODE -ne 0) { Write-Fail "$sub exited $LASTEXITCODE" } else { Write-Pass "$sub green" }
}

# Aggregate contract assertions
foreach ($f in @('hub-error.log','hub.port')) {
    try { [System.IO.File]::Delete((Join-Path $env:TEMP $f)) } catch { }
}

try {
    Write-Host ''
    Write-Host '--- Contract assertions ---' -ForegroundColor Yellow

    $Script:HubProc = Start-HubProcess
    if (-not (Wait-HubReady -TimeoutSeconds $BootTimeoutSeconds)) {
        Write-Fail 'Hub did not boot'; Stop-Hub
    } else {
        Write-Pass 'Hub booted'

        $base = "http://127.0.0.1:$Script:HubPort"

        # 1+2. Font files present + correct MIME via GET
        $r = Invoke-WebRequest -Uri "$base/vendor/fonts/geist-sans-latin.woff2" -UseBasicParsing -TimeoutSec 5
        if ($r.Headers['Content-Type'] -match 'font/woff2') { Write-Pass 'Sans WOFF2 + MIME' } else { Write-Fail 'Sans MIME' }
        $r = Invoke-WebRequest -Uri "$base/vendor/fonts/geist-mono-latin.woff2" -UseBasicParsing -TimeoutSec 5
        if ($r.Headers['Content-Type'] -match 'font/woff2') { Write-Pass 'Mono WOFF2 + MIME' } else { Write-Fail 'Mono MIME' }

        # 3. index.html preload
        $html = (Invoke-WebRequest -Uri "$base/" -UseBasicParsing).Content
        Assert-Contains $html 'rel="preload"' 'preload links'

        # 4. Tokens in CSS
        $css = (Invoke-WebRequest -Uri "$base/style.css" -UseBasicParsing).Content
        Assert-Contains $css '--bg-base' 'token --bg-base'
        Assert-Contains $css 'oklch('     'OKLCH used'

        # 5. Component primitives
        Assert-Contains $css '.card {' 'card primitive'
        Assert-Contains $css '.dialog {' 'dialog primitive'

        # 6. Palette state in app.js
        $js = (Invoke-WebRequest -Uri "$base/app.js" -UseBasicParsing).Content
        Assert-Contains $js 'paletteOpen' 'palette state'
        Assert-Contains $js '(ev.ctrlKey || ev.metaKey)' 'ctrl/cmd K binding'

        # 7. Markup palette guard
        Assert-Contains $html 'palette-dialog"' 'palette dialog markup'

        # 8. Sentinel — /api/items still returns paramPreview (regression for P-schema-1..3)
        $cat = Invoke-RestMethod -Uri "$base/api/items" -TimeoutSec 5
        $sample = @($cat.items | Where-Object { $_.kind -eq 'ps1' -and $null -ne $_.paramPreview }) | Select-Object -First 1
        if ($sample) { Write-Pass "Regression OK — paramPreview still flowing (sample: $($sample.name))" }
        else { Write-Fail 'No items with paramPreview — schema regression!' }
    }
} finally {
    Stop-Hub
}

Write-Host ''
if ($Script:Failures.Count -eq 0) {
    Write-Host 'smoke-ui-shadcn PASS' -ForegroundColor Green
    exit 0
} else {
    Write-Host ("smoke-ui-shadcn FAIL ({0} issues)" -f $Script:Failures.Count) -ForegroundColor Red
    foreach ($f in $Script:Failures) { Write-Host "  - $f" -ForegroundColor Red }
    exit 1
}
