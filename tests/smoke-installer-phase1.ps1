#Requires -Version 5.1
# smoke-installer-phase1.ps1
# Phase 1 (config refactor + setup wizard) smoke. Runs against Hub.ps1 under pwsh
# (NOT the compiled Hub.exe — exe doesn't have the new code until P1.final rebuild).
#
# 16 cases — covers K21/K22/K23 + ADV-C1/H3.
# Case 14 (FolderBrowserDialog rate-limit) skipped — dialog is modal, can't auto-dismiss.
# Verify manually: click Settings → Browse twice rapidly → 2nd call should return 429.

[CmdletBinding()]
param(
    [string]$HubSource = (Join-Path (Split-Path -Parent $PSScriptRoot) 'Hub.ps1'),
    [int]$Port = 8765,
    [int]$BootTimeoutSeconds = 12
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:Failures = New-Object 'System.Collections.Generic.List[string]'
$Script:HubProc  = $null
$Script:Backup   = $null
$Script:CfgDir   = Join-Path $env:LOCALAPPDATA 'Hub'
$Script:CfgPath  = Join-Path $Script:CfgDir 'hub-config.json'

function Write-Step { param([string]$M) Write-Host ('  [..] ' + $M) -ForegroundColor DarkGray }
function Write-Pass { param([string]$M) Write-Host ('  [OK] ' + $M) -ForegroundColor Green }
function Write-Fail { param([string]$M) Write-Host ('  [FAIL] ' + $M) -ForegroundColor Red; $Script:Failures.Add($M) }

function Backup-UserConfig {
    if (Test-Path -LiteralPath $Script:CfgPath) {
        $Script:Backup = Get-Content -LiteralPath $Script:CfgPath -Raw -Encoding UTF8
        Remove-Item -LiteralPath $Script:CfgPath -Force
        Write-Step "Backed up user's hub-config.json"
    }
}

function Restore-UserConfig {
    if ($Script:Backup) {
        [System.IO.File]::WriteAllText($Script:CfgPath, $Script:Backup, [System.Text.Encoding]::UTF8)
        Write-Step 'Restored user hub-config.json'
    } elseif (Test-Path -LiteralPath $Script:CfgPath) {
        Remove-Item -LiteralPath $Script:CfgPath -Force
    }
}

function Stop-Hub {
    if ($Script:HubProc) {
        try { & taskkill.exe /T /F /PID $Script:HubProc.Id 2>$null | Out-Null } catch {}
        $Script:HubProc = $null
    }
    Start-Sleep -Milliseconds 600
}

function Start-Hub {
    param([string[]]$ExtraArgs = @())
    Stop-Hub
    $args = @('-NoProfile','-File',$HubSource) + $ExtraArgs
    $Script:HubProc = Start-Process pwsh -ArgumentList $args -PassThru -WindowStyle Hidden
    $deadline = (Get-Date).AddSeconds($BootTimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $r = Invoke-WebRequest "http://127.0.0.1:$Port/api/health" -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
            if ($r.StatusCode -eq 200) { return }
        } catch { Start-Sleep -Milliseconds 300 }
    }
    throw "Hub did not become healthy within $BootTimeoutSeconds s"
}

function New-HubSession {
    # Seeds CSRF cookie + returns session + cookie value.
    $session = $null
    $null = Invoke-WebRequest "http://127.0.0.1:$Port/" -UseBasicParsing -SessionVariable session -TimeoutSec 5
    $cookie = ($session.Cookies.GetCookies("http://127.0.0.1:$Port") | Where-Object Name -eq 'hub-csrf').Value
    return @{ Session = $session; Csrf = $cookie }
}

