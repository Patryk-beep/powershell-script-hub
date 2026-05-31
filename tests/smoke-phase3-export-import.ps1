#Requires -Version 5.1
# smoke-phase3-export-import.ps1 — Phase 3 .hubflow export/import. Sandboxed, runs beside a
# live Hub.exe via -SkipMutex. Asserts HTTP STATUS + the security invariants: export carries
# no plaintext and keeps canvas; import forces a fresh id (no overwrite), resets version,
# runs Test-WorkflowSchema (rejects templates/cycles/oversize), and flags unresolved scripts.

[CmdletBinding()]
param(
    [string]$HubScript = (Join-Path (Split-Path -Parent $PSScriptRoot) 'Hub.ps1'),
    [int]$Port = 8802,
    [int]$BootTimeoutSeconds = 15
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:OrigTemp         = $env:TEMP
$Script:OrigTmp          = $env:TMP
$Script:OrigLocalAppData = $env:LOCALAPPDATA
$Script:Sandbox = Join-Path $Script:OrigTemp ('hub-smoke-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
[System.IO.Directory]::CreateDirectory($Script:Sandbox) | Out-Null
$env:TEMP = $Script:Sandbox; $env:TMP = $Script:Sandbox; $env:LOCALAPPDATA = $Script:Sandbox

$Script:Failures = New-Object 'System.Collections.Generic.List[string]'
$Script:HubProc  = $null
$Script:Fixtures = Join-Path $PSScriptRoot 'fixtures'
$Script:HubPort  = $Port
$Script:BaseUrl  = "http://127.0.0.1:$Script:HubPort"

function Write-Pass { param([string]$M) Write-Host ('  [OK] '   + $M) -ForegroundColor Green }
function Write-Fail { param([string]$M) Write-Host ('  [FAIL] ' + $M) -ForegroundColor Red; $Script:Failures.Add($M) }

function Stop-Hub {
    if ($Script:HubProc -and -not $Script:HubProc.HasExited) { & taskkill.exe /T /F /PID $Script:HubProc.Id 2>$null | Out-Null }
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
    if ($Sess) { $headers['Origin'] = $Script:BaseUrl; if (-not $NoCsrf) { $headers['X-Hub-CSRF'] = $Sess.Csrf } }
    $payload = if ($Body) { $Body | ConvertTo-Json -Depth 12 -Compress } else { $null }
    $params  = @{ Uri = "$Script:BaseUrl$Path"; Method = $Method; Headers = $headers; UseBasicParsing = $true; TimeoutSec = 10; SkipHttpErrorCheck = $true }
    if ($payload) { $params['Body'] = $payload }
    if ($Sess)    { $params['WebSession'] = $Sess.Session }
    $r = Invoke-WebRequest @params
    $obj = $null; try { $obj = $r.Content | ConvertFrom-Json } catch { }
    return @{ Status = [int]$r.StatusCode; Body = $obj; Raw = $r.Content; Headers = $r.Headers }
}

function Get-ItemPath { param([string]$Name)
    $r = Invoke-RestMethod "$Script:BaseUrl/api/items" -TimeoutSec 5
    $item = @($r.items | Where-Object { $_.name -eq $Name }) | Select-Object -First 1
    return $(if ($item) { $item.path } else { $null })
}

Write-Host ''
Write-Host 'smoke-phase3-export-import — .hubflow export/import' -ForegroundColor Cyan

try {
    Start-HubProcess
    Write-Pass 'Hub booted'
    $sess = New-HubSession

    $echoPath     = Get-ItemPath 'echo'
    $consumerPath = Get-ItemPath 'secret-consumer'
    if (-not $echoPath -or -not $consumerPath) { Write-Fail 'fixtures echo/secret-consumer not in catalog'; throw 'fixture missing' }

    # ── Create a workflow with canvas + a @secret token + a normal step ───────
    $wf = @{
        name   = 'wf-export-me'
        steps  = @(
            @{ id = 's1'; scriptId = $echoPath;     params = @{ Text = 'hello-export' }; onSuccess = 'next' }
            @{ id = 's2'; scriptId = $consumerPath; params = @{ Password = '@secret:foo' } }
        )
        canvas = @{ nodes = @(@{ id = 's1'; x = 10; y = 20 }, @{ id = 's2'; x = 200; y = 20 }); zoom = 1 }
    }
    $r = Invoke-Api -Method POST -Path '/api/workflows' -Body $wf -Sess $sess
    if ($r.Status -ne 200) { Write-Fail "create workflow → $($r.Status)"; throw 'create failed' }
    $srcId = $r.Body.id
    Write-Pass "workflow created ($srcId)"

    # ── Export ────────────────────────────────────────────────────────────────
    $r = Invoke-Api -Method GET -Path "/api/workflows/$srcId/export" -Sess $sess
    if ($r.Status -eq 200) { Write-Pass 'GET export → 200' } else { Write-Fail "export → $($r.Status)" }
    $cd = [string]$r.Headers['Content-Disposition']
    if ($cd -match 'attachment' -and $cd -match '\.hubflow') { Write-Pass 'export sets Content-Disposition attachment *.hubflow' } else { Write-Fail "export Content-Disposition: $cd" }
    $env1 = $r.Body
    if ($env1 -and $env1.hubflow -eq 1 -and $env1.workflow) { Write-Pass 'envelope shape { hubflow:1, workflow }' } else { Write-Fail 'envelope shape wrong' }
    if ($env1.workflow.canvas -and $env1.workflow.canvas.nodes) { Write-Pass 'exported workflow retains canvas' } else { Write-Fail 'canvas missing from export' }
    if ($r.Raw -match '@secret:foo' -and $r.Raw -notmatch 'BIND-SECRET|CANARY|hunter2') { Write-Pass 'export carries @secret token, no plaintext values' } else { Write-Fail 'export plaintext check failed' }

    # ── 404 on unknown export ─────────────────────────────────────────────────
    $r = Invoke-Api -Method GET -Path '/api/workflows/nope-not-real/export' -Sess $sess
    if ($r.Status -eq 404) { Write-Pass 'export unknown id → 404' } else { Write-Fail "export unknown → $($r.Status)" }

    # ── Import the exported envelope → fresh id, version reset ─────────────────
    $r = Invoke-Api -Method POST -Path '/api/workflows/import' -Body $env1 -Sess $sess
    if ($r.Status -eq 200) { Write-Pass 'import → 200' } else { Write-Fail "import → $($r.Status)" }
    $newId = $r.Body.id
    if ($newId -and $newId -ne $srcId) { Write-Pass 'import forced a FRESH id (no overwrite of source)' } else { Write-Fail "import id not fresh: $newId vs $srcId" }
    if (@($r.Body.referencedSecrets) -contains 'foo') { Write-Pass 'import reports referencedSecrets = [foo]' } else { Write-Fail "referencedSecrets: $($r.Body.referencedSecrets -join ',')" }
    if (@($r.Body.unresolvedScripts).Count -eq 0) { Write-Pass 'import: all scriptIds resolved (no unresolved)' } else { Write-Fail "unexpected unresolvedScripts: $($r.Body.unresolvedScripts -join ',')" }
    # Confirm the imported copy has version=1 and is a distinct stored workflow.
    $r2 = Invoke-Api -Method GET -Path "/api/workflows/$newId" -Sess $sess
    if ($r2.Status -eq 200 -and $r2.Body.version -eq 1) { Write-Pass 'imported workflow persisted with version=1' } else { Write-Fail "imported workflow version: $($r2.Body.version)" }

    # ── Tampered imports → 422 / 413 ──────────────────────────────────────────
    $r = Invoke-Api -Method POST -Path '/api/workflows/import' -Body @{ hubflow = 99; workflow = $wf } -Sess $sess
    if ($r.Status -eq 422) { Write-Pass 'bad hubflow version → 422' } else { Write-Fail "bad hubflow version → $($r.Status)" }

    $r = Invoke-Api -Method POST -Path '/api/workflows/import' -Body @{ hubflow = 1 } -Sess $sess
    if ($r.Status -eq 422) { Write-Pass 'missing workflow → 422' } else { Write-Fail "missing workflow → $($r.Status)" }

    $tmplWf = @{ name = 'evil'; steps = @(@{ id = 's1'; scriptId = '{{evil}}'; params = @{} }) }
    $r = Invoke-Api -Method POST -Path '/api/workflows/import' -Body @{ hubflow = 1; workflow = $tmplWf } -Sess $sess
    if ($r.Status -eq 422) { Write-Pass 'templated scriptId → 422 (Test-WorkflowSchema)' } else { Write-Fail "templated scriptId → $($r.Status)" }

    $cycWf = @{ name = 'cyc'; steps = @(
        @{ id = 's1'; scriptId = $echoPath; params = @{}; onSuccess = 's2' }
        @{ id = 's2'; scriptId = $echoPath; params = @{}; onSuccess = 's1' }
    ) }
    $r = Invoke-Api -Method POST -Path '/api/workflows/import' -Body @{ hubflow = 1; workflow = $cycWf } -Sess $sess
    if ($r.Status -eq 422) { Write-Pass 'cyclic graph → 422' } else { Write-Fail "cyclic graph → $($r.Status)" }

    $bigVal = 'z' * 300000
    $bigWf = @{ name = 'big'; steps = @(@{ id = 's1'; scriptId = $echoPath; params = @{ Text = $bigVal } }) }
    $r = Invoke-Api -Method POST -Path '/api/workflows/import' -Body @{ hubflow = 1; workflow = $bigWf } -Sess $sess
    if ($r.Status -eq 413) { Write-Pass 'oversized import body → 413' } else { Write-Fail "oversized import → $($r.Status) (expected 413)" }

    # ── Out-of-root scriptId → 200 + unresolvedScripts ────────────────────────
    $orphan = 'C:\Nowhere\not-in-scanroot.ps1'
    $orphanWf = @{ name = 'orphan'; steps = @(@{ id = 's1'; scriptId = $orphan; params = @{} }) }
    $r = Invoke-Api -Method POST -Path '/api/workflows/import' -Body @{ hubflow = 1; workflow = $orphanWf } -Sess $sess
    if ($r.Status -eq 200 -and (@($r.Body.unresolvedScripts) -contains $orphan)) { Write-Pass 'out-of-root scriptId → 200 + flagged unresolved' } else { Write-Fail "out-of-root → $($r.Status) unresolved=$($r.Body.unresolvedScripts -join ',')" }

    # ── Export scrub: a literal in a password param is rejected (defense in depth) ──
    $leakWf = @{ name = 'wf-leak'; steps = @(@{ id = 's1'; scriptId = $consumerPath; params = @{ Password = 'LITERAL-SECRET-LEAK' } }) }
    $r = Invoke-Api -Method POST -Path '/api/workflows' -Body $leakWf -Sess $sess
    $leakId = $r.Body.id
    $r = Invoke-Api -Method GET -Path "/api/workflows/$leakId/export" -Sess $sess
    if ($r.Status -eq 422 -and $r.Raw -match 'secret-literal-in-workflow') { Write-Pass 'export scrub: literal in password param → 422' } else { Write-Fail "export scrub → $($r.Status) (expected 422)" }

    # ── Import must NOT carry an execution trigger (no auto-run) ──────────────
    $cronWf = @{ name = 'wf-cron'; trigger = @{ type = 'cron'; expression = '* * * * *' };
        steps = @(@{ id = 's1'; scriptId = $echoPath; params = @{ Text = 'x' } }) }
    $r = Invoke-Api -Method POST -Path '/api/workflows/import' -Body @{ hubflow = 1; workflow = $cronWf } -Sess $sess
    if ($r.Status -eq 200) {
        $imp = Invoke-Api -Method GET -Path "/api/workflows/$($r.Body.id)" -Sess $sess
        $t = $imp.Body.trigger
        if (-not $t -or $t.type -eq 'manual') { Write-Pass 'import resets trigger to manual (no auto-schedule on import)' }
        else { Write-Fail "import preserved trigger.type=$($t.type) — could auto-run!" }
    } else { Write-Fail "cron-trigger import → $($r.Status)" }

    # ── CSRF gate on import ───────────────────────────────────────────────────
    $sessNoCsrf = New-HubSession
    $r = Invoke-Api -Method POST -Path '/api/workflows/import' -Body @{ hubflow = 1; workflow = $wf } -Sess $sessNoCsrf -NoCsrf
    if ($r.Status -eq 403) { Write-Pass 'import without CSRF → 403' } else { Write-Fail "import without CSRF → $($r.Status)" }

} catch {
    Write-Fail "exception: $($_.Exception.Message)"
} finally {
    Stop-Hub
    $env:TEMP = $Script:OrigTemp; $env:TMP = $Script:OrigTmp; $env:LOCALAPPDATA = $Script:OrigLocalAppData
    try { if ($Script:Sandbox -and (Test-Path -LiteralPath $Script:Sandbox)) { Remove-Item -LiteralPath $Script:Sandbox -Recurse -Force -ErrorAction SilentlyContinue } } catch { }
}

Write-Host ''
if ($Script:Failures.Count -eq 0) {
    Write-Host 'smoke-phase3-export-import PASS' -ForegroundColor Green
    exit 0
} else {
    Write-Host ("smoke-phase3-export-import FAIL ({0} issue(s)):" -f $Script:Failures.Count) -ForegroundColor Red
    foreach ($f in $Script:Failures) { Write-Host "  - $f" -ForegroundColor Red }
    exit 1
}
