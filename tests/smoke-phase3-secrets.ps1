#Requires -Version 5.1
# smoke-phase3-secrets.ps1 — Phase 3 secrets vault. Runs beside a live Hub.exe via
# -SkipMutex + sandboxed LOCALAPPDATA/TEMP so it never touches the real DPAPI vault.
# Asserts HTTP STATUS codes (the primary contract) plus the leak greps that are the only
# real proof: encrypt-at-rest, no-argv-leak (Win32_Process.CommandLine), no-history-leak,
# ADV-301 (downstream stdout drop), ADV-302 (exit-code propagation).

[CmdletBinding()]
param(
    [string]$HubScript = (Join-Path (Split-Path -Parent $PSScriptRoot) 'Hub.ps1'),
    [int]$Port = 8801,
    [int]$BootTimeoutSeconds = 15,
    [int]$RunTimeoutSeconds = 25
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Test isolation (sandbox TEMP + LOCALAPPDATA before deriving paths) ---
$Script:OrigTemp         = $env:TEMP
$Script:OrigTmp          = $env:TMP
$Script:OrigLocalAppData = $env:LOCALAPPDATA
$Script:Sandbox = Join-Path $Script:OrigTemp ('hub-smoke-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
[System.IO.Directory]::CreateDirectory($Script:Sandbox) | Out-Null
$env:TEMP         = $Script:Sandbox
$env:TMP          = $Script:Sandbox
$env:LOCALAPPDATA = $Script:Sandbox

$Script:Failures   = New-Object 'System.Collections.Generic.List[string]'
$Script:HubProc    = $null
$Script:Fixtures   = Join-Path $PSScriptRoot 'fixtures'
$Script:HubPort    = $Port
$Script:BaseUrl    = "http://127.0.0.1:$Script:HubPort"
$Script:HubDir     = Join-Path $env:LOCALAPPDATA 'Hub'
$Script:SecretsDir = Join-Path $Script:HubDir 'secrets'
$Script:RunsJsonl  = Join-Path (Join-Path $Script:HubDir 'history') 'runs.jsonl'
$Script:ErrLog     = Join-Path $env:TEMP 'hub-error.log'
$Script:ProofFile  = Join-Path $Script:HubDir 'secret-proof.txt'   # fixtures write binding proof here

function Write-Pass { param([string]$M) Write-Host ('  [OK] '   + $M) -ForegroundColor Green }
function Write-Fail { param([string]$M) Write-Host ('  [FAIL] ' + $M) -ForegroundColor Red; $Script:Failures.Add($M) }

function Get-Sha256Hex { param([string]$S)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $hex = [System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($S))).Replace('-', '')
    $sha.Dispose(); return $hex
}

function Stop-Hub {
    if ($Script:HubProc -and -not $Script:HubProc.HasExited) {
        & taskkill.exe /T /F /PID $Script:HubProc.Id 2>$null | Out-Null
    }
    $Script:HubProc = $null; Start-Sleep -Milliseconds 600
}

function Start-HubProcess {
    Stop-Hub
    $Script:HubProc = Start-Process pwsh `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$HubScript`" -ExtraScanRoots `"$Script:Fixtures`" -SkipMutex -Port $Script:HubPort" `
        -PassThru -WindowStyle Hidden
    $deadline = (Get-Date).AddSeconds($BootTimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try { $r = Invoke-WebRequest "$Script:BaseUrl/api/health" -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop; if ($r.StatusCode -eq 200) { return } }
        catch { Start-Sleep -Milliseconds 300 }
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
    param([string]$Method, [string]$Path, $Body = $null, [hashtable]$Sess = $null, [switch]$NoCsrf)
    $headers = @{ 'Content-Type' = 'application/json' }
    if ($Sess) {
        $headers['Origin'] = $Script:BaseUrl
        if (-not $NoCsrf) { $headers['X-Hub-CSRF'] = $Sess.Csrf }
    }
    $payload = if ($Body) { $Body | ConvertTo-Json -Depth 10 -Compress } else { $null }
    $params  = @{ Uri = "$Script:BaseUrl$Path"; Method = $Method; Headers = $headers; UseBasicParsing = $true; TimeoutSec = 10; SkipHttpErrorCheck = $true }
    if ($payload) { $params['Body'] = $payload }
    if ($Sess)    { $params['WebSession'] = $Sess.Session }
    $r = Invoke-WebRequest @params
    $obj = $null
    try { $obj = $r.Content | ConvertFrom-Json } catch { }
    return @{ Status = [int]$r.StatusCode; Body = $obj; Raw = $r.Content }
}

function Get-ItemPath { param([string]$Name)
    $r = Invoke-RestMethod "$Script:BaseUrl/api/items" -TimeoutSec 5
    $item = @($r.items | Where-Object { $_.name -eq $Name }) | Select-Object -First 1
    return $(if ($item) { $item.path } else { $null })
}

function Get-PwshCmdLines {
    return @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.CommandLine } | Where-Object { $_ })
}

