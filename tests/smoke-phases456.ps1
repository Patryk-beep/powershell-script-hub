#Requires -Version 5.1
# smoke-phases456.ps1 — Phase 4 (triggers), 5 (git), 6 (history) smoke.

[CmdletBinding()]
param(
    [string]$HubScript = (Join-Path (Split-Path -Parent $PSScriptRoot) 'Hub.ps1'),
    [int]$Port = 8799,
    [int]$BootTimeoutSeconds = 15
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Test isolation (ADV-002/004): sandbox TEMP + LOCALAPPDATA so we bind -Port deterministically
# and never touch the user's real %LOCALAPPDATA%\Hub\. Restored in finally. ---
$Script:OrigTemp          = $env:TEMP
$Script:OrigTmp           = $env:TMP
$Script:OrigLocalAppData  = $env:LOCALAPPDATA
$Script:Sandbox = Join-Path $Script:OrigTemp ('hub-smoke-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
[System.IO.Directory]::CreateDirectory($Script:Sandbox) | Out-Null
$env:TEMP         = $Script:Sandbox
$env:TMP          = $Script:Sandbox
$env:LOCALAPPDATA = $Script:Sandbox

$Script:Failures = New-Object 'System.Collections.Generic.List[string]'
$Script:HubProc  = $null
$Script:Fixtures = Join-Path $PSScriptRoot 'fixtures'
$Script:HubPort  = $Port
$Script:BaseUrl  = "http://127.0.0.1:$Script:HubPort"
$Script:CfgDir   = Join-Path $env:LOCALAPPDATA 'Hub'
$Script:CfgPath  = Join-Path $Script:CfgDir 'hub-config.json'
$Script:CfgBackup = $null

function Write-Pass { param([string]$M) Write-Host ('  [OK] '   + $M) -ForegroundColor Green }
function Write-Fail { param([string]$M) Write-Host ('  [FAIL] ' + $M) -ForegroundColor Red; $Script:Failures.Add($M) }

function Stop-Hub {
    if ($Script:HubProc -and -not $Script:HubProc.HasExited) {
        & taskkill.exe /T /F /PID $Script:HubProc.Id 2>$null | Out-Null
    }
    $Script:HubProc = $null
    Start-Sleep -Milliseconds 600
}

function Start-HubProcess {
    Stop-Hub
    $Script:HubProc = Start-Process pwsh `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$HubScript`" -ExtraScanRoots `"$Script:Fixtures`" -SkipMutex -Port $Script:HubPort" `
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
    if ($Sess) { $headers['Origin'] = $Script:BaseUrl; $headers['X-Hub-CSRF'] = $Sess.Csrf }
    $params = @{ Uri = "$Script:BaseUrl$Path"; Method = $Method; Headers = $headers; UseBasicParsing = $true; TimeoutSec = 10; SkipHttpErrorCheck = $true }
    if ($Body) { $params['Body'] = ($Body | ConvertTo-Json -Depth 10 -Compress) }
    if ($Sess) { $params['WebSession'] = $Sess.Session }
    $r = Invoke-WebRequest @params
    $obj = $null; try { $obj = $r.Content | ConvertFrom-Json } catch { }
    return @{ Status = [int]$r.StatusCode; Body = $obj; Raw = $r.Content }
}

Write-Host ''
Write-Host 'smoke-phases456 — triggers, git, history' -ForegroundColor Cyan

try {
    # Backup config
    if (Test-Path $Script:CfgPath) {
        $Script:CfgBackup = Get-Content $Script:CfgPath -Raw -Encoding UTF8
        Remove-Item $Script:CfgPath -Force
    }

    Start-HubProcess
    Write-Pass 'Hub booted'
    $sess = New-HubSession

    # ── Phase 6: History endpoint exists ────────────────────────────────
    $r = Invoke-Api -Method GET -Path '/api/history'
    if ($r.Status -eq 200 -and $null -ne $r.Body.entries -and $null -ne $r.Body.total) {
        Write-Pass 'P6-1: GET /api/history returns entries + total'
    } else {
        Write-Fail "P6-1: expected 200 with entries/total, got $($r.Status)"
    }

    # ── Phase 6: Run a script and verify history entry ───────────────────
    $echoPath = (Invoke-RestMethod "$Script:BaseUrl/api/items" -TimeoutSec 5).items |
                Where-Object { $_.name -eq 'echo' } | Select-Object -First 1 -ExpandProperty path
    if (-not $echoPath) { Write-Fail 'P6-2: echo fixture not found'; } else {
        $wfBody = @{
            name = 'p456-hist-test'
            steps = @( @{ id = 's1'; scriptId = $echoPath; params = @{ Text = 'history-test' } } )
        }
        $cr = Invoke-Api -Method POST -Path '/api/workflows' -Body $wfBody -Sess $sess
        if ($cr.Status -ne 200) { Write-Fail "P6-2: create wf failed ($($cr.Status))" } else {
            $wfId  = $cr.Body.id
            $trigR = Invoke-Api -Method POST -Path "/api/workflows/$wfId/run" -Body @{} -Sess $sess
            if ($trigR.Status -ne 202) { Write-Fail "P6-2: trigger failed ($($trigR.Status))" } else {
                Start-Sleep -Seconds 3
                $hr = Invoke-Api -Method GET -Path '/api/history'
                if ($hr.Status -eq 200 -and $hr.Body.total -gt 0) {
                    Write-Pass "P6-2: history has entries after run ($($hr.Body.total) total)"
                } else {
                    Write-Fail "P6-2: history still empty after run (total=$($hr.Body.total))"
                }
            }
        }
    }

    # ── Phase 6: CSV export ──────────────────────────────────────────────
    $r = Invoke-WebRequest "$Script:BaseUrl/api/history?format=csv" -UseBasicParsing -TimeoutSec 5 -SkipHttpErrorCheck
    if ([int]$r.StatusCode -eq 200 -and $r.Headers['Content-Type'] -match 'text/csv') {
        Write-Pass 'P6-3: CSV export returns text/csv'
    } else {
        Write-Fail "P6-3: expected CSV, got $([int]$r.StatusCode) $($r.Headers['Content-Type'])"
    }

    # ── Phase 5: GET /api/git-roots returns list ─────────────────────────
    $r = Invoke-Api -Method GET -Path '/api/git-roots'
    if ($r.Status -eq 200 -and $null -ne $r.Body.gitRoots) {
        Write-Pass 'P5-1: GET /api/git-roots returns gitRoots array'
    } else {
        Write-Fail "P5-1: expected 200 with gitRoots, got $($r.Status)"
    }

    # ── Phase 5: Reject non-https URL ────────────────────────────────────
    $r = Invoke-Api -Method POST -Path '/api/git-roots' -Body @{ url = 'file:///local/repo'; branch = 'main' } -Sess $sess
    if ($r.Status -eq 400 -and $r.Body.error -eq 'invalid-url') {
        Write-Pass 'P5-2: file:// URL rejected (400 invalid-url)'
    } else {
        Write-Fail "P5-2: expected 400 invalid-url, got $($r.Status)/$($r.Body.error)"
    }

    $r = Invoke-Api -Method POST -Path '/api/git-roots' -Body @{ url = 'ssh://github.com/user/repo'; branch = 'main' } -Sess $sess
    if ($r.Status -eq 400 -and $r.Body.error -eq 'invalid-url') {
        Write-Pass 'P5-3: ssh:// URL rejected (400 invalid-url)'
    } else {
        Write-Fail "P5-3: expected 400 invalid-url, got $($r.Status)/$($r.Body.error)"
    }

    # ── Phase 5: Accept valid https URL (no actual clone) ────────────────
    $r = Invoke-Api -Method POST -Path '/api/git-roots' -Body @{ url = 'https://github.com/example/repo.git'; branch = 'main' } -Sess $sess
    if ($r.Status -eq 202 -and $r.Body.ok -and $r.Body.trustWarning) {
        Write-Pass 'P5-4: https URL accepted (202) with trustWarning'
    } else {
        Write-Fail "P5-4: expected 202+ok+trustWarning, got $($r.Status)"
    }

    # ── Phase 4: Trigger schema validation (bad cron expression) ─────────
    $badWf = @{
        name    = 'bad-trigger'
        trigger = @{ type = 'cron'; expression = 'not-a-cron' }
        steps   = @( @{ id = 's1'; scriptId = $echoPath; params = @{} } )
    }
    if ($echoPath) {
        $r = Invoke-Api -Method POST -Path '/api/workflows' -Body $badWf -Sess $sess
        if ($r.Status -eq 422) {
            Write-Pass 'P4-1: bad cron expression rejected (422)'
        } else {
            Write-Fail "P4-1: expected 422, got $($r.Status)"
        }
    }

    # ── Phase 4: Valid manual trigger accepted ────────────────────────────
    if ($echoPath) {
        $goodWf = @{
            name    = 'manual-trigger-test'
            trigger = @{ type = 'manual' }
            steps   = @( @{ id = 's1'; scriptId = $echoPath; params = @{} } )
        }
        $r = Invoke-Api -Method POST -Path '/api/workflows' -Body $goodWf -Sess $sess
        if ($r.Status -eq 200) {
            Write-Pass 'P4-2: manual trigger workflow created (200)'
        } else {
            Write-Fail "P4-2: expected 200, got $($r.Status)"
        }
    }

    # ── Phase 4: Valid cron trigger accepted ──────────────────────────────
    if ($echoPath) {
        $cronWf = @{
            name    = 'cron-trigger-test'
            trigger = @{ type = 'cron'; expression = '0 8 * * 1-5' }
            steps   = @( @{ id = 's1'; scriptId = $echoPath; params = @{} } )
        }
        $r = Invoke-Api -Method POST -Path '/api/workflows' -Body $cronWf -Sess $sess
        if ($r.Status -eq 200) {
            Write-Pass 'P4-3: valid cron trigger (0 8 * * 1-5) accepted (200)'
        } else {
            Write-Fail "P4-3: expected 200, got $($r.Status) - $($r.Raw)"
        }
    }

    # ── Phase 4: Trigger state dir created ───────────────────────────────
    $stateDir = Join-Path $Script:CfgDir 'trigger-states'
    if ([System.IO.Directory]::Exists($stateDir)) {
        Write-Pass 'P4-4: trigger-states directory created'
    } else {
        Write-Fail 'P4-4: trigger-states directory not created'
    }

    # ── Phase 6: History pagination ───────────────────────────────────────
    $r = Invoke-Api -Method GET -Path '/api/history?limit=2&offset=0'
    if ($r.Status -eq 200 -and $r.Body.limit -eq 2) {
        Write-Pass 'P6-4: history pagination (limit/offset) works'
    } else {
        Write-Fail "P6-4: pagination failed, got $($r.Status)"
    }

} finally {
    Stop-Hub
    if ($Script:CfgBackup) {
        [System.IO.File]::WriteAllText($Script:CfgPath, $Script:CfgBackup, [System.Text.Encoding]::UTF8)
    } elseif (Test-Path $Script:CfgPath) {
        Remove-Item $Script:CfgPath -Force -ErrorAction SilentlyContinue
    }
    # Restore env + remove the isolation sandbox (ADV-002/004).
    $env:TEMP = $Script:OrigTemp; $env:TMP = $Script:OrigTmp; $env:LOCALAPPDATA = $Script:OrigLocalAppData
    try { if ($Script:Sandbox -and (Test-Path -LiteralPath $Script:Sandbox)) { Remove-Item -LiteralPath $Script:Sandbox -Recurse -Force -ErrorAction SilentlyContinue } } catch { }
}

Write-Host ''
if ($Script:Failures.Count -eq 0) {
    Write-Host 'smoke-phases456 PASS' -ForegroundColor Green
    exit 0
} else {
    Write-Host ("smoke-phases456 FAIL ({0} issue(s)):" -f $Script:Failures.Count) -ForegroundColor Red
    foreach ($f in $Script:Failures) { Write-Host "  - $f" -ForegroundColor Red }
    exit 1
}
