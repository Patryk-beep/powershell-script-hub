#Requires -Version 5.1
# Phase 1 smoke test — runs all 4 scenarios from plan-script-hub-phase1.md.
# Exit 0 = all pass; non-zero = first failure (with detail).

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

function Send-RawHttp {
    [CmdletBinding()]
    param(
        [string]$RequestLine,             # e.g. 'GET /api/health HTTP/1.1'
        [hashtable]$Headers = @{},
        [string]$Body = '',
        [int]$Port = 8765,
        [string]$RemoteHost = '127.0.0.1'
    )
    if (-not $Headers.ContainsKey('Host')) { $Headers['Host'] = "$RemoteHost`:$Port" }
    if (-not $Headers.ContainsKey('Connection')) { $Headers['Connection'] = 'close' }
    if ($Body.Length -gt 0 -and -not $Headers.ContainsKey('Content-Length')) {
        $Headers['Content-Length'] = [System.Text.Encoding]::UTF8.GetByteCount($Body)
    }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append($RequestLine + "`r`n")
    foreach ($k in $Headers.Keys) { [void]$sb.Append(("{0}: {1}`r`n" -f $k, $Headers[$k])) }
    [void]$sb.Append("`r`n")
    [void]$sb.Append($Body)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $client.Connect($RemoteHost, $Port)
        $stream = $client.GetStream()
        $bytes  = [System.Text.Encoding]::UTF8.GetBytes($sb.ToString())
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
        $ms = New-Object System.IO.MemoryStream
        $buf = New-Object byte[] 8192
        while (($n = $stream.Read($buf, 0, $buf.Length)) -gt 0) { $ms.Write($buf, 0, $n) }
        $text = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
        $parts  = $text -split "`r`n`r`n", 2
        $head   = $parts[0]
        $body   = if ($parts.Count -gt 1) { $parts[1] } else { '' }
        $status = -1
        if ($head -match '^HTTP/[\d.]+ (\d{3})') { $status = [int]$matches[1] }
        return [pscustomobject]@{ Status = $status; Head = $head; Body = $body }
    } finally {
        try { $client.Close() } catch { }
    }
}

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
    $proc = Start-Process pwsh -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$HubScript`"" -PassThru -WindowStyle Hidden
    return $proc
}

# === SETUP ===

if (-not (Test-Path -LiteralPath $HubScript)) {
    Write-Host ("Hub.ps1 not found at $HubScript") -ForegroundColor Red
    exit 2
}

foreach ($f in @('hub-error.log','hub.port','hub-stdout.txt','hub-stderr.txt')) {
    $path = Join-Path $env:TEMP $f
    try { [System.IO.File]::Delete($path) } catch { }
}

Write-Host ''
Write-Host 'Phase 1 smoke test' -ForegroundColor Cyan
Write-Host ('  Hub source: ' + $HubScript)

try {
    $Script:HubProc = Start-HubProcess
    Write-Step ("Started Hub PID $($Script:HubProc.Id) — waiting for /api/health")
    if (-not (Wait-HubReady -TimeoutSeconds $BootTimeoutSeconds)) {
        $logPath = Join-Path $env:TEMP 'hub-error.log'
        $log = if (Test-Path $logPath) { Get-Content -Raw -LiteralPath $logPath } else { '(no error log)' }
        Write-Fail ("Hub did not become healthy within $BootTimeoutSeconds s. Log:`n$log")
        Stop-Hub
        Write-Host ''
        Write-Host 'FAIL — Hub failed to boot' -ForegroundColor Red
        exit 1
    }
    Write-Pass 'Hub booted and /api/health 200'

    # ===========================================================
    # 1.T1 — Boot + static + health
    # ===========================================================
    Write-Host ''
    Write-Host '1.T1 — Boot + static + health'

    $r = Invoke-WebRequest -Uri 'http://127.0.0.1:8765/' -UseBasicParsing -TimeoutSec 5
    if ($r.StatusCode -ne 200) { Write-Fail "Root status was $($r.StatusCode), expected 200" }
    elseif ($r.Content -notmatch 'Loading catalog') { Write-Fail "Root body missing loading placeholder 'Loading catalog'" }
    else { Write-Pass "GET / returned 200 with expected content" }

    $r = Invoke-WebRequest -Uri 'http://127.0.0.1:8765/app.js' -UseBasicParsing -TimeoutSec 5
    if ($r.StatusCode -ne 200) { Write-Fail "/app.js status $($r.StatusCode)" }
    elseif ($r.Headers['Content-Type'] -notmatch 'application/javascript') {
        Write-Fail "/app.js content-type was '$($r.Headers['Content-Type'])'"
    } else { Write-Pass "/app.js 200 with correct MIME" }

    $health = Invoke-RestMethod -Uri 'http://127.0.0.1:8765/api/health' -TimeoutSec 5
    if ($health.status -ne 'ok') { Write-Fail "/api/health status was '$($health.status)', expected 'ok'" }
    elseif ($health.port -ne 8765) { Write-Fail "/api/health port was $($health.port), expected 8765" }
    elseif (-not $health.listenerHealthy) { Write-Fail "/api/health listenerHealthy was false" }
    else { Write-Pass "/api/health JSON shape correct (status=ok, port=8765, jobs=$($health.jobs))" }

    # Verify CSRF cookie was set on root
    $rootHead = (Send-RawHttp -RequestLine 'GET / HTTP/1.1' -Headers @{ Host = 'localhost:8765' }).Head
    if ($rootHead -match 'Set-Cookie:\s*hub-csrf=[0-9a-f-]+;.*SameSite=Strict') {
        Write-Pass 'CSRF cookie set on root with SameSite=Strict'
    } else {
        Write-Fail "CSRF cookie not properly set on root. Headers:`n$rootHead"
    }

    # ===========================================================
    # 1.T2 — Path-traversal guard
    # ===========================================================
    Write-Host ''
    Write-Host '1.T2 — Path-traversal guard'

    $resp = Send-RawHttp -RequestLine 'GET /../Hub.ps1 HTTP/1.1'
    if ($resp.Status -ge 400 -and $resp.Status -lt 500) {
        Write-Pass "GET /../Hub.ps1 -> $($resp.Status) (rejected)"
    } else { Write-Fail "GET /../Hub.ps1 -> $($resp.Status), expected 4xx" }

    $resp = Send-RawHttp -RequestLine 'GET /..%2FHub.ps1 HTTP/1.1'
    if ($resp.Status -ge 400 -and $resp.Status -lt 500) {
        Write-Pass "GET /..%2FHub.ps1 -> $($resp.Status) (rejected)"
    } else { Write-Fail "GET /..%2FHub.ps1 -> $($resp.Status), expected 4xx" }

    # Confirm Hub.ps1 actually exists in the repo (so the test is meaningful)
    if (-not (Test-Path -LiteralPath $HubScript)) {
        Write-Fail "Sanity: Hub.ps1 missing — traversal test is meaningless"
    }

    # ===========================================================
    # 1.T3 — Mutex single-instance
    # ===========================================================
    Write-Host ''
    Write-Host '1.T3 — Mutex single-instance'

    $second = Start-HubProcess
    $exited = $second.WaitForExit(5000)
    if (-not $exited) {
        & taskkill.exe /T /F /PID $second.Id 2>$null | Out-Null
        Write-Fail "Second Hub instance did not exit within 5 s (mutex check failed)"
    } elseif ($second.ExitCode -ne 0) {
        Write-Fail "Second Hub exited with code $($second.ExitCode), expected 0"
    } else {
        Write-Pass "Second Hub exited cleanly (mutex held by first instance)"
    }
    # Confirm first instance still healthy
    try {
        $h = Invoke-RestMethod -Uri 'http://127.0.0.1:8765/api/health' -TimeoutSec 3
        if ($h.status -eq 'ok') { Write-Pass "First Hub still healthy after duplicate launch" }
        else { Write-Fail "First Hub status after duplicate launch: $($h.status)" }
    } catch { Write-Fail "First Hub no longer responding after duplicate launch: $($_.Exception.Message)" }

    # ===========================================================
    # 1.T4 — CSRF / Origin / Host / Content-Type middleware
    # ===========================================================
    Write-Host ''
    Write-Host '1.T4 — Security middleware'

    # (a) POST with no Origin -> 403 origin
    $r = Send-RawHttp -RequestLine 'POST /api/run HTTP/1.1' -Headers @{ 'Content-Type'='application/json' } -Body '{"x":1}'
    if ($r.Status -eq 403 -and $r.Body -match 'origin') { Write-Pass "POST without Origin -> 403 origin" }
    else { Write-Fail "POST without Origin -> $($r.Status). Body: $($r.Body)" }

    # (b) POST with bad Origin -> 403 origin
    $r = Send-RawHttp -RequestLine 'POST /api/run HTTP/1.1' -Headers @{ 'Origin'='http://evil.com'; 'Content-Type'='application/json' } -Body '{"x":1}'
    if ($r.Status -eq 403 -and $r.Body -match 'origin') { Write-Pass "POST with evil Origin -> 403 origin" }
    else { Write-Fail "POST with evil Origin -> $($r.Status). Body: $($r.Body)" }

    # (c) POST with bad Host -> 421 host
    $r = Send-RawHttp -RequestLine 'POST /api/run HTTP/1.1' -Headers @{ 'Origin'='http://127.0.0.1:8765'; 'Host'='evil.com'; 'Content-Type'='application/json' } -Body '{"x":1}'
    if ($r.Status -eq 421 -and $r.Body -match 'host') { Write-Pass "POST with bad Host -> 421 host" }
    else { Write-Fail "POST with bad Host -> $($r.Status). Body: $($r.Body)" }

    # (d) POST with wrong Content-Type -> 415
    $r = Send-RawHttp -RequestLine 'POST /api/run HTTP/1.1' -Headers @{ 'Origin'='http://127.0.0.1:8765'; 'Content-Type'='text/plain' } -Body '{"x":1}'
    if ($r.Status -eq 415 -and $r.Body -match 'content-type') { Write-Pass "POST with text/plain -> 415 content-type" }
    else { Write-Fail "POST with text/plain -> $($r.Status). Body: $($r.Body)" }

    # (e) POST without CSRF header -> 403 csrf
    $r = Send-RawHttp -RequestLine 'POST /api/run HTTP/1.1' -Headers @{ 'Origin'='http://127.0.0.1:8765'; 'Content-Type'='application/json'; 'Cookie'='hub-csrf=abc' } -Body '{"x":1}'
    if ($r.Status -eq 403 -and $r.Body -match 'csrf') { Write-Pass "POST without X-Hub-CSRF -> 403 csrf" }
    else { Write-Fail "POST without X-Hub-CSRF -> $($r.Status). Body: $($r.Body)" }

    # (f) POST with mismatched CSRF -> 403 csrf
    $r = Send-RawHttp -RequestLine 'POST /api/run HTTP/1.1' -Headers @{ 'Origin'='http://127.0.0.1:8765'; 'Content-Type'='application/json'; 'Cookie'='hub-csrf=abc'; 'X-Hub-CSRF'='different' } -Body '{"x":1}'
    if ($r.Status -eq 403 -and $r.Body -match 'csrf') { Write-Pass "POST with mismatched CSRF -> 403 csrf" }
    else { Write-Fail "POST with mismatched CSRF -> $($r.Status). Body: $($r.Body)" }

    # (g) GET /api/items with valid Origin passes middleware (returns 200 + JSON since P2 shipped — assertion updated post-P2).
    $r = Send-RawHttp -RequestLine 'GET /api/items HTTP/1.1' -Headers @{ 'Origin'='http://127.0.0.1:8765' }
    if ($r.Status -eq 200 -and $r.Body -match '"items"') { Write-Pass "GET /api/items passes middleware (200 + JSON)" }
    else { Write-Fail "GET /api/items -> $($r.Status). Body excerpt: $(($r.Body)[0..120] -join '')" }

} finally {
    Stop-Hub
}

# ===========================================================
# RESULT
# ===========================================================

Write-Host ''
if ($Script:Failures.Count -eq 0) {
    Write-Host ('PASS — all Phase 1 smoke checks succeeded') -ForegroundColor Green
    exit 0
} else {
    Write-Host ('FAIL — ' + $Script:Failures.Count + ' failure(s):') -ForegroundColor Red
    foreach ($f in $Script:Failures) { Write-Host ('  - ' + $f) -ForegroundColor Red }
    exit 1
}
