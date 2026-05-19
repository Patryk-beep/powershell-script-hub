#Requires -Version 5.1
# Phase 4 smoke — job runner + SSE + kill + TTL sweeper + per-line cap +
# -NonInteractive + ValidateSet re-validate + arg-injection safety.

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
$Script:BaseUrl  = 'http://127.0.0.1:8765'

function Write-Step { param([string]$Msg) Write-Host ('  [..] ' + $Msg) -ForegroundColor DarkGray }
function Write-Pass { param([string]$Msg) Write-Host ('  [OK] ' + $Msg) -ForegroundColor Green }
function Write-Fail { param([string]$Msg) Write-Host ('  [FAIL] ' + $Msg) -ForegroundColor Red; $Script:Failures.Add($Msg) }

function Wait-HubReady {
    param([int]$TimeoutSeconds)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $r = Invoke-WebRequest -Uri "$Script:BaseUrl/api/health" -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
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
    $args = @(
        '-NoProfile', '-Sta', '-ExecutionPolicy', 'Bypass',
        '-File', $HubScript,
        '-ExtraScanRoots',  $Script:Fixtures,
        '-FastTtlSeconds',  '3',
        '-FastSweepSeconds','2'
    )
    Start-Process pwsh -ArgumentList $args -PassThru -WindowStyle Hidden
}

function New-HubSession {
    [OutputType([hashtable])]
    param()
    $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    Invoke-WebRequest -Uri "$Script:BaseUrl/" -UseBasicParsing -WebSession $session -TimeoutSec 5 | Out-Null
    $csrf = ($session.Cookies.GetCookies("$Script:BaseUrl/") | Where-Object Name -eq 'hub-csrf' | Select-Object -First 1).Value
    return @{ session = $session; csrf = $csrf }
}

function Invoke-HubRun {
    [OutputType([hashtable])]
    param(
        [string]$ItemId,
        [hashtable]$Values = @{},
        [string]$RawArgs = $null,
        [hashtable]$Ctx
    )
    $body = @{ itemId = $ItemId }
    if ($Values.Count -gt 0) { $body.values = $Values }
    if ($RawArgs) { $body.rawArgs = $RawArgs }
    $json = $body | ConvertTo-Json -Compress -Depth 5
    $headers = @{
        'Origin'     = $Script:BaseUrl
        'X-Hub-CSRF' = $Ctx.csrf
    }
    return Invoke-WebRequest -Uri "$Script:BaseUrl/api/run" -Method POST -Headers $headers `
        -ContentType 'application/json' -Body $json -WebSession $Ctx.session `
        -UseBasicParsing -SkipHttpErrorCheck -TimeoutSec 10
}

function Read-Sse {
    [OutputType([hashtable])]
    param(
        [string]$JobId,
        [int]$TimeoutSeconds = 20,
        [int]$MaxLines = 5000,
        [scriptblock]$StopWhen = $null   # invoked after each event; return $true to stop early
    )
    $events = New-Object 'System.Collections.Generic.List[hashtable]'
    $endEvt = $null
    $url = "$Script:BaseUrl/api/stream/$JobId"

    $req = [System.Net.HttpWebRequest]::Create($url)
    $req.Method = 'GET'
    $req.Headers.Add('Origin', $Script:BaseUrl)
    $req.Accept = 'text/event-stream'
    $req.AllowReadStreamBuffering = $false
    $req.Timeout = 10000   # connect timeout only

    $resp = $null; $stream = $null; $reader = $null; $cts = $null
    try {
        $resp = $req.GetResponse()
        if ([int]$resp.StatusCode -ne 200) {
            return @{ ok = $false; status = [int]$resp.StatusCode; events = $events.ToArray() }
        }
        $stream = $resp.GetResponseStream()
        $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
        $cts    = [System.Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($TimeoutSeconds))

        $currentEvent = $null
        $currentData  = ''
        while ($events.Count -lt $MaxLines) {
            $line = $null
            try {
                $task = $reader.ReadLineAsync($cts.Token)
                $line = $task.GetAwaiter().GetResult()
            } catch [System.OperationCanceledException] {
                break
            } catch {
                break
            }
            if ($null -eq $line) { break }
            if ($line -eq '') {
                if ($null -ne $currentEvent) {
                    $entry = @{ event = $currentEvent; data = $currentData }
                    [void]$events.Add($entry)
                    if ($currentEvent -eq 'end') { $endEvt = $entry; break }
                    if ($StopWhen) {
                        try { if (& $StopWhen $events) { break } } catch { }
                    }
                    $currentEvent = $null
                    $currentData  = ''
                }
            } elseif ($line.StartsWith('event:')) {
                $currentEvent = $line.Substring(6).Trim()
            } elseif ($line.StartsWith('data:')) {
                $currentData = $line.Substring(5).Trim()
            }
        }
    } finally {
        try { if ($cts)    { $cts.Dispose() }    } catch { }
        try { if ($reader) { $reader.Dispose() } } catch { }
        try { if ($stream) { $stream.Dispose() } } catch { }
        try { if ($resp)   { $resp.Close() }     } catch { }
    }
    return @{ ok = $true; events = $events.ToArray(); end = $endEvt }
}

