#Requires -Version 5.1
# smoke-phase2-engine.ps1 — Phase 2 execution engine smoke.
# Tests: run trigger, state polling, kill, interrupted recovery, 404s.

[CmdletBinding()]
param(
    [string]$HubScript = (Join-Path (Split-Path -Parent $PSScriptRoot) 'Hub.ps1'),
    [int]$BootTimeoutSeconds = 15,
    [int]$RunTimeoutSeconds  = 20
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:Failures = New-Object 'System.Collections.Generic.List[string]'
$Script:HubProc  = $null
$Script:Fixtures = Join-Path $PSScriptRoot 'fixtures'
$Script:HubPort  = 8765
$Script:BaseUrl  = "http://127.0.0.1:$Script:HubPort"
$Script:CfgDir   = Join-Path $env:LOCALAPPDATA 'Hub'
$Script:RunsDir  = Join-Path $Script:CfgDir 'workflow-runs'

function Write-Pass { param([string]$M) Write-Host ('  [OK] '   + $M) -ForegroundColor Green }
function Write-Fail { param([string]$M) Write-Host ('  [FAIL] ' + $M) -ForegroundColor Red; $Script:Failures.Add($M) }
function Write-Step { param([string]$M) Write-Host ('  [..] '   + $M) -ForegroundColor DarkGray }

function Stop-Hub {
    if ($Script:HubProc -and -not $Script:HubProc.HasExited) {
        & taskkill.exe /T /F /PID $Script:HubProc.Id 2>$null | Out-Null
    }
    $Script:HubProc = $null
    Start-Sleep -Milliseconds 600
}

function Start-HubProcess {
    param([string[]]$ExtraArgs = @())
    Stop-Hub
    $extra = if ($ExtraArgs) { ' ' + ($ExtraArgs -join ' ') } else { '' }
    $Script:HubProc = Start-Process pwsh `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$HubScript`" -ExtraScanRoots `"$Script:Fixtures`"$extra" `
        -PassThru -WindowStyle Hidden
    $deadline = (Get-Date).AddSeconds($BootTimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $r = Invoke-WebRequest "$Script:BaseUrl/api/health" -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
            if ($r.StatusCode -eq 200) { return }
        } catch { Start-Sleep -Milliseconds 300 }
    }
    throw 'Hub did not boot within timeout'
}

function New-HubSession {
    $session = $null
    $null = Invoke-WebRequest "$Script:BaseUrl/" -UseBasicParsing -SessionVariable session -TimeoutSec 5
    $cookie = ($session.Cookies.GetCookies("$Script:BaseUrl") | Where-Object Name -eq 'hub-csrf').Value
    return @{ Session = $session; Csrf = $cookie }
}

function Invoke-Api {
    param([string]$Method, [string]$Path, $Body = $null, [hashtable]$Sess = $null)
    $headers = @{ 'Content-Type' = 'application/json' }
    if ($Sess) {
        $headers['Origin']     = $Script:BaseUrl
        $headers['X-Hub-CSRF'] = $Sess.Csrf
    }
    $payload = if ($Body) { $Body | ConvertTo-Json -Depth 10 -Compress } else { $null }
    $params  = @{
        Uri              = "$Script:BaseUrl$Path"
        Method           = $Method
        Headers          = $headers
        UseBasicParsing  = $true
        TimeoutSec       = 10
        SkipHttpErrorCheck = $true
    }
    if ($payload) { $params['Body'] = $payload }
    if ($Sess)    { $params['WebSession'] = $Sess.Session }
    $r = Invoke-WebRequest @params
    $obj = $null
    try { $obj = $r.Content | ConvertFrom-Json } catch { }
    return @{ Status = [int]$r.StatusCode; Body = $obj; Raw = $r.Content }
}

function Wait-RunComplete {
    param([string]$RunId, [int]$TimeoutSec)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $r = Invoke-Api -Method GET -Path "/api/workflow-runs/$RunId"
        if ($r.Status -eq 200 -and $r.Body.status -ne 'running') {
            return $r.Body
        }
        Start-Sleep -Milliseconds 300
    }
    return $null
}

function Get-ItemPath {
    param([string]$Name)
    $r = Invoke-RestMethod "$Script:BaseUrl/api/items" -TimeoutSec 5
    $item = @($r.items | Where-Object { $_.name -eq $Name }) | Select-Object -First 1
    return $(if ($item) { $item.path } else { $null })
}

