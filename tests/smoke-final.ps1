#Requires -Version 5.1
# Final smoke — exercises the COMPILED Hub.exe end-to-end (not Hub.ps1).
# Verifies the production-shipping binary works as expected.

[CmdletBinding()]
param(
    [string]$ExePath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'Hub.exe'),
    [int]$BootTimeoutSeconds = 12
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:Failures = New-Object 'System.Collections.Generic.List[string]'
$Script:HubProc  = $null

function Write-Step { param([string]$M) Write-Host ('  [..] ' + $M) -ForegroundColor DarkGray }
function Write-Pass { param([string]$M) Write-Host ('  [OK] ' + $M) -ForegroundColor Green }
function Write-Fail { param([string]$M) Write-Host ('  [FAIL] ' + $M) -ForegroundColor Red; $Script:Failures.Add($M) }

function Wait-HubReady {
    param([int]$Port, [int]$TimeoutSeconds)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $r = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/api/health" -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
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

function Get-HubPort {
    $path = Join-Path $env:TEMP 'hub.port'
    if (Test-Path -LiteralPath $path) {
        try {
            $raw = (Get-Content -LiteralPath $path -Raw).Trim()
            $p = 0
            if ([int]::TryParse($raw, [ref]$p)) { return $p }
        } catch { }
    }
    return 8765
}

foreach ($f in @('hub-error.log','hub.port')) {
    try { [System.IO.File]::Delete((Join-Path $env:TEMP $f)) } catch { }
}

Write-Host ''
Write-Host 'Final smoke — Hub.exe' -ForegroundColor Cyan
Write-Host ('  Exe: ' + $ExePath)

if (-not (Test-Path -LiteralPath $ExePath)) {
    Write-Fail "Hub.exe not found at $ExePath. Run build-hub.ps1 first."
    exit 2
}

try {
    $Script:HubProc = Start-Process -FilePath $ExePath -PassThru
    Write-Step "Started Hub PID $($Script:HubProc.Id)"
    if (-not (Wait-HubReady -Port 8765 -TimeoutSeconds $BootTimeoutSeconds)) {
        $logPath = Join-Path $env:TEMP 'hub-error.log'
        $log = if (Test-Path -LiteralPath $logPath) { Get-Content -Raw -LiteralPath $logPath } else { '(no error log)' }
        Write-Fail "Hub.exe did not become healthy within $BootTimeoutSeconds s. Log:`n$log"
        exit 1
    }
    Write-Pass 'Hub.exe booted and /api/health 200'

    $port = Get-HubPort
    Write-Pass "Bound port: $port"

    $h = Invoke-RestMethod -Uri "http://127.0.0.1:$port/api/health" -TimeoutSec 5
    if ($h.status -ne 'ok')         { Write-Fail "/api/health status='$($h.status)'" }
    elseif ($h.port -ne $port)      { Write-Fail "/api/health port=$($h.port), expected $port" }
    elseif (-not $h.version)        { Write-Fail "/api/health has no version" }
    else { Write-Pass "/api/health OK (version=$($h.version), jobs=$($h.jobs))" }

    $v = Invoke-RestMethod -Uri "http://127.0.0.1:$port/api/version" -TimeoutSec 5
    if (-not $v.version) { Write-Fail "/api/version has no version" }
    else { Write-Pass "/api/version returns v$($v.version)" }

    $catalog = Invoke-RestMethod -Uri "http://127.0.0.1:$port/api/items" -TimeoutSec 5
    $items   = @($catalog.items)
    if ($items.Count -lt 1) { Write-Fail "/api/items returned 0 items" }
    else { Write-Pass "/api/items returned $($items.Count) items" }

    # Pick first .ps1 + check schema
    $sample = $items | Where-Object { $_.kind -eq 'ps1' } | Select-Object -First 1
    if (-not $sample) {
        Write-Fail 'No .ps1 sample available — skipping schema check'
    } else {
        $schema = Invoke-RestMethod -Uri "http://127.0.0.1:$port/api/items/$($sample.id)/schema" -TimeoutSec 5
        if (-not $schema.mode) { Write-Fail "Schema missing mode for $($sample.name)" }
        else { Write-Pass "Schema endpoint OK for $($sample.name) (mode=$($schema.mode))" }
    }

    # Page renders + script order correct
    $html = (Invoke-WebRequest -Uri "http://127.0.0.1:$port/" -UseBasicParsing -TimeoutSec 5).Content
    if ($html -notmatch 'x-data="hubApp\(\)"') { Write-Fail "Root HTML missing Alpine hubApp binding" }
    elseif ($html.IndexOf('app.js') -gt $html.IndexOf('alpine.min.js')) {
        Write-Fail "Script order regression: app.js loads AFTER alpine.min.js"
    } else { Write-Pass 'Root HTML serves with correct script order' }

    # Vendored Alpine still served
    $alpine = Invoke-WebRequest -Uri "http://127.0.0.1:$port/vendor/alpine.min.js" -UseBasicParsing -TimeoutSec 5
    if ($alpine.StatusCode -ne 200) { Write-Fail "alpine.min.js -> $($alpine.StatusCode)" }
    elseif ($alpine.Content.Length -lt 40000) { Write-Fail "alpine.min.js shorter than expected" }
    else { Write-Pass "alpine.min.js served ($($alpine.Content.Length) bytes)" }

} finally {
    Stop-Hub
    Start-Sleep -Milliseconds 500
}

Write-Host ''
if ($Script:Failures.Count -eq 0) {
    Write-Host 'PASS — final smoke succeeded' -ForegroundColor Green
    exit 0
} else {
    Write-Host ('FAIL — ' + $Script:Failures.Count + ' failure(s):') -ForegroundColor Red
    foreach ($f in $Script:Failures) { Write-Host ('  - ' + $f) -ForegroundColor Red }
    exit 1
}
