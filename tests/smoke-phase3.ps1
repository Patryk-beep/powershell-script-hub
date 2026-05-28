#Requires -Version 5.1
# Phase 3 smoke — schema introspection (typed + raw), no execution side-effects,
# real-world Snippets coverage, middleware regression.

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
$Script:SentinelPath = Join-Path $env:TEMP 'hub-fixture-executed.flag'

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
    $argStr = "-NoProfile -Sta -ExecutionPolicy Bypass -File `"$HubScript`" -ExtraScanRoots `"$Script:Fixtures`""
    Start-Process pwsh -ArgumentList $argStr -PassThru -WindowStyle Hidden
}

# === SETUP ===

foreach ($f in @('hub-error.log','hub.port','hub-fixture-executed.flag')) {
    try { [System.IO.File]::Delete((Join-Path $env:TEMP $f)) } catch { }
}

Write-Host ''
Write-Host 'Phase 3 smoke test' -ForegroundColor Cyan
Write-Host ('  Hub source: ' + $HubScript)
Write-Host ('  Fixtures:   ' + $Script:Fixtures)

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
    Write-Pass 'Hub booted'

    # Gather items, locate fixtures by name
    $catalog = Invoke-RestMethod -Uri 'http://127.0.0.1:8765/api/items' -TimeoutSec 5
    $items   = @($catalog.items)
    $sample  = $items | Where-Object { $_.name -eq 'sample-param' } | Select-Object -First 1
    $noparam = $items | Where-Object { $_.name -eq 'no-param' }     | Select-Object -First 1
    if (-not $sample)  { Write-Fail 'sample-param fixture not discovered'; throw 'fixture' }
    if (-not $noparam) { Write-Fail 'no-param fixture not discovered'; throw 'fixture' }
    Write-Pass "Both fixtures discovered ($($sample.id), $($noparam.id))"

    # ===========================================================
    # 3.T1 — Parser coverage on sample-param.ps1
    # ===========================================================
    Write-Host ''
    Write-Host '3.T1 — Typed schema mapping'

    $schema = Invoke-RestMethod -Uri "http://127.0.0.1:8765/api/items/$($sample.id)/schema" -TimeoutSec 5
    if ($schema.mode -ne 'typed') { Write-Fail "sample-param mode='$($schema.mode)', expected 'typed'"; throw 'mode' }
    Write-Pass "Schema mode = typed"

    $fields = @($schema.fields)
    if ($fields.Count -ne 6) { Write-Fail "Expected 6 fields, got $($fields.Count)" }
    else { Write-Pass "6 fields detected" }

    function Get-Field { param([string]$Name) ($fields | Where-Object { $_.name -eq $Name } | Select-Object -First 1) }

    $upn = Get-Field 'UserPrincipalName'
    if (-not $upn)                          { Write-Fail "UserPrincipalName field missing" }
    elseif ($upn.widget -ne 'textbox')      { Write-Fail "UPN widget='$($upn.widget)', expected textbox" }
    elseif (-not $upn.required)             { Write-Fail "UPN should be required=true" }
    elseif ($upn.help -notmatch 'UPN')      { Write-Fail "UPN help missing 'UPN' substring: '$($upn.help)'" }
    else { Write-Pass "UPN: textbox + required + help present" }

    $name = Get-Field 'Name'
    if (-not $name)                         { Write-Fail "Name field missing" }
    elseif ($name.widget -ne 'textbox')     { Write-Fail "Name widget='$($name.widget)'" }
    elseif ($name.default -ne 'default-name') { Write-Fail "Name default='$($name.default)'" }
    else { Write-Pass "Name: textbox + default='default-name'" }

    $count = Get-Field 'Count'
    if (-not $count)                        { Write-Fail "Count field missing" }
    elseif ($count.widget -ne 'number')     { Write-Fail "Count widget='$($count.widget)'" }
    elseif ([int]$count.default -ne 5)      { Write-Fail "Count default='$($count.default)'" }
    else { Write-Pass "Count: number + default=5" }

    $force = Get-Field 'Force'
    if (-not $force)                              { Write-Fail "Force field missing" }
    elseif ($force.widget -ne 'checkbox-switch')  { Write-Fail "Force widget='$($force.widget)'" }
    else { Write-Pass "Force: checkbox-switch" }

    $quiet = Get-Field 'Quiet'
    if (-not $quiet)                              { Write-Fail "Quiet field missing" }
    elseif ($quiet.widget -ne 'checkbox')         { Write-Fail "Quiet widget='$($quiet.widget)'" }
    else { Write-Pass "Quiet: checkbox" }

    $mode = Get-Field 'Mode'
    if (-not $mode)                               { Write-Fail "Mode field missing" }
    elseif ($mode.widget -ne 'dropdown')          { Write-Fail "Mode widget='$($mode.widget)'" }
    else {
        $opts = @($mode.options)
        if (($opts -join ',') -ne 'A,B,C')        { Write-Fail "Mode options='$($opts -join ',')'" }
        else { Write-Pass "Mode: dropdown options=A,B,C" }
    }

    # ===========================================================
    # 3.T2 — Raw-mode fallback on no-param.ps1
    # ===========================================================
    Write-Host ''
    Write-Host '3.T2 — Raw-mode fallback'

    $rawSchema = Invoke-RestMethod -Uri "http://127.0.0.1:8765/api/items/$($noparam.id)/schema" -TimeoutSec 5
    if ($rawSchema.mode -ne 'raw') {
        Write-Fail "no-param mode='$($rawSchema.mode)', expected 'raw'"
    } else {
        Write-Pass "no-param mode=raw (reason: $($rawSchema.reason))"
    }
    if (@($rawSchema.fields).Count -ne 0) {
        Write-Fail "Raw schema should have 0 fields, got $((@($rawSchema.fields)).Count)"
    } else {
        Write-Pass "Raw schema has 0 fields"
    }

    # ===========================================================
    # 3.T3 — No script execution during schema fetch
    # ===========================================================
    Write-Host ''
    Write-Host '3.T3 — Schema fetch does NOT execute the script'

    # Sentinel was deleted at setup. Hit schema again. Assert sentinel absent.
    Invoke-RestMethod -Uri "http://127.0.0.1:8765/api/items/$($sample.id)/schema" -TimeoutSec 5 | Out-Null
    Start-Sleep -Milliseconds 500
    if (Test-Path -LiteralPath $Script:SentinelPath) {
        $content = Get-Content -Raw -LiteralPath $Script:SentinelPath
        Write-Fail "Sentinel file appeared — schema fetch EXECUTED the script!`n$content"
    } else {
        Write-Pass "Sentinel absent — AST-only introspection confirmed"
    }

    # ===========================================================
    # 3.T4 — Real-world coverage across Snippets scripts
    # ===========================================================
    Write-Host ''
    Write-Host '3.T4 — Real-world Snippets coverage'

    $snippets = $items | Where-Object { $_.root -like '*Snippets' -and $_.kind -eq 'ps1' }
    $errs = 0
    $typed = 0
    $raw = 0
    foreach ($it in $snippets) {
        try {
            $s = Invoke-RestMethod -Uri "http://127.0.0.1:8765/api/items/$($it.id)/schema" -TimeoutSec 5
            if ($s.mode -eq 'typed') { $typed++ } else { $raw++ }
        } catch {
            $errs++
            Write-Fail "Schema fetch failed for $($it.name): $($_.Exception.Message)"
        }
    }
    if ($errs -eq 0) {
        Write-Pass "All $($snippets.Count) Snippets returned a schema ($typed typed, $raw raw)"
    }

    # ===========================================================
    # 3.T5 — Unknown id -> 404
    # ===========================================================
    Write-Host ''
    Write-Host '3.T5 — Unknown id returns 404'

    $r = Invoke-WebRequest -Uri 'http://127.0.0.1:8765/api/items/deadbeef0000/schema' -UseBasicParsing -SkipHttpErrorCheck -TimeoutSec 5
    if ($r.StatusCode -eq 404) { Write-Pass 'Unknown id -> 404' }
    else { Write-Fail "Unknown id -> $($r.StatusCode), expected 404" }

    # Bad id format (not 12 hex) -> falls through to /api/* catch-all (503) per current router
    # We don't strictly assert; just confirm it does NOT 500 or expose any data.
    $r = Invoke-WebRequest -Uri 'http://127.0.0.1:8765/api/items/NOT_HEX/schema' -UseBasicParsing -SkipHttpErrorCheck -TimeoutSec 5
    if ($r.StatusCode -in @(503, 404)) { Write-Pass "Bad id format -> $($r.StatusCode) (acceptable)" }
    else { Write-Fail "Bad id format -> $($r.StatusCode)" }

    # ===========================================================
    # 3.T6 — Middleware regression (Origin still enforced on schema route)
    # ===========================================================
    Write-Host ''
    Write-Host '3.T6 — Middleware regression on schema route'

    $r = Invoke-WebRequest -Uri "http://127.0.0.1:8765/api/items/$($sample.id)/schema" -Headers @{ 'Origin' = 'http://evil.com' } -UseBasicParsing -SkipHttpErrorCheck -TimeoutSec 5
    if ($r.StatusCode -eq 403) {
        Write-Pass "Cross-origin schema fetch -> 403 (Origin enforced)"
    } else {
        Write-Fail "Cross-origin schema fetch -> $($r.StatusCode), expected 403"
    }

    # ===========================================================
    # 3.T7 — Frontend CSRF cookie still set on root
    # ===========================================================
    Write-Host ''
    Write-Host '3.T7 — CSRF cookie bootstrap'

    $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $r = Invoke-WebRequest -Uri 'http://127.0.0.1:8765/' -UseBasicParsing -WebSession $session -TimeoutSec 5
    if ($r.StatusCode -ne 200) { Write-Fail "Root status $($r.StatusCode)" }
    else {
        $cookies = $session.Cookies.GetCookies('http://127.0.0.1:8765/')
        $csrf = $cookies | Where-Object { $_.Name -eq 'hub-csrf' } | Select-Object -First 1
        if ($csrf -and $csrf.Value -match '^[0-9a-f-]+$') {
            Write-Pass "hub-csrf cookie set on root (value len=$($csrf.Value.Length))"
        } else {
            Write-Fail "hub-csrf cookie missing or malformed"
        }
    }

    # ===========================================================
    # 3.T8 — index.html references form template + Alpine
    # ===========================================================
    Write-Host ''
    Write-Host '3.T8 — Frontend resources'

    $html = (Invoke-WebRequest -Uri 'http://127.0.0.1:8765/' -UseBasicParsing -TimeoutSec 5).Content
    if ($html -match 'class="form-pane"' -and $html -match 'x-for="field in schema.fields"') {
        Write-Pass "index.html contains form-pane + field iterator"
    } else {
        Write-Fail "index.html missing form-pane or field iterator"
    }
    if ($html -match 'X-Hub-CSRF') {
        # Note: header injection is in app.js via postJson, not directly in HTML.
        # If HTML doesn't have it but app.js does, that's fine. We only check HTML here.
        Write-Pass "index.html mentions CSRF-related markup"
    } else {
        # Not necessarily a failure — the helper lives in app.js
        Write-Pass "(CSRF header injection lives in app.js postJson helper)"
    }
    $appJs = (Invoke-WebRequest -Uri 'http://127.0.0.1:8765/app.js' -UseBasicParsing -TimeoutSec 5).Content
    if ($appJs -match 'X-Hub-CSRF') {
        Write-Pass "app.js sends X-Hub-CSRF header in postJson helper"
    } else {
        Write-Fail "app.js missing X-Hub-CSRF header"
    }

} catch {
    Write-Fail "Unhandled exception: $($_.Exception.Message)"
} finally {
    Stop-Hub
}

# ===========================================================
# RESULT
# ===========================================================

Write-Host ''
if ($Script:Failures.Count -eq 0) {
    Write-Host 'PASS — all Phase 3 smoke checks succeeded' -ForegroundColor Green
    exit 0
} else {
    Write-Host ('FAIL — ' + $Script:Failures.Count + ' failure(s):') -ForegroundColor Red
    foreach ($f in $Script:Failures) { Write-Host ('  - ' + $f) -ForegroundColor Red }
    exit 1
}