function Wait-RunComplete { param([string]$RunId, [int]$TimeoutSec, $CmdLineSink = $null)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if ($null -ne $CmdLineSink) { foreach ($cl in (Get-PwshCmdLines)) { [void]$CmdLineSink.Value.Add($cl) } }
        $r = Invoke-Api -Method GET -Path "/api/workflow-runs/$RunId"
        if ($r.Status -eq 200 -and $r.Body -and $r.Body.status -and $r.Body.status -ne 'running') { return $r }
        Start-Sleep -Milliseconds 350
    }
    return $null
}

Write-Host ''
Write-Host 'smoke-phase3-secrets — DPAPI vault + stdin injection + ADV-301/302' -ForegroundColor Cyan

try {
    Start-HubProcess
    Write-Pass 'Hub booted (secrets routes resolve)'
    $sess = New-HubSession

    $consumerPath = Get-ItemPath 'secret-consumer'
    $slowPath     = Get-ItemPath 'secret-slow'
    $echoPath     = Get-ItemPath 'secret-echo'
    $exit3Path    = Get-ItemPath 'secret-exit3'
    $credPath     = Get-ItemPath 'secret-cred'
    $argSlowPath  = Get-ItemPath 'arg-slow'
    foreach ($p in @(@{n='secret-consumer';v=$consumerPath}, @{n='secret-slow';v=$slowPath}, @{n='secret-echo';v=$echoPath}, @{n='secret-exit3';v=$exit3Path}, @{n='secret-cred';v=$credPath}, @{n='arg-slow';v=$argSlowPath})) {
        if (-not $p.v) { Write-Fail "fixture $($p.n) not in catalog"; throw 'fixture missing' }
    }
    Write-Pass 'phase-3 fixtures present in catalog'

    # ── CRUD + storage ───────────────────────────────────────────────────────
    $SECRET = 'CANARY-PLAINTEXT-7f3ab19c-DO-NOT-LEAK'
    $r = Invoke-Api -Method POST -Path '/api/secrets' -Body @{ name = 'cipw'; kind = 'password'; value = $SECRET } -Sess $sess
    if ($r.Status -eq 200) { Write-Pass 'POST /api/secrets → 200' } else { Write-Fail "POST /api/secrets → $($r.Status)" }
    if ($r.Raw -notmatch 'CANARY-PLAINTEXT' -and ($r.Body -and -not ($r.Body.PSObject.Properties.Name -contains 'value'))) { Write-Pass 'POST response carries no value' } else { Write-Fail 'POST response leaked value' }

    # Encrypt-at-rest: read the .secret.json off disk; plaintext must be absent.
    Start-Sleep -Milliseconds 200
    $files = @(Get-ChildItem -Path $Script:SecretsDir -Filter '*.secret.json' -ErrorAction SilentlyContinue)
    if ($files.Count -ge 1) {
        $disk = Get-Content -Raw -Path $files[0].FullName
        if ($disk -notmatch 'CANARY-PLAINTEXT' -and $disk -match '"ciphertext"') { Write-Pass 'encrypt-at-rest: plaintext absent, ciphertext present on disk' }
        else { Write-Fail 'encrypt-at-rest: plaintext present on disk OR no ciphertext' }
    } else { Write-Fail "no .secret.json written to $Script:SecretsDir" }

    # Write-only GET list (metadata only, never value/ciphertext).
    $r = Invoke-Api -Method GET -Path '/api/secrets' -Sess $sess
    if ($r.Status -eq 200 -and @($r.Body | Where-Object { $_.name -eq 'cipw' }).Count -eq 1) { Write-Pass 'GET /api/secrets → 200, lists name' } else { Write-Fail "GET /api/secrets → $($r.Status)" }
    if ($r.Raw -notmatch 'CANARY-PLAINTEXT' -and $r.Raw -notmatch 'ciphertext') { Write-Pass 'GET list contains no value/ciphertext' } else { Write-Fail 'GET list leaked value/ciphertext' }

    # No single-secret GET path that could return a value.
    $r = Invoke-Api -Method GET -Path '/api/secrets/cipw' -Sess $sess
    if ($r.Status -eq 405) { Write-Pass 'GET /api/secrets/<name> → 405 (no value-returning GET)' } else { Write-Fail "GET single secret → $($r.Status) (expected 405)" }

    # Duplicate name → 409 (case-insensitive).
    $r = Invoke-Api -Method POST -Path '/api/secrets' -Body @{ name = 'CIPW'; kind = 'password'; value = 'x' } -Sess $sess
    if ($r.Status -eq 409) { Write-Pass 'duplicate name (case-insensitive) → 409' } else { Write-Fail "duplicate → $($r.Status) (expected 409)" }

    # Name validation → 422.
    foreach ($bad in @('..\evil', '', ('a' * 70), 'has/slash')) {
        $r = Invoke-Api -Method POST -Path '/api/secrets' -Body @{ name = $bad; kind = 'password'; value = 'x' } -Sess $sess
        if ($r.Status -eq 422) { Write-Pass "bad name rejected → 422 ($([math]::Min($bad.Length,8)) chars)" } else { Write-Fail "bad name '$bad' → $($r.Status) (expected 422)" }
    }

    # 64KB cap (ADV-304) → 413.
    $r = Invoke-Api -Method POST -Path '/api/secrets' -Body @{ name = 'toobig'; kind = 'password'; value = ('z' * 70000) } -Sess $sess
    if ($r.Status -eq 413) { Write-Pass 'value > 64KB → 413 (ADV-304)' } else { Write-Fail "oversize value → $($r.Status) (expected 413)" }

    # CSRF gate: POST without header (FRESH session) → 403.
    $sessNoCsrf = New-HubSession
    $r = Invoke-Api -Method POST -Path '/api/secrets' -Body @{ name = 'nocsrf'; kind = 'password'; value = 'x' } -Sess $sessNoCsrf -NoCsrf
    if ($r.Status -eq 403) { Write-Pass 'POST without CSRF → 403' } else { Write-Fail "POST without CSRF → $($r.Status) (expected 403)" }

    # ── No-argv-leak + no-history-leak via /api/run (secret-slow) ─────────────
    $LEAK = 'LEAKRUN-CANARY-3d9e21'
    $r = Invoke-Api -Method POST -Path '/api/secrets' -Body @{ name = 'leakpw'; kind = 'password'; value = $LEAK } -Sess $sess
    $slowId = (Invoke-RestMethod "$Script:BaseUrl/api/items").items | Where-Object { $_.name -eq 'secret-slow' } | Select-Object -First 1
    $r = Invoke-Api -Method POST -Path '/api/run' -Body @{ itemId = $slowId.id; values = @{ Password = '@secret:leakpw' } } -Sess $sess
    if ($r.Status -eq 202) { Write-Pass 'POST /api/run (secret) → 202' } else { Write-Fail "POST /api/run (secret) → $($r.Status)" }
    # Poll command lines while the child sleeps (~3s).
    $caught = New-Object 'System.Collections.Generic.List[string]'
    $deadline = (Get-Date).AddSeconds(4)
    while ((Get-Date) -lt $deadline) { foreach ($cl in (Get-PwshCmdLines)) { [void]$caught.Add($cl) }; Start-Sleep -Milliseconds 250 }
    $joined = ($caught -join " || ")
    if ($joined -notmatch 'LEAKRUN-CANARY') { Write-Pass 'no-argv-leak: secret absent from all pwsh Win32_Process.CommandLine' } else { Write-Fail 'no-argv-leak: secret PRESENT on a command line' }
    if ($joined -match 'In\.ReadToEnd') { Write-Pass 'secret run used the stdin shim (shim marker seen on a command line)' } else { Write-Fail 'shim marker not seen — secret run may not have used stdin path' }
    Start-Sleep -Milliseconds 800
    $histText = if (Test-Path $Script:RunsJsonl) { Get-Content -Raw $Script:RunsJsonl } else { '' }
    $errText  = if (Test-Path $Script:ErrLog)    { Get-Content -Raw $Script:ErrLog }    else { '' }
    if ($histText -notmatch 'LEAKRUN-CANARY') { Write-Pass 'no-history-leak: secret absent from runs.jsonl' } else { Write-Fail 'no-history-leak: secret in runs.jsonl' }
    if ($errText  -notmatch 'LEAKRUN-CANARY') { Write-Pass 'no-log-leak: secret absent from hub-error.log' } else { Write-Fail 'no-log-leak: secret in hub-error.log' }
    # SSE surface: structural, not asserted here. Hub only ever streams the child's own
    # stdout/stderr; it never writes the injected secret value to a stream. A non-echoing
    # fixture (secret-consumer/secret-slow emits only a hash) therefore yields a clean SSE
    # buffer by construction. The echo-back case (user's own script printing the secret) is
    # the documented accepted limitation, not a Hub leak.

    # ── Binding proof via 1-step workflow (secret-consumer emits SHA256) ───────
    $BIND = 'BIND-SECRET-VALUE-aa11bb22'
    $expHash = Get-Sha256Hex $BIND
    $null = Invoke-Api -Method POST -Path '/api/secrets' -Body @{ name = 'bindpw'; kind = 'password'; value = $BIND } -Sess $sess
    $wf = @{ name = 'wf-bind'; steps = @(@{ id = 's1'; scriptId = $consumerPath; params = @{ Password = '@secret:bindpw' } }) }
    $r = Invoke-Api -Method POST -Path '/api/workflows' -Body $wf -Sess $sess
    $wfId = if ($r.Status -eq 200) { $r.Body.id } else { $null }
    if ($wfId) {
        $r = Invoke-Api -Method POST -Path "/api/workflows/$wfId/run" -Body @{} -Sess $sess
        $runId = if ($r.Status -eq 202) { $r.Body.runId } else { $null }
        $done = if ($runId) { Wait-RunComplete -RunId $runId -TimeoutSec $RunTimeoutSeconds } else { $null }
        if ($done) {
            # Binding proof comes from a FILE the fixture wrote (its captured stdout is redacted
            # because the step is secret-bearing — the hardening). The hash is one-way, not the value.
            $proof = if (Test-Path $Script:ProofFile) { Get-Content -Raw $Script:ProofFile } else { '' }
            if ($proof -match ('consumer hash=' + $expHash)) { Write-Pass 'binding: child received the REAL secret (SHA256 via proof file matches)' }
            else { Write-Fail "binding: hash mismatch (expected $expHash)" }
            $s1 = $done.Body.stepOutputs.s1
            if ($s1 -and $s1.stdoutRedacted -eq $true) { Write-Pass 'hardening: secret-bearing step stdout redacted in run record (stdoutRedacted=true)' }
            else { Write-Fail 'hardening: secret-bearing step stdout NOT redacted' }
            if ($done.Raw -notmatch 'BIND-SECRET-VALUE') { Write-Pass 'binding run record carries no plaintext' } else { Write-Fail 'binding run record leaked plaintext' }
        } else { Write-Fail 'binding workflow run did not complete' }
    } else { Write-Fail "binding workflow create → $($r.Status)" }

    # ── ADV-302: secret run of exit-3 fixture reports exit 3 ──────────────────
    $null = Invoke-Api -Method POST -Path '/api/secrets' -Body @{ name = 'exitpw'; kind = 'password'; value = 'whatever' } -Sess $sess
    $wf = @{ name = 'wf-exit3'; steps = @(@{ id = 's1'; scriptId = $exit3Path; params = @{ Password = '@secret:exitpw' } }) }
    $r = Invoke-Api -Method POST -Path '/api/workflows' -Body $wf -Sess $sess
    $wfId = if ($r.Status -eq 200) { $r.Body.id } else { $null }
    if ($wfId) {
        $r = Invoke-Api -Method POST -Path "/api/workflows/$wfId/run" -Body @{} -Sess $sess
        $runId = if ($r.Status -eq 202) { $r.Body.runId } else { $null }
        $done = if ($runId) { Wait-RunComplete -RunId $runId -TimeoutSec $RunTimeoutSeconds } else { $null }
        if ($done -and $done.Body.stepOutputs.s1.exitCode -eq 3) { Write-Pass 'ADV-302: secret run propagates exit 3 (not 0)' }
        else { Write-Fail "ADV-302: exit code was '$($done.Body.stepOutputs.s1.exitCode)' (expected 3)" }
    } else { Write-Fail "exit3 workflow create → $($r.Status)" }

    # ── ADV-301: a secret-bearing step's echoed secret never reaches downstream argv ──
    $WF3 = 'WFSECRET-CANARY-99ee77'
    $null = Invoke-Api -Method POST -Path '/api/secrets' -Body @{ name = 'wfpw'; kind = 'password'; value = $WF3 } -Sess $sess
    $wf = @{ name = 'wf-adv301'; steps = @(
        @{ id = 's1'; scriptId = $echoPath;    params = @{ Password = '@secret:wfpw' }; onSuccess = 'next' }
        @{ id = 's2'; scriptId = $argSlowPath; params = @{ Text = '{{step-s1.stdout}}' } }
    ) }
    $r = Invoke-Api -Method POST -Path '/api/workflows' -Body $wf -Sess $sess
    $wfId = if ($r.Status -eq 200) { $r.Body.id } else { $null }
    if ($wfId) {
        $r = Invoke-Api -Method POST -Path "/api/workflows/$wfId/run" -Body @{} -Sess $sess
        $runId = if ($r.Status -eq 202) { $r.Body.runId } else { $null }
        $sink  = New-Object 'System.Collections.Generic.List[string]'
        $done  = if ($runId) { Wait-RunComplete -RunId $runId -TimeoutSec $RunTimeoutSeconds -CmdLineSink ([ref]$sink) } else { $null }
        if ($done) {
            $s2 = $done.Body.stepOutputs.s2
            if ($s2 -and ($s2.stdout -match '^got=$' -or $s2.stdout -eq 'got=')) { Write-Pass 'ADV-301: downstream step received EMPTY Text (secret stdout ref dropped)' }
            else { Write-Fail "ADV-301: downstream step stdout was '$($s2.stdout)' (expected 'got=')" }
            $sinkJoined = ($sink -join " || ")
            if ($sinkJoined -notmatch 'WFSECRET-CANARY') { Write-Pass 'ADV-301: secret absent from every step Win32_Process.CommandLine (the DoD assertion)' } else { Write-Fail 'ADV-301: secret reached a command line' }
            # Hardening (user-sanctioned, rune:adversary PROCEED): step1 echoed its own secret to
            # stdout, but as a secret-bearing step its captured stdout is redacted — so the secret
            # is absent from the persisted workflow-runs/*.json record. (It may still appear in the
            # transient in-memory child job buffer; never at rest.)
            if ($done.Raw -notmatch 'WFSECRET-CANARY') { Write-Pass 'hardening: echoed secret redacted from persisted run record (no plaintext at rest)' } else { Write-Fail 'hardening: secret persisted in run record' }
        } else { Write-Fail 'ADV-301 workflow run did not complete' }
    } else { Write-Fail "ADV-301 workflow create → $($r.Status)" }

    # ── Credential kind binds [pscredential] ──────────────────────────────────
    $CRED = 'cred-pw-value-5a5a'
    $expCred = Get-Sha256Hex $CRED
    $null = Invoke-Api -Method POST -Path '/api/secrets' -Body @{ name = 'mycred'; kind = 'credential'; username = 'svc-acct'; value = $CRED } -Sess $sess
    $wf = @{ name = 'wf-cred'; steps = @(@{ id = 's1'; scriptId = $credPath; params = @{ Cred = '@secret:mycred' } }) }
    $r = Invoke-Api -Method POST -Path '/api/workflows' -Body $wf -Sess $sess
    $wfId = if ($r.Status -eq 200) { $r.Body.id } else { $null }
    if ($wfId) {
        $r = Invoke-Api -Method POST -Path "/api/workflows/$wfId/run" -Body @{} -Sess $sess
        $runId = if ($r.Status -eq 202) { $r.Body.runId } else { $null }
        $done = if ($runId) { Wait-RunComplete -RunId $runId -TimeoutSec $RunTimeoutSeconds } else { $null }
        $cproof = if (Test-Path $Script:ProofFile) { Get-Content -Raw $Script:ProofFile } else { '' }
        if ($cproof -match ('cred user=svc-acct hash=' + $expCred)) { Write-Pass 'credential kind: [pscredential] bound (username + password hash match, via proof file)' }
        else { Write-Fail "credential kind: proof not found (expected hash $expCred)" }
    } else { Write-Fail "cred workflow create → $($r.Status)" }

    # ── PUT rename + DELETE ───────────────────────────────────────────────────
    $r = Invoke-Api -Method PUT -Path '/api/secrets/cipw' -Body @{ name = 'cipw-renamed' } -Sess $sess
    if ($r.Status -eq 200) { Write-Pass 'PUT rename → 200' } else { Write-Fail "PUT rename → $($r.Status)" }
    $r = Invoke-Api -Method GET -Path '/api/secrets' -Sess $sess
    if (@($r.Body | Where-Object { $_.name -eq 'cipw-renamed' }).Count -eq 1 -and @($r.Body | Where-Object { $_.name -eq 'cipw' }).Count -eq 0) { Write-Pass 'rename reflected in list' } else { Write-Fail 'rename not reflected' }
    $r = Invoke-Api -Method DELETE -Path '/api/secrets/cipw-renamed' -Sess $sess
    if ($r.Status -eq 200) { Write-Pass 'DELETE → 200' } else { Write-Fail "DELETE → $($r.Status)" }
    $r = Invoke-Api -Method DELETE -Path '/api/secrets/nonexistent' -Sess $sess
    if ($r.Status -eq 404) { Write-Pass 'DELETE unknown → 404' } else { Write-Fail "DELETE unknown → $($r.Status)" }

} catch {
    Write-Fail "exception: $($_.Exception.Message)"
} finally {
    Stop-Hub
    $env:TEMP = $Script:OrigTemp; $env:TMP = $Script:OrigTmp; $env:LOCALAPPDATA = $Script:OrigLocalAppData
    try { if ($Script:Sandbox -and (Test-Path -LiteralPath $Script:Sandbox)) { Remove-Item -LiteralPath $Script:Sandbox -Recurse -Force -ErrorAction SilentlyContinue } } catch { }
}

Write-Host ''
if ($Script:Failures.Count -eq 0) {
    Write-Host 'smoke-phase3-secrets PASS' -ForegroundColor Green
    exit 0
} else {
    Write-Host ("smoke-phase3-secrets FAIL ({0} issue(s)):" -f $Script:Failures.Count) -ForegroundColor Red
    foreach ($f in $Script:Failures) { Write-Host "  - $f" -ForegroundColor Red }
    exit 1
}
