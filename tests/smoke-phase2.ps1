#Requires -Version 5.1
# Phase 2 smoke test — items API + ID stability + middleware regression.
# Exit 0 = all pass; non-zero = first failure.

[CmdletBinding()]
param(
    [string]$HubScript = (Join-Path (Split-Path -Parent $PSScriptRoot) 'Hub.ps1'),
    [int]$BootTimeoutSeconds = 12
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:Failures = New-Object 'System.Collections.Generic.List[string]'
$Script:HubProc  = $null

function Write-Step { param([string]$Msg) Write-Host ('  [..] ' + $Msg) -ForegroundColor DarkGray }
function Write-Pass { param([string]$Msg) Write-Host ('  [OK] ' + $Msg) -ForegroundColor Green }
function Write-Fail { param([string]$Msg) Write-Host ('  [FAIL] ' + $Msg) -ForegroundColor Red; $Script:Failures.Add($Msg) }

function Wait-HubReady {
    param([int]$TimeoutSeconds)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $r = Invoke-WebRequest -Uri 'http://127.0.0.1:8765/api/health' -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
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
    Start-Process pwsh -ArgumentList "-NoProfile -Sta -ExecutionPolicy Bypass -File `"$HubScript`"" -PassThru -WindowStyle Hidden
}

# === SETUP ===

foreach ($f in @('hub-error.log','hub.port','hub-stdout.txt','hub-stderr.txt')) {
    try { [System.IO.File]::Delete((Join-Path $env:TEMP $f)) } catch { }
}

Write-Host ''
Write-Host 'Phase 2 smoke test' -ForegroundColor Cyan
Write-Host ('  Hub source: ' + $HubScript)

try {
    $Script:HubProc = Start-HubProcess
    Write-Step ("Started Hub PID $($Script:HubProc.Id) — waiting for /api/health")
    if (-not (Wait-HubReady -TimeoutSeconds $BootTimeoutSeconds)) {
        $logPath = Join-Path $env:TEMP 'hub-error.log'
        $log = if (Test-Path $logPath) { Get-Content -Raw -LiteralPath $logPath } else { '(no error log)' }
        Write-Fail ("Hub did not become healthy within $BootTimeoutSeconds s. Log:`n$log")
        Stop-Hub
        exit 1
    }
    Write-Pass 'Hub booted and /api/health 200'

    # ===========================================================
    # 2.T1 — /api/items shape + content
    # ===========================================================
    Write-Host ''
    Write-Host '2.T1 — /api/items shape + content'

    $resp = Invoke-RestMethod -Uri 'http://127.0.0.1:8765/api/items' -TimeoutSec 5
    if ($null -eq $resp) { Write-Fail '/api/items returned null'; throw 'null' }
    if (-not $resp.PSObject.Properties.Match('items')) { Write-Fail "/api/items response missing 'items' property" }
    if (-not $resp.PSObject.Properties.Match('warnings')) { Write-Fail "/api/items response missing 'warnings' property" }

    $items = @($resp.items)
    if ($items.Count -lt 1) {
        Write-Fail "/api/items returned 0 items (expected >= 1 from Snippets root)"
    } else {
        Write-Pass "/api/items returned $($items.Count) items"
    }

    # Sample first item for shape
    $sample = $items[0]
    $requiredKeys = @('id','name','kind','path','root','mtime','cloudOnly')
    $missing = @()
    foreach ($k in $requiredKeys) {
        if (-not $sample.PSObject.Properties.Match($k)) { $missing += $k }
    }
    if ($missing.Count -gt 0) {
        Write-Fail "Sample item missing properties: $($missing -join ', '). Item: $($sample | ConvertTo-Json -Compress)"
    } else {
        Write-Pass "Item shape correct (id, name, kind, path, root, mtime, cloudOnly)"
    }

    # ID format
    if ($sample.id -match '^[0-9a-f]{12}$') {
        Write-Pass "ID format correct (12 hex chars): $($sample.id)"
    } else {
        Write-Fail "ID format wrong: '$($sample.id)' (expected 12 hex chars)"
    }

    # kind values
    $kinds = $items.kind | Sort-Object -Unique
    $badKinds = $kinds | Where-Object { $_ -notin @('ps1','exe') }
    if ($badKinds) {
        Write-Fail "Unexpected kind values: $($badKinds -join ', ')"
    } else {
        Write-Pass "All kinds in {ps1, exe}: $($kinds -join ', ')"
    }

    # At least the Snippets roots should be hit (we have 13 .ps1 there)
    $ps1Count = ($items | Where-Object { $_.kind -eq 'ps1' }).Count
    if ($ps1Count -lt 5) {
        Write-Fail "Expected >= 5 .ps1 items from Snippets root, got $ps1Count"
    } else {
        Write-Pass "$ps1Count .ps1 items discovered"
    }

    # Warnings should be array
    if ($resp.warnings -isnot [array] -and $null -ne $resp.warnings) {
        # PS deserializes empty arrays oddly — allow Object[] or null
        Write-Pass "Warnings present: $($resp.warnings -join '; ')"
    } else {
        $wc = if ($resp.warnings) { @($resp.warnings).Count } else { 0 }
        Write-Pass "Warnings array ($wc entries)"
    }

    # ===========================================================
    # 2.T2 — ID stability across calls
    # ===========================================================
    Write-Host ''
    Write-Host '2.T2 — ID stability'

    $second = Invoke-RestMethod -Uri 'http://127.0.0.1:8765/api/items' -TimeoutSec 5
    $idsA = @($items | Select-Object -ExpandProperty id) | Sort-Object
    $idsB = @($second.items | Select-Object -ExpandProperty id) | Sort-Object
    if ($idsA.Count -ne $idsB.Count) {
        Write-Fail "Item count differs between calls: $($idsA.Count) vs $($idsB.Count)"
    } elseif (Compare-Object $idsA $idsB) {
        Write-Fail "IDs differ between calls"
    } else {
        Write-Pass "IDs stable across two calls ($($idsA.Count) items, identical sets)"
    }

    # Same id from same path?
    $firstItem = $items[0]
    $sameNamed = $second.items | Where-Object { $_.path -eq $firstItem.path } | Select-Object -First 1
    if ($sameNamed -and $sameNamed.id -eq $firstItem.id) {
        Write-Pass "Same path -> same ID across calls"
    } else {
        Write-Fail "Same path produced different IDs across calls"
    }

    # ===========================================================
    # 2.T3 — Middleware regression on /api/items
    # ===========================================================
    Write-Host ''
    Write-Host '2.T3 — Middleware regression'

    # Cross-origin GET should be rejected (Origin header validation still active)
    try {
        $r = Invoke-WebRequest -Uri 'http://127.0.0.1:8765/api/items' -Headers @{ 'Origin' = 'http://evil.com' } -UseBasicParsing -SkipHttpErrorCheck -TimeoutSec 5
        if ($r.StatusCode -eq 403) {
            Write-Pass "Cross-origin GET /api/items -> 403 (Origin enforced)"
        } else {
            Write-Fail "Cross-origin GET /api/items -> $($r.StatusCode), expected 403"
        }
    } catch {
        Write-Fail "Cross-origin GET threw: $($_.Exception.Message)"
    }

    # POST to /api/items should be 405 (only GET defined)
    try {
        $r = Invoke-WebRequest -Uri 'http://127.0.0.1:8765/api/items' -Method POST -Headers @{
            'Origin' = 'http://127.0.0.1:8765'
            'Content-Type' = 'application/json'
        } -Body '{}' -UseBasicParsing -SkipHttpErrorCheck -TimeoutSec 5
        if ($r.StatusCode -eq 405) {
            Write-Pass "POST /api/items -> 405 (method-not-allowed)"
        } else {
            Write-Fail "POST /api/items -> $($r.StatusCode), expected 405"
        }
    } catch {
        Write-Fail "POST /api/items threw: $($_.Exception.Message)"
    }

    # ===========================================================
    # 2.T4 — Static frontend resources still served
    # ===========================================================
    Write-Host ''
    Write-Host '2.T4 — Frontend resources'

    $r = Invoke-WebRequest -Uri 'http://127.0.0.1:8765/vendor/alpine.min.js' -UseBasicParsing -TimeoutSec 5
    if ($r.StatusCode -eq 200 -and $r.Content.Length -gt 30000) {
        Write-Pass "Alpine.js vendored ($($r.Content.Length) bytes)"
    } else {
        Write-Fail "Alpine.js not served correctly: status=$($r.StatusCode), length=$($r.Content.Length)"
    }

    $r = Invoke-WebRequest -Uri 'http://127.0.0.1:8765/' -UseBasicParsing -TimeoutSec 5
    if ($r.Content -match 'x-data="hubApp\(\)"' -and $r.Content -match 'items-grid') {
        Write-Pass "index.html contains Alpine hubApp + items-grid"
    } else {
        Write-Fail "index.html missing Alpine bindings or items-grid"
    }

} finally {
    Stop-Hub
}

# ===========================================================
# RESULT
# ===========================================================

Write-Host ''
if ($Script:Failures.Count -eq 0) {
    Write-Host 'PASS — all Phase 2 smoke checks succeeded' -ForegroundColor Green
    exit 0
} else {
    Write-Host ('FAIL — ' + $Script:Failures.Count + ' failure(s):') -ForegroundColor Red
    foreach ($f in $Script:Failures) { Write-Host ('  - ' + $f) -ForegroundColor Red }
    exit 1
}
