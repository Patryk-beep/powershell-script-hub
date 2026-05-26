#Requires -Version 5.1
# P-ui-1 smoke — vendored fonts + WOFF2 MIME + token block + preload links.

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
    Start-Process pwsh -ArgumentList '-NoProfile','-Sta','-ExecutionPolicy','Bypass','-File',$HubScript,'-ExtraScanRoots',$Script:Fixtures -PassThru -WindowStyle Hidden
}

function Assert-Contains { param([string]$Hay,[string]$Needle,[string]$Label) if ($Hay -match [regex]::Escape($Needle)) { Write-Pass $Label } else { Write-Fail "$Label — missing '$Needle'" } }

foreach ($f in @('hub-error.log','hub.port')) {
    try { [System.IO.File]::Delete((Join-Path $env:TEMP $f)) } catch { }
}

Write-Host ''
Write-Host 'P-ui-1 smoke (fonts + MIME + tokens)' -ForegroundColor Cyan

# Static file presence
$fontsDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'wwwroot\vendor\fonts'
foreach ($n in @('geist-sans-latin.woff2','geist-mono-latin.woff2','LICENSE-GEIST.txt')) {
    $p = Join-Path $fontsDir $n
    if (Test-Path $p) {
        $size = (Get-Item $p).Length
        Write-Pass "$n exists ($size bytes)"
    } else { Write-Fail "$n missing at $p" }
}

# Magic bytes
foreach ($n in @('geist-sans-latin.woff2','geist-mono-latin.woff2')) {
    $p = Join-Path $fontsDir $n
    if (Test-Path $p) {
        $b = [System.IO.File]::ReadAllBytes($p) | Select-Object -First 4
        $magic = -join ($b | ForEach-Object { [char]$_ })
        if ($magic -eq 'wOF2') { Write-Pass "$n magic = wOF2" } else { Write-Fail "$n magic = '$magic' (expected wOF2)" }
    }
}

try {
    $Script:HubProc = Start-HubProcess
    if (-not (Wait-HubReady -TimeoutSeconds $BootTimeoutSeconds)) {
        Write-Fail "Hub did not boot"; Stop-Hub; exit 1
    }
    Write-Pass "Hub booted"

    $base = "http://127.0.0.1:$Script:HubPort"

    # MIME
    Write-Host ''
    Write-Host 'WOFF2 MIME'
    $r = Invoke-WebRequest -Uri "$base/vendor/fonts/geist-sans-latin.woff2" -UseBasicParsing -TimeoutSec 5
    if ($r.Headers['Content-Type'] -match 'font/woff2') { Write-Pass "Geist Sans Content-Type = font/woff2" }
    else { Write-Fail "Sans Content-Type = $($r.Headers['Content-Type'])" }
    $r = Invoke-WebRequest -Uri "$base/vendor/fonts/geist-mono-latin.woff2" -UseBasicParsing -TimeoutSec 5
    if ($r.Headers['Content-Type'] -match 'font/woff2') { Write-Pass "Geist Mono Content-Type = font/woff2" }
    else { Write-Fail "Mono Content-Type = $($r.Headers['Content-Type'])" }

    # CSS contains tokens + @font-face
    Write-Host ''
    Write-Host 'style.css head'
    $css = (Invoke-WebRequest -Uri "$base/style.css" -UseBasicParsing).Content
    Assert-Contains $css "--bg-base"           'token --bg-base'
    Assert-Contains $css "--bg-surface"        'token --bg-surface'
    Assert-Contains $css "--accent"            'token --accent'
    Assert-Contains $css "--radius"            'token --radius'
    Assert-Contains $css "@font-face"          '@font-face block'
    Assert-Contains $css "font-display: swap"  'font-display swap'
    Assert-Contains $css "font-family: 'Geist'" "Geist family declared"
    Assert-Contains $css "font-family: 'Geist Mono'" "Geist Mono family declared"
    Assert-Contains $css "oklch("              'OKLCH used'

    # index.html preload
    Write-Host ''
    Write-Host 'index.html preload'
    $html = (Invoke-WebRequest -Uri "$base/" -UseBasicParsing).Content
    Assert-Contains $html 'rel="preload"'             'preload link tag'
    Assert-Contains $html 'geist-sans-latin.woff2'    'sans preload href'
    Assert-Contains $html 'geist-mono-latin.woff2'    'mono preload href'
    Assert-Contains $html 'crossorigin'               'crossorigin attribute'

} finally {
    Stop-Hub
}

Write-Host ''
if ($Script:Failures.Count -eq 0) {
    Write-Host 'P-ui-1 smoke PASS' -ForegroundColor Green
    exit 0
} else {
    Write-Host ("P-ui-1 smoke FAIL ({0} issues)" -f $Script:Failures.Count) -ForegroundColor Red
    foreach ($f in $Script:Failures) { Write-Host "  - $f" -ForegroundColor Red }
    exit 1
}