function Invoke-Setup {
    param([hashtable]$Sess, [object]$Body, [hashtable]$ExtraHeaders = @{})
    $headers = @{
        'Content-Type' = 'application/json'
        'Origin'       = "http://127.0.0.1:$Port"
        'X-Hub-CSRF'   = $Sess.Csrf
    }
    foreach ($k in $ExtraHeaders.Keys) { $headers[$k] = $ExtraHeaders[$k] }
    $payload = $Body | ConvertTo-Json -Compress -Depth 4
    # PS 7 throws Microsoft.PowerShell.Commands.HttpResponseException — handle via -SkipHttpErrorCheck (PS 7+).
    try {
        $r = Invoke-WebRequest "http://127.0.0.1:$Port/api/setup" `
            -Method POST -Body $payload -Headers $headers `
            -WebSession $Sess.Session -UseBasicParsing -TimeoutSec 10 -SkipHttpErrorCheck
        $bodyObj = $null
        try { $bodyObj = $r.Content | ConvertFrom-Json } catch {}
        return @{ Status = [int]$r.StatusCode; Body = $bodyObj }
    } catch {
        return @{ Status = -1; Body = $null; Error = $_.Exception.Message }
    }
}

# ─────────────────────────────────────────────────────────────────────
# Begin
# ─────────────────────────────────────────────────────────────────────
Write-Host ''
Write-Host 'smoke-installer-phase1 — config refactor + setup wizard' -ForegroundColor Cyan

