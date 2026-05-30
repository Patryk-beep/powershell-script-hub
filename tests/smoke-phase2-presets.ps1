#Requires -Version 5.1
# smoke-phase2-presets.ps1 — Phase 2: preset CRUD, secret redaction (ADV-201),
# argv-preview (ADV-202/203). Runs beside a live Hub.exe via -SkipMutex + sandboxed
# LOCALAPPDATA/TEMP. Asserts HTTP STATUS (never $null -ne body — '[]'|ConvertFrom-Json
# is $null, indistinguishable from a 503 body-null).

[CmdletBinding()]
param(
    [string]$HubScript = (Join-Path (Split-Path -Parent $PSScriptRoot) 'Hub.ps1'),
    [int]$Port = 8799,
    [int]$BootTimeoutSeconds = 15
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
$Script:PresetsDir = Join-Path (Join-Path $env:LOCALAPPDATA 'Hub') 'presets'

function Write-Pass { param([string]$M) Write-Host ('  [OK] '   + $M) -ForegroundColor Green }
function Write-Fail { param([string]$M) Write-Host ('  [FAIL] ' + $M) -ForegroundColor Red; $Script:Failures.Add($M) }

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

function Get-ItemId {
    param([string]$Name)
    $r = Invoke-RestMethod "$Script:BaseUrl/api/items" -TimeoutSec 5
    $item = @($r.items | Where-Object { $_.name -eq $Name }) | Select-Object -First 1
    return $(if ($item) { $item.id } else { $null })
}

Write-Host ''
Write-Host 'smoke-phase2-presets — presets + redaction + argv-preview' -ForegroundColor Cyan

try {
    Start-HubProcess
    Write-Pass 'Hub booted'
    $sess = New-HubSession

    $secretId = Get-ItemId 'secret-param'
    if (-not $secretId) { Write-Fail 'secret-param fixture not in catalog'; throw 'fixture missing' }
    Write-Pass "secret-param item id resolved"

    # --- POST preset with secrets + a benign value ---
    $body = @{ itemId = $secretId; name = 'my-preset'; values = @{ Password = 'hunter2'; ApiKey = 'sk-live-123'; Path = 'C:\keep' } }
    $r = Invoke-Api -Method POST -Path '/api/presets' -Body $body -Sess $sess
    if ($r.Status -eq 200) { Write-Pass 'POST /api/presets → 200' } else { Write-Fail "POST /api/presets → $($r.Status)" }
    $presetId = if ($r.Body) { $r.Body.id } else { $null }

    # --- GET list returns it (assert array + status, never body-null) ---
    $r = Invoke-Api -Method GET -Path "/api/presets?itemId=$secretId" -Sess $sess
    if ($r.Status -eq 200 -and @($r.Body).Count -ge 1) { Write-Pass 'GET /api/presets?itemId= returns the preset' } else { Write-Fail "GET presets list → $($r.Status) count=$(@($r.Body).Count)" }

    # --- ADV-201: read the file OFF DISK; secrets must be absent, benign present ---
    $files = @(Get-ChildItem -Path $Script:PresetsDir -Filter '*.json' -ErrorAction SilentlyContinue)
    if ($files.Count -ge 1) {
        $disk = Get-Content -Raw -Path $files[0].FullName
        if ($disk -notmatch 'hunter2'    -and $disk -notmatch '"Password"') { Write-Pass 'ADV-201: SecureString value NOT on disk' } else { Write-Fail 'ADV-201: Password leaked to disk' }
        if ($disk -notmatch 'sk-live-123' -and $disk -notmatch '"ApiKey"')   { Write-Pass 'ADV-201: plain-string secret (ApiKey) NOT on disk' } else { Write-Fail 'ADV-201: ApiKey leaked to disk' }
        if ($disk -match 'C:\\\\keep' -or $disk -match 'C:\\keep')           { Write-Pass 'benign Path value survives on disk' } else { Write-Fail 'benign Path value missing from disk' }
    } else {
        Write-Fail "no preset file written to $Script:PresetsDir"
    }

    # --- CSRF gate: POST without header → 403 ---
    # Use a FRESH session: PS7's WebRequestSession persists headers set via -Headers across
    # reused-session calls, so $sess would leak X-Hub-CSRF even when we omit it. A new
    # session has only the cookie (set by GET /), never the header.
    $sessNoCsrf = New-HubSession
    $r = Invoke-Api -Method POST -Path '/api/presets' -Body $body -Sess $sessNoCsrf -NoCsrf
    if ($r.Status -eq 403) { Write-Pass 'POST without CSRF → 403' } else { Write-Fail "POST without CSRF → $($r.Status) (expected 403)" }

    # --- unknown item rejected ---
    $r = Invoke-Api -Method POST -Path '/api/presets' -Body @{ itemId = 'nope-not-real'; name = 'x'; values = @{} } -Sess $sess
    if ($r.Status -eq 404) { Write-Pass 'unknown item → 404' } else { Write-Fail "unknown item → $($r.Status) (expected 404)" }

    # --- argv-preview: structure correct, secret masked (ADV-202) ---
    $r = Invoke-Api -Method POST -Path '/api/argv-preview' -Body @{ itemId = $secretId; values = @{ Path = 'a b'; Password = 'hunter2' } } -Sess $sess
    if ($r.Status -eq 200) { Write-Pass 'POST /api/argv-preview → 200' } else { Write-Fail "argv-preview → $($r.Status)" }
    if ($r.Body) {
        $argv = @($r.Body.argv)
        if ($argv -contains '-Path' -and $argv -contains 'a b') { Write-Pass "argv has discrete '-Path' + 'a b' (one element, no shell)" } else { Write-Fail "argv missing discrete Path element: $($argv -join '|')" }
        if (($r.Body.commandLineString -notmatch 'hunter2') -and ($r.Raw -notmatch 'hunter2')) { Write-Pass 'ADV-202: secret value masked in argv-preview' } else { Write-Fail 'ADV-202: secret value present in argv-preview' }
    }

    # --- argv-preview incomplete (none required here, so force via empty): still 200 ---
    $r = Invoke-Api -Method POST -Path '/api/argv-preview' -Body @{ itemId = $secretId; values = @{} } -Sess $sess
    if ($r.Status -eq 200) { Write-Pass 'argv-preview with empty values → 200 (best-effort)' } else { Write-Fail "argv-preview empty → $($r.Status)" }

    # --- History boundary (the OTHER secret surface): run via /api/run, then assert the
    #     history entry carries redacted params. Omit the SecureString (string→securestring
    #     binding would fail); ApiKey is a plain [string] that the heuristic must still drop. ---
    $r = Invoke-Api -Method POST -Path '/api/run' -Body @{ itemId = $secretId; values = @{ ApiKey = 'sk-hist-999'; Path = 'C:\histkeep' } } -Sess $sess
    if ($r.Status -eq 202 -and $r.Body.jobId) {
        Write-Pass 'POST /api/run (catalog) → 202'
        $deadline = (Get-Date).AddSeconds(10); $entry = $null
        while ((Get-Date) -lt $deadline) {
            $h = Invoke-Api -Method GET -Path '/api/history' -Sess $sess
            if ($h.Status -eq 200 -and $h.Body.entries) {
                $entry = @($h.Body.entries | Where-Object { $_.itemId -eq $secretId }) | Select-Object -First 1
                if ($entry) { break }
            }
            Start-Sleep -Milliseconds 400
        }
        if ($entry) {
            Write-Pass 'history entry written for catalog run'
            $hp = $entry.params
            $pathOk   = $hp -and ($hp.Path -eq 'C:\histkeep')
            $apiGone  = -not ($hp.PSObject.Properties.Name -contains 'ApiKey')
            $rawFalse = ($entry.rawArgsUsed -eq $false)
            if ($pathOk)   { Write-Pass 'history params.Path survives (job.values reached Write-HubHistory)' } else { Write-Fail "history params.Path missing — \$Job.values did NOT reach history" }
            if ($apiGone)  { Write-Pass 'history params has NO ApiKey secret (ADV-201 on history surface)' } else { Write-Fail 'history leaked ApiKey' }
            if (($h.Raw -notmatch 'sk-hist-999')) { Write-Pass 'history raw JSON contains no secret value' } else { Write-Fail 'history raw JSON leaked secret value' }
            if ($rawFalse) { Write-Pass 'history rawArgsUsed=false for typed run' } else { Write-Fail "history rawArgsUsed unexpected: $($entry.rawArgsUsed)" }
        } else {
            Write-Fail 'no history entry appeared for catalog run within timeout'
        }
    } else {
        Write-Fail "POST /api/run → $($r.Status) (expected 202)"
    }

    # --- DELETE → 200, list empty ---
    if ($presetId) {
        $r = Invoke-Api -Method DELETE -Path "/api/presets/$presetId" -Sess $sess
        if ($r.Status -eq 200) { Write-Pass 'DELETE /api/presets/<id> → 200' } else { Write-Fail "DELETE → $($r.Status)" }
        $r = Invoke-Api -Method GET -Path "/api/presets?itemId=$secretId" -Sess $sess
        if ($r.Status -eq 200 -and @($r.Body).Count -eq 0) { Write-Pass 'GET list empty after delete (and returns [] not null)' } else { Write-Fail "list after delete → $($r.Status) count=$(@($r.Body).Count)" }
    }

} catch {
    Write-Fail "exception: $($_.Exception.Message)"
} finally {
    Stop-Hub
    $env:TEMP = $Script:OrigTemp; $env:TMP = $Script:OrigTmp; $env:LOCALAPPDATA = $Script:OrigLocalAppData
    try { if ($Script:Sandbox -and (Test-Path -LiteralPath $Script:Sandbox)) { Remove-Item -LiteralPath $Script:Sandbox -Recurse -Force -ErrorAction SilentlyContinue } } catch { }
}

Write-Host ''
if ($Script:Failures.Count -eq 0) {
    Write-Host 'smoke-phase2-presets PASS' -ForegroundColor Green
    exit 0
} else {
    Write-Host ("smoke-phase2-presets FAIL ({0} issue(s)):" -f $Script:Failures.Count) -ForegroundColor Red
    foreach ($f in $Script:Failures) { Write-Host "  - $f" -ForegroundColor Red }
    exit 1
}