# ─────────────────────────────────────────────────────────────────────────────
Write-Host ''
Write-Host 'smoke-phase2-engine — execution engine' -ForegroundColor Cyan

try {
    Start-HubProcess
    Write-Pass 'Hub booted'

    $sess = New-HubSession
    $echoPath   = Get-ItemPath 'echo'
    $noParamPath = Get-ItemPath 'no-param'
    $slowPath   = Get-ItemPath 'slow'

    if (-not $echoPath)    { Write-Fail 'fixture echo.ps1 not in catalog';    Stop-Hub; exit 1 }
    if (-not $noParamPath) { Write-Fail 'fixture no-param.ps1 not in catalog'; Stop-Hub; exit 1 }
    if (-not $slowPath)    { Write-Fail 'fixture slow.ps1 not in catalog';     Stop-Hub; exit 1 }
    Write-Pass "Fixtures in catalog (echo=$echoPath)"

    # ── Case 1: create + trigger a 2-step workflow ──────────────────────────
    $wfBody = @{
        name  = 'smoke-two-step'
        steps = @(
            @{ id = 's1'; scriptId = $echoPath;    params = @{ Text = 'from-step1' } }
            @{ id = 's2'; scriptId = $noParamPath; params = @{} }
        )
    }
    $r = Invoke-Api -Method POST -Path '/api/workflows' -Body $wfBody -Sess $sess
    if ($r.Status -ne 200) { Write-Fail "Case 1a: create workflow expected 200, got $($r.Status)"; Stop-Hub; exit 1 }
    $wfId = $r.Body.id
    Write-Pass "Case 1a: workflow created ($wfId)"

    $r = Invoke-Api -Method POST -Path "/api/workflows/$wfId/run" -Body @{} -Sess $sess
    if ($r.Status -ne 202) { Write-Fail "Case 1b: trigger expected 202, got $($r.Status)" }
    else {
        $runId = $r.Body.runId
        Write-Pass "Case 1b: run triggered ($runId)"

        $run = Wait-RunComplete -RunId $runId -TimeoutSec $RunTimeoutSeconds
        if (-not $run)                   { Write-Fail 'Case 1c: run did not complete within timeout' }
        elseif ($run.status -ne 'done')  { Write-Fail "Case 1c: expected status=done, got $($run.status)" }
        elseif (-not $run.stepOutputs)   { Write-Fail 'Case 1c: stepOutputs missing' }
        else {
            Write-Pass "Case 1c: run completed (status=$($run.status))"
            # Verify step outputs captured.
            $s1out = $run.stepOutputs.s1
            if ($s1out -and $s1out.stdout -match 'from-step1') {
                Write-Pass 'Case 1d: step stdout captured'
            } else {
                Write-Fail "Case 1d: s1 stdout expected 'from-step1', got '$($s1out.stdout)'"
            }
        }
    }

    # ── Case 2: run GET endpoint ─────────────────────────────────────────────
    $r = Invoke-Api -Method GET -Path "/api/workflow-runs/$runId"
    if ($r.Status -eq 200 -and $r.Body.runId -eq $runId) { Write-Pass 'Case 2: GET run returns run record' }
    else { Write-Fail "Case 2: GET run expected 200+runId, got $($r.Status)" }

    # ── Case 3: subscribers/pathMap not leaked ───────────────────────────────
    $leaked = $r.Raw -match '"subscribers"' -or $r.Raw -match '"pathMap"'
    if (-not $leaked) { Write-Pass 'Case 3: subscribers/pathMap not in GET response' }
    else { Write-Fail 'Case 3: subscribers or pathMap leaked into run GET response' }

    # ── Case 4: 404 on unknown run ───────────────────────────────────────────
    $r = Invoke-Api -Method GET -Path '/api/workflow-runs/run-does-not-exist'
    if ($r.Status -eq 404) { Write-Pass 'Case 4: unknown runId returns 404' }
    else { Write-Fail "Case 4: expected 404, got $($r.Status)" }

    # ── Case 5: kill a running workflow ──────────────────────────────────────
    $wfSlow = @{
        name  = 'smoke-slow'
        steps = @(
            @{ id = 's1'; scriptId = $slowPath; params = @{} }
        )
    }
    $r = Invoke-Api -Method POST -Path '/api/workflows' -Body $wfSlow -Sess $sess
    if ($r.Status -ne 200) { Write-Fail "Case 5a: create slow workflow expected 200, got $($r.Status)" }
    else {
        $slowWfId = $r.Body.id
        $r2 = Invoke-Api -Method POST -Path "/api/workflows/$slowWfId/run" -Body @{} -Sess $sess
        if ($r2.Status -ne 202) { Write-Fail "Case 5b: trigger slow run expected 202, got $($r2.Status)" }
        else {
            $slowRunId = $r2.Body.runId
            Start-Sleep -Milliseconds 400
            $r3 = Invoke-Api -Method POST -Path "/api/workflow-runs/$slowRunId/kill" -Body @{} -Sess $sess
            if ($r3.Status -ne 200 -or -not $r3.Body.ok) {
                Write-Fail "Case 5c: kill expected 200+ok, got $($r3.Status)"
            } else {
                $killed = Wait-RunComplete -RunId $slowRunId -TimeoutSec 5
                if ($killed -and $killed.status -eq 'killed') { Write-Pass 'Case 5: kill terminates run (status=killed)' }
                else { Write-Fail "Case 5: expected status=killed, got $($killed.status)" }
            }
        }
    }

    # ── Case 6: SSE endpoint on completed run ────────────────────────────────
    $r = Invoke-WebRequest "$Script:BaseUrl/api/workflow-runs/$runId/stream" `
        -UseBasicParsing -TimeoutSec 5 -SkipHttpErrorCheck
    if ([int]$r.StatusCode -eq 200 -and $r.Headers['Content-Type'] -match 'text/event-stream') {
        if ($r.Content -match 'event: end') { Write-Pass 'Case 6: completed run stream returns end event' }
        else { Write-Fail "Case 6: stream content missing 'event: end'" }
    } else {
        Write-Fail "Case 6: expected 200 text/event-stream, got $($r.StatusCode) $($r.Headers['Content-Type'])"
    }

    # ── Case 7: interrupted recovery — run record marked interrupted on restart ─
    Stop-Hub
    $runFile = Join-Path $Script:RunsDir "$runId.json"
    if (Test-Path $runFile) {
        $data = Get-Content $runFile -Raw | ConvertFrom-Json
        if ($data.status -ne 'done') { Write-Fail "Case 7 pre: expected persisted status=done, got $($data.status)" }
    }
    # Inject a fake in-progress run record.
    $fakeId = 'run-smoke-interrupted-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $fake   = @{ runId = $fakeId; workflowId = 'wf-fake'; status = 'running'; currentStepId = 's1'; stepOutputs = @{}; startedAt = (Get-Date).ToString('o') }
    [System.IO.File]::WriteAllText(
        (Join-Path $Script:RunsDir "$fakeId.json"),
        ($fake | ConvertTo-Json -Depth 5 -Compress),
        [System.Text.UTF8Encoding]::new($false))

    Start-HubProcess
    Start-Sleep -Milliseconds 500
    $r = Invoke-Api -Method GET -Path "/api/workflow-runs/$fakeId"
    if ($r.Status -eq 200 -and $r.Body.status -eq 'interrupted') {
        Write-Pass 'Case 7: in-progress run marked interrupted on restart'
    } else {
        Write-Fail "Case 7: expected status=interrupted, got $($r.Status)/$($r.Body.status)"
    }

} finally {
    Stop-Hub
    # Clean up injected fake run file
    try {
        $fakeFiles = Get-ChildItem -Path $Script:RunsDir -Filter 'run-smoke-interrupted-*.json' -ErrorAction SilentlyContinue
        foreach ($f in $fakeFiles) { Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue }
    } catch { }
}

Write-Host ''
if ($Script:Failures.Count -eq 0) {
    Write-Host 'smoke-phase2-engine PASS' -ForegroundColor Green
    exit 0
} else {
    Write-Host ("smoke-phase2-engine FAIL ({0} issue(s)):" -f $Script:Failures.Count) -ForegroundColor Red
    foreach ($f in $Script:Failures) { Write-Host "  - $f" -ForegroundColor Red }
    exit 1
}