function Get-LineEvents {
    param($Result)
    return @($Result.events | Where-Object { $_.event -eq 'line' })
}

function Test-TickEvent {
    [OutputType([bool])]
    param($Event)
    if ($Event.event -ne 'line') { return $false }
    try {
        $obj = $Event.data | ConvertFrom-Json
        return ($obj.line -match '^tick \d+$')
    } catch { return $false }
}

function Get-Item-Id {
    param($Catalog, [string]$Name)
    return ($Catalog.items | Where-Object { $_.name -eq $Name } | Select-Object -First 1)
}

# === SETUP ===

foreach ($f in @('hub-error.log','hub.port','hub-fixture-executed.flag')) {
    try { [System.IO.File]::Delete((Join-Path $env:TEMP $f)) } catch { }
}

Write-Host ''
Write-Host 'Phase 4 smoke test' -ForegroundColor Cyan
Write-Host ('  Hub source: ' + $HubScript)
Write-Host ('  Fixtures:   ' + $Script:Fixtures)

try {
    $Script:HubProc = Start-HubProcess
    Write-Step ("Started Hub PID $($Script:HubProc.Id) — waiting for /api/health")
    if (-not (Wait-HubReady -TimeoutSeconds $BootTimeoutSeconds)) {
        $logPath = Join-Path $env:TEMP 'hub-error.log'
        $log = if (Test-Path $logPath) { Get-Content -Raw -LiteralPath $logPath } else { '(no error log)' }
        Write-Fail ("Hub did not become healthy. Log:`n$log")
        Stop-Hub
        exit 1
    }
    Write-Pass 'Hub booted'

    $ctx = New-HubSession
    if (-not $ctx.csrf) { Write-Fail 'No CSRF cookie acquired'; throw 'csrf' }
    Write-Pass "Session bootstrap (csrf=$($ctx.csrf.Substring(0,8))...)"

    $catalog = Invoke-RestMethod -Uri "$Script:BaseUrl/api/items" -TimeoutSec 5
    $echo        = Get-Item-Id $catalog 'echo'
    $slow        = Get-Item-Id $catalog 'slow'
    $prompt      = Get-Item-Id $catalog 'prompt'
    $validateset = Get-Item-Id $catalog 'validate-set'
    $longline    = Get-Item-Id $catalog 'long-line'
    $argecho     = Get-Item-Id $catalog 'arg-echo'
    foreach ($pair in @(@{N='echo';V=$echo},@{N='slow';V=$slow},@{N='prompt';V=$prompt},@{N='validate-set';V=$validateset},@{N='long-line';V=$longline},@{N='arg-echo';V=$argecho})) {
        if (-not $pair.V) { Write-Fail "Fixture not discovered: $($pair.N)"; throw 'fixture' }
    }
    Write-Pass "All 6 fixtures discovered"

    # ===========================================================
    # 4.T1 — Echo end-to-end
    # ===========================================================
    Write-Host ''
    Write-Host '4.T1 — Echo end-to-end'

    $r = Invoke-HubRun -ItemId $echo.id -Values @{ Text = 'hello world' } -Ctx $ctx
    if ($r.StatusCode -ne 202) { Write-Fail "echo run -> $($r.StatusCode), body: $($r.Content)" }
    else {
        $jobId = ($r.Content | ConvertFrom-Json).jobId
        $sse = Read-Sse -JobId $jobId -TimeoutSeconds 10
        $lines = Get-LineEvents $sse
        $foundEcho = $lines | Where-Object {
            try { $obj = $_.data | ConvertFrom-Json; $obj.line -match 'got: hello world' } catch { $false }
        }
        if (-not $foundEcho)          { Write-Fail "Echo line not seen. Events: $($sse.events | ConvertTo-Json -Compress)" }
        elseif (-not $sse.end)        { Write-Fail "No end event for echo run" }
        else {
            $endData = $sse.end.data | ConvertFrom-Json
            if ($endData.exitCode -ne 0) { Write-Fail "Echo exitCode=$($endData.exitCode)" }
            else { Write-Pass "Echo line received + end exitCode=0" }
        }
    }

    # ===========================================================
    # 4.T2 — Long-running + kill (no orphan)
    # ===========================================================
    Write-Host ''
    Write-Host '4.T2 — Slow run + kill'

    $r = Invoke-HubRun -ItemId $slow.id -Values @{ Count = 30; DelayMs = 300 } -Ctx $ctx
    if ($r.StatusCode -ne 202) { Write-Fail "slow run -> $($r.StatusCode)" }
    else {
        $jobId = ($r.Content | ConvertFrom-Json).jobId

        # First connection: read until 2 ticks, then disconnect.
        $sse1 = Read-Sse -JobId $jobId -TimeoutSeconds 8 -StopWhen {
            param($ev)
            $tickEvents = @($ev | Where-Object { Test-TickEvent $_ })
            return ($tickEvents.Count -ge 2)
        }
        $ticks = @($sse1.events | Where-Object { Test-TickEvent $_ }).Count
        if ($ticks -lt 2) { Write-Fail "Saw $ticks ticks in 8s, expected >= 2" }
        else { Write-Pass "Saw $ticks ticks before kill" }

        $killHeaders = @{ 'Origin' = $Script:BaseUrl; 'X-Hub-CSRF' = $ctx.csrf }
        $killR = Invoke-WebRequest -Uri "$Script:BaseUrl/api/jobs/$jobId/kill" -Method POST `
            -Headers $killHeaders -ContentType 'application/json' -Body '{}' `
            -WebSession $ctx.session -UseBasicParsing -SkipHttpErrorCheck -TimeoutSec 5
        if ($killR.StatusCode -notin @(204, 200)) { Write-Fail "Kill -> $($killR.StatusCode)" }
        else { Write-Pass "Kill -> $($killR.StatusCode)" }

        # Reconnect: should get buffered events + end frame quickly.
        Start-Sleep -Milliseconds 800
        $sse2 = Read-Sse -JobId $jobId -TimeoutSeconds 5
        if (-not $sse2.end) {
            Write-Fail "Did not see end frame within 5s after kill"
        } else {
            $endData = $sse2.end.data | ConvertFrom-Json
            if ($endData.status -ne 'killed') { Write-Fail "End status='$($endData.status)', expected 'killed'" }
            else { Write-Pass "End frame status=killed received after kill" }
        }
    }

    # ===========================================================
    # 4.T3 — ValidateSet server-side re-validation (ADV-004)
    # ===========================================================
    Write-Host ''
    Write-Host '4.T3 — ValidateSet bypass blocked'

    $r = Invoke-HubRun -ItemId $validateset.id -Values @{ Choice = 'evil-not-in-set' } -Ctx $ctx
    if ($r.StatusCode -eq 400) {
        $errBody = $r.Content | ConvertFrom-Json
        if ($errBody.error -match 'ValidateSet') {
            Write-Pass "ValidateSet bypass -> 400 with explicit error"
        } else {
            Write-Pass "ValidateSet bypass -> 400 (error='$($errBody.error)')"
        }
    } else { Write-Fail "ValidateSet bypass -> $($r.StatusCode) (expected 400)" }

    # Valid value should succeed
    $r = Invoke-HubRun -ItemId $validateset.id -Values @{ Choice = 'beta' } -Ctx $ctx
    if ($r.StatusCode -ne 202) { Write-Fail "Valid ValidateSet -> $($r.StatusCode)" }
    else { Write-Pass "Valid ValidateSet value accepted" }

    # ===========================================================
    # 4.T4 — Argument injection safety (no shell interpretation)
    # ===========================================================
    Write-Host ''
    Write-Host '4.T4 — Argument injection safety'

    $r = Invoke-HubRun -ItemId $echo.id -Values @{ Text = '; whoami' } -Ctx $ctx
    if ($r.StatusCode -ne 202) { Write-Fail "Injection test run -> $($r.StatusCode)" }
    else {
        $jobId = ($r.Content | ConvertFrom-Json).jobId
        $sse = Read-Sse -JobId $jobId -TimeoutSeconds 10
        $lines = Get-LineEvents $sse
        $literal = $lines | Where-Object {
            try { ($_.data | ConvertFrom-Json).line -match 'got: ; whoami' } catch { $false }
        }
        if ($literal) { Write-Pass "Shell metacharacter preserved literally" }
        else { Write-Fail "Did not see 'got: ; whoami' in output (possibly shell interpreted)" }
    }

    # ===========================================================
    # 4.T5 — Read-Host does NOT hang (-NonInteractive + stdin EOF)
    # ===========================================================
    Write-Host ''
    Write-Host '4.T5 — Read-Host fixture does NOT hang'

    $r = Invoke-HubRun -ItemId $prompt.id -Ctx $ctx
    if ($r.StatusCode -ne 202) { Write-Fail "Prompt run -> $($r.StatusCode)" }
    else {
        $jobId = ($r.Content | ConvertFrom-Json).jobId
        $started = Get-Date
        $sse = Read-Sse -JobId $jobId -TimeoutSeconds 10
        $elapsed = ((Get-Date) - $started).TotalSeconds
        if (-not $sse.end) { Write-Fail "Read-Host hung — no end event in 10s" }
        elseif ($elapsed -gt 10) { Write-Fail "Took $([int]$elapsed)s to exit" }
        else { Write-Pass "Process exited within $([int]$elapsed)s (no hang)" }
    }

    # ===========================================================
    # 4.T6 — Per-line cap (ADV-010)
    # ===========================================================
    Write-Host ''
    Write-Host '4.T6 — Per-line cap'

    $r = Invoke-HubRun -ItemId $longline.id -Values @{ Length = 50000 } -Ctx $ctx
    if ($r.StatusCode -ne 202) { Write-Fail "Long-line run -> $($r.StatusCode)" }
    else {
        $jobId = ($r.Content | ConvertFrom-Json).jobId
        $sse = Read-Sse -JobId $jobId -TimeoutSeconds 10
        $lines = Get-LineEvents $sse
        $hit = $false
        foreach ($l in $lines) {
            try {
                $obj = $l.data | ConvertFrom-Json
                if ($obj.line -match '\[\.\.\.truncated\]$' -and $obj.line.Length -le 4200) {
                    $hit = $true; break
                }
            } catch { }
        }
        if ($hit) { Write-Pass "Long line truncated at <=4KB with [...truncated] marker" }
        else { Write-Fail "Did not see truncation marker on 50KB line" }
    }

    # ===========================================================
    # 4.T7 — Reconnect replay (buffer survives close+reopen)
    # ===========================================================
    Write-Host ''
    Write-Host '4.T7 — Reconnect replay'

    $r = Invoke-HubRun -ItemId $slow.id -Values @{ Count = 8; DelayMs = 200 } -Ctx $ctx
    if ($r.StatusCode -ne 202) { Write-Fail "Replay slow run -> $($r.StatusCode)" }
    else {
        $jobId = ($r.Content | ConvertFrom-Json).jobId
        # Wait ~1.5s for at least 3 ticks to populate buffer, then poll SSE fresh.
        Start-Sleep -Milliseconds 1500
        $sse = Read-Sse -JobId $jobId -TimeoutSeconds 5
        $lines = Get-LineEvents $sse
        $tickCount = @($lines | Where-Object { Test-TickEvent $_ }).Count
        if ($tickCount -ge 3) { Write-Pass "Late SSE connection replayed $tickCount buffered ticks" }
        else { Write-Fail "Reconnect saw $tickCount ticks, expected >= 3" }
    }

    # ===========================================================
    # 4.T8 — TTL sweeper drops terminal jobs
    # ===========================================================
    Write-Host ''
    Write-Host '4.T8 — TTL sweeper'

    $r = Invoke-HubRun -ItemId $echo.id -Values @{ Text = 'sweep-test' } -Ctx $ctx
    if ($r.StatusCode -ne 202) { Write-Fail "Sweep test run -> $($r.StatusCode)" }
    else {
        $jobId = ($r.Content | ConvertFrom-Json).jobId
        # Wait for job to terminate
        $sse = Read-Sse -JobId $jobId -TimeoutSeconds 10
        if (-not $sse.end) { Write-Fail "Sweep prep: job never ended"; }
        else {
            # FastTtl=3s, FastSweep=2s — wait > 5s for TTL to elapse + next sweep
            Write-Step "Waiting 7s for TTL sweep…"
            Start-Sleep -Seconds 7
            # Stream same jobId — should now be unknown
            $r2 = Invoke-WebRequest -Uri "$Script:BaseUrl/api/stream/$jobId" `
                -Headers @{ 'Origin' = $Script:BaseUrl } -UseBasicParsing -SkipHttpErrorCheck -TimeoutSec 5
            if ($r2.StatusCode -eq 404) { Write-Pass "Job evicted by TTL sweeper (404 after ~7s)" }
            else { Write-Fail "Job still present after TTL: $($r2.StatusCode)" }
        }
    }

    # ===========================================================
    # 4.T9 — Middleware regression on /api/run + /api/jobs/.../kill
    # ===========================================================
    Write-Host ''
    Write-Host '4.T9 — Middleware regression'

    # No Origin -> 403
    $r2 = Invoke-WebRequest -Uri "$Script:BaseUrl/api/run" -Method POST `
        -ContentType 'application/json' -Body '{"itemId":"abc"}' `
        -UseBasicParsing -SkipHttpErrorCheck -TimeoutSec 5
    if ($r2.StatusCode -eq 403) { Write-Pass "POST /api/run no-Origin -> 403" }
    else { Write-Fail "POST /api/run no-Origin -> $($r2.StatusCode)" }

    # No CSRF header -> 403
    $r3 = Invoke-WebRequest -Uri "$Script:BaseUrl/api/run" -Method POST `
        -Headers @{ 'Origin' = $Script:BaseUrl } -ContentType 'application/json' -Body '{"itemId":"abc"}' `
        -UseBasicParsing -SkipHttpErrorCheck -TimeoutSec 5
    if ($r3.StatusCode -eq 403) { Write-Pass "POST /api/run no-CSRF -> 403" }
    else { Write-Fail "POST /api/run no-CSRF -> $($r3.StatusCode)" }

} catch {
    Write-Fail "Unhandled exception: $($_.Exception.Message)"
} finally {
    Stop-Hub
}

Write-Host ''
if ($Script:Failures.Count -eq 0) {
    Write-Host 'PASS — all Phase 4 smoke checks succeeded' -ForegroundColor Green
    exit 0
} else {
    Write-Host ('FAIL — ' + $Script:Failures.Count + ' failure(s):') -ForegroundColor Red
    foreach ($f in $Script:Failures) { Write-Host ('  - ' + $f) -ForegroundColor Red }
    exit 1
}