try {
    Backup-UserConfig

    # ─── Case 1: boot with no config ───────────────────────────────
    Start-Hub
    $cfg = Invoke-RestMethod "http://127.0.0.1:$Port/api/config" -TimeoutSec 5
    if (-not $cfg.needsSetup)       { Write-Fail 'Case 1: needsSetup should be true on fresh boot' }
    elseif ($cfg.defaults.Count -ne 2) { Write-Fail "Case 1: expected 2 defaults, got $($cfg.defaults.Count)" }
    elseif ($cfg.maxScanRoots -ne 16)  { Write-Fail "Case 1: maxScanRoots expected 16, got $($cfg.maxScanRoots)" }
    else { Write-Pass 'Case 1: /api/config returns needsSetup=true + defaults + maxScanRoots' }

    $sess = New-HubSession

    # ─── Case 2: valid two-path setup ──────────────────────────────
    $tmpDir1 = Join-Path $env:TEMP "hub-smoke-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    $tmpDir2 = Join-Path $env:TEMP "hub-smoke-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    [System.IO.Directory]::CreateDirectory($tmpDir1) | Out-Null
    [System.IO.Directory]::CreateDirectory($tmpDir2) | Out-Null
    $r = Invoke-Setup -Sess $sess -Body @{ scanRoots = @($tmpDir1, $tmpDir2) }
    if ($r.Status -ne 200)           { Write-Fail "Case 2: expected 200, got $($r.Status)" }
    elseif ((-not $r.Body) -or (-not $r.Body.ok)) { Write-Fail 'Case 2: ok=false in response' }
    elseif (-not (Test-Path -LiteralPath $Script:CfgPath)) { Write-Fail 'Case 2: hub-config.json not written' }
    else {
        $cfg2 = Invoke-RestMethod "http://127.0.0.1:$Port/api/config" -TimeoutSec 5
        if ($cfg2.needsSetup)        { Write-Fail 'Case 2: needsSetup should be false after save' }
        elseif (@($cfg2.scanRoots).Count -ne 2) { Write-Fail "Case 2: expected 2 roots, got $(@($cfg2.scanRoots).Count)" }
        else { Write-Pass 'Case 2: POST /api/setup persisted; /api/config reflects' }
    }

    # ─── Case 3: relative path rejected ────────────────────────────
    $r = Invoke-Setup -Sess $sess -Body @{ scanRoots = @('.\foo') }
    if ($r.Status -ne 400 -or $r.Body.error -ne 'invalid-path') { Write-Fail "Case 3: relative path should 400 invalid-path, got $($r.Status)/$($r.Body.error)" }
    else { Write-Pass 'Case 3: relative path rejected (400 invalid-path)' }

    # ─── Case 4: UNC rejected ──────────────────────────────────────
    $r = Invoke-Setup -Sess $sess -Body @{ scanRoots = @('\\server\share\foo') }
    if ($r.Status -ne 400 -or $r.Body.error -ne 'invalid-path') { Write-Fail "Case 4: UNC should 400, got $($r.Status)/$($r.Body.error)" }
    else { Write-Pass 'Case 4: UNC path rejected (K22)' }

    # ─── Case 5: system root rejected ──────────────────────────────
    $r = Invoke-Setup -Sess $sess -Body @{ scanRoots = @($env:SystemRoot) }
    if ($r.Status -ne 400 -or $r.Body.error -ne 'invalid-path') { Write-Fail "Case 5: SystemRoot should 400, got $($r.Status)/$($r.Body.error)" }
    else { Write-Pass 'Case 5: C:\Windows rejected (K22)' }

    # ─── Case 6: install dir reflection rejected ───────────────────
    $installDir = Split-Path -Parent $HubSource
    $r = Invoke-Setup -Sess $sess -Body @{ scanRoots = @($installDir) }
    if ($r.Status -ne 400 -or $r.Body.error -ne 'invalid-path') { Write-Fail "Case 6: install dir should 400, got $($r.Status)/$($r.Body.error)" }
    else { Write-Pass 'Case 6: install dir reflection rejected (K22)' }

    # ─── Case 7: config dir reflection rejected ────────────────────
    $r = Invoke-Setup -Sess $sess -Body @{ scanRoots = @($Script:CfgDir) }
    if ($r.Status -ne 400 -or $r.Body.error -ne 'invalid-path') { Write-Fail "Case 7: config dir should 400, got $($r.Status)/$($r.Body.error)" }
    else { Write-Pass 'Case 7: config dir reflection rejected (K22)' }

    # ─── Case 8: traversal `..` rejected ───────────────────────────
    $r = Invoke-Setup -Sess $sess -Body @{ scanRoots = @('C:\foo\..\bar') }
    if ($r.Status -ne 400 -or $r.Body.error -ne 'invalid-path') { Write-Fail "Case 8: traversal should 400, got $($r.Status)/$($r.Body.error)" }
    else { Write-Pass 'Case 8: traversal rejected (K22)' }

    # ─── Case 9: too many roots (17) ───────────────────────────────
    $many = 1..17 | ForEach-Object { Join-Path $env:TEMP "hub-many-$_" }
    $r = Invoke-Setup -Sess $sess -Body @{ scanRoots = $many }
    if ($r.Status -ne 400 -or $r.Body.error -ne 'too-many-roots') { Write-Fail "Case 9: 17 roots should 400 too-many-roots, got $($r.Status)/$($r.Body.error)" }
    elseif ($r.Body.max -ne 16) { Write-Fail "Case 9: expected max=16, got $($r.Body.max)" }
    else { Write-Pass 'Case 9: >16 roots rejected (K22 cap)' }

    # ─── Case 10: dedupe two identical paths ───────────────────────
    $r = Invoke-Setup -Sess $sess -Body @{ scanRoots = @($tmpDir1, $tmpDir1) }
    if ($r.Status -ne 200) { Write-Fail "Case 10: expected 200, got $($r.Status)" }
    elseif (@($r.Body.scanRoots).Count -ne 1) { Write-Fail "Case 10: expected 1 after dedup, got $(@($r.Body.scanRoots).Count)" }
    else { Write-Pass 'Case 10: duplicates deduplicated' }

    # ─── Case 11: ADV-C1 — cross-origin POST with matching CSRF rejected ──
    $r = Invoke-Setup -Sess $sess -Body @{ scanRoots = @($tmpDir1) } -ExtraHeaders @{ 'Origin' = 'https://evil.example.com' }
    if ($r.Status -ne 403 -or $r.Body.error -ne 'origin') { Write-Fail "Case 11: cross-origin should 403 origin, got $($r.Status)/$($r.Body.error)" }
    else { Write-Pass 'Case 11: ADV-C1 cross-origin POST rejected (403 origin)' }

    # ─── Case 12: no CSRF header rejected ──────────────────────────
    # NOTE: PS7 WebSession persists -Headers across requests. For negative CSRF tests,
    # we DO NOT use $sess.Session — instead inject the cookie via Cookie header explicitly.
    $r = Invoke-WebRequest "http://127.0.0.1:$Port/api/setup" `
        -Method POST -Body (@{ scanRoots = @($tmpDir1) } | ConvertTo-Json -Compress) `
        -Headers @{
            'Content-Type' = 'application/json'
            'Origin'       = "http://127.0.0.1:$Port"
            'Cookie'       = "hub-csrf=$($sess.Csrf)"
        } -UseBasicParsing -TimeoutSec 5 -SkipHttpErrorCheck
    if ([int]$r.StatusCode -eq 403) { Write-Pass 'Case 12: missing CSRF header rejected (403)' }
    else { Write-Fail "Case 12: expected 403, got $([int]$r.StatusCode)" }

    # ─── Case 13: /api/browse-folder without CSRF ──────────────────
    $r = Invoke-WebRequest "http://127.0.0.1:$Port/api/browse-folder" `
        -Method POST -Body '{}' `
        -Headers @{
            'Content-Type' = 'application/json'
            'Origin'       = "http://127.0.0.1:$Port"
            'Cookie'       = "hub-csrf=$($sess.Csrf)"
        } -UseBasicParsing -TimeoutSec 5 -SkipHttpErrorCheck
    if ([int]$r.StatusCode -eq 403) { Write-Pass 'Case 13: /api/browse-folder missing CSRF rejected (403)' }
    else { Write-Fail "Case 13: expected 403, got $([int]$r.StatusCode)" }

    # ─── Case 14: SKIPPED (manual — modal blocks listener pump) ────
    Write-Host '  [SKIP] Case 14: /api/browse-folder rate-limit (manual verify — modal blocks pump)' -ForegroundColor Yellow

    # ─── Case 15: bad version triggers fallback ────────────────────
    Stop-Hub
    [System.IO.File]::WriteAllText($Script:CfgPath, '{"version":99,"scanRoots":[]}', [System.Text.Encoding]::UTF8)
    Start-Hub
    $cfgBad = Invoke-RestMethod "http://127.0.0.1:$Port/api/config" -TimeoutSec 5
    if (-not $cfgBad.needsSetup) { Write-Fail 'Case 15: bad version should trigger needsSetup=true' }
    else { Write-Pass 'Case 15: ADV-H3 unknown config version triggers fallback' }

    # ─── Case 16: -ExtraScanRoots not in /api/config (K23 divergence) ─
    Stop-Hub
    Remove-Item -LiteralPath $Script:CfgPath -Force -ErrorAction SilentlyContinue
    Start-Hub -ExtraArgs @('-ExtraScanRoots',$tmpDir1)
    $cfgX = Invoke-RestMethod "http://127.0.0.1:$Port/api/config" -TimeoutSec 5
    $itemsX = (Invoke-RestMethod "http://127.0.0.1:$Port/api/items" -TimeoutSec 5).items
    $persistedHasTmp1 = @($cfgX.scanRoots | Where-Object { $_ -eq $tmpDir1 }).Count -gt 0
    if ($persistedHasTmp1) { Write-Fail 'Case 16: K23 broken — /api/config leaked $ExtraScanRoots into persisted view' }
    else { Write-Pass 'Case 16: K23 /api/config returns persisted-only, ExtraScanRoots invisible' }

} finally {
    Stop-Hub
    Restore-UserConfig
}

Write-Host ''
if ($Script:Failures.Count -eq 0) {
    Write-Host 'PASS — phase 1 smoke succeeded (15 automated + 1 manual)' -ForegroundColor Green
    exit 0
} else {
    Write-Host ('FAIL — ' + $Script:Failures.Count + ' failure(s):') -ForegroundColor Red
    foreach ($f in $Script:Failures) { Write-Host ('  - ' + $f) -ForegroundColor Red }
    exit 1
}
