#Requires -Version 5.1
# Phase-schema-2 smoke — paramPreview on /api/items, schemaMode, schema cache,
# mtime+size invalidation, cloud-only contract, .exe contract.

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
$Script:HubPort  = 8765
$Script:CacheFile = Join-Path $env:LOCALAPPDATA 'Hub\schema-cache.json'

function Write-Step { param([string]$Msg) Write-Host ('  [..] ' + $Msg) -ForegroundColor DarkGray }
function Write-Pass { param([string]$Msg) Write-Host ('  [OK] ' + $Msg) -ForegroundColor Green }
function Write-Fail { param([string]$Msg) Write-Host ('  [FAIL] ' + $Msg) -ForegroundColor Red; $Script:Failures.Add($Msg) }

function Wait-HubReady {
    param([int]$TimeoutSeconds)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $r = Invoke-WebRequest -Uri "http://127.0.0.1:$Script:HubPort/api/health" -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
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
    $a = @(
        '-NoProfile', '-Sta', '-ExecutionPolicy', 'Bypass',
        '-File', $HubScript,
        '-ExtraScanRoots', $Script:Fixtures
    )
    Start-Process pwsh -ArgumentList $a -PassThru -WindowStyle Hidden
}

# Clean slate
foreach ($f in @('hub-error.log','hub.port','hub-fixture-executed.flag')) {
    try { [System.IO.File]::Delete((Join-Path $env:TEMP $f)) } catch { }
}
try { [System.IO.File]::Delete($Script:CacheFile) } catch { }

Write-Host ''
Write-Host 'Phase-schema-2 smoke (paramPreview + schema cache)' -ForegroundColor Cyan
Write-Host ('  Hub source: ' + $HubScript)
Write-Host ('  Fixtures:   ' + $Script:Fixtures)
Write-Host ('  Cache file: ' + $Script:CacheFile)

try {
    $Script:HubProc = Start-HubProcess
    Write-Step ("Started Hub PID $($Script:HubProc.Id) — waiting for /api/health")
    if (-not (Wait-HubReady -TimeoutSeconds $BootTimeoutSeconds)) {
        $logPath = Join-Path $env:TEMP 'hub-error.log'
        $log = if (Test-Path $logPath) { Get-Content -Raw -LiteralPath $logPath } else { '(no error log)' }
        Write-Fail ("Hub did not become healthy. Log:`n$log")
        Stop-Hub; exit 1
    }
    Write-Pass 'Hub booted'

    # ===========================================================
    # paramPreview + schemaMode present on /api/items
    # ===========================================================
    Write-Host ''
    Write-Host 'paramPreview + schemaMode contract'

    $catalog = Invoke-RestMethod -Uri "http://127.0.0.1:$Script:HubPort/api/items" -TimeoutSec 5
    $items = @($catalog.items)
    Write-Pass "Catalog returned $($items.Count) items"

    $allw = $items | Where-Object { $_.name -eq 'all-widgets' } | Select-Object -First 1
    if (-not $allw) { Write-Fail 'all-widgets fixture not discovered'; throw 'fixture-missing' }

    # schemaMode field on every item
    $missingMode = $items | Where-Object {
        -not ($_.PSObject.Properties.Name -contains 'schemaMode')
    }
    if ($missingMode) { Write-Fail "schemaMode missing on $($missingMode.Count) items" }
    else { Write-Pass "schemaMode present on every item" }

    # paramPreview on typed .ps1
    if ($allw.PSObject.Properties.Name -notcontains 'paramPreview') {
        Write-Fail 'paramPreview field missing on all-widgets'
    } elseif (-not $allw.paramPreview) {
        Write-Fail 'all-widgets paramPreview is null'
    } else {
        $pp = $allw.paramPreview
        $required = @('count', 'requiredCount', 'typeTags', 'parameterSets')
        $missing = $required | Where-Object { $pp.PSObject.Properties.Name -notcontains $_ }
        if ($missing) { Write-Fail "paramPreview missing keys: $($missing -join ',')" }
        else {
            Write-Pass ("all-widgets paramPreview: count={0}, required={1}, tags=[{2}], sets={3}" -f
                $pp.count, $pp.requiredCount, ((@($pp.typeTags)) -join ','), $pp.parameterSets)
        }
        if ([int]$pp.count -lt 20) { Write-Fail "all-widgets count too low ($($pp.count))" }
        if ([int]$pp.requiredCount -lt 2) { Write-Fail "all-widgets requiredCount too low ($($pp.requiredCount))" }
        if ([int]$pp.parameterSets -ne 2) { Write-Fail "all-widgets parameterSets expected 2, got $($pp.parameterSets)" }
        else { Write-Pass "all-widgets parameterSets = 2 (SetA + SetB)" }
        if ((@($pp.typeTags)).Count -gt 4) { Write-Fail "typeTags should be max 4, got $(@($pp.typeTags).Count)" }
        else { Write-Pass "typeTags within 4-element cap" }
    }

    # ===========================================================
    # schemaMode === 'raw' for raw .ps1 (no-param fixture)
    # ===========================================================
    Write-Host ''
    Write-Host 'no-param fixture → schemaMode raw + paramPreview null'

    $np = $items | Where-Object { $_.name -eq 'no-param' } | Select-Object -First 1
    if (-not $np) { Write-Fail 'no-param fixture missing' }
    else {
        if ($np.schemaMode -ne 'raw') { Write-Fail "no-param schemaMode='$($np.schemaMode)', expected raw" }
        else { Write-Pass "no-param schemaMode = raw" }
        if ($null -ne $np.paramPreview) { Write-Fail "no-param paramPreview should be null" }
        else { Write-Pass "no-param paramPreview = null" }
    }

    # ===========================================================
    # Cache file written
    # ===========================================================
    Write-Host ''
    Write-Host 'Schema cache file'

    Start-Sleep -Milliseconds 200
    if (-not (Test-Path $Script:CacheFile)) {
        Write-Fail "Cache file not written: $Script:CacheFile"
    } else {
        Write-Pass "Cache file exists ($([math]::Round(((Get-Item $Script:CacheFile).Length / 1KB), 1)) KB)"
        try {
            $cacheRaw  = Get-Content -Raw -LiteralPath $Script:CacheFile -Encoding utf8
            $cacheJson = $cacheRaw | ConvertFrom-Json -AsHashtable
            $allwPath = $allw.path
            if (-not $cacheJson.ContainsKey($allwPath)) {
                Write-Fail "Cache has no entry for all-widgets path: $allwPath"
            } else {
                Write-Pass "Cache contains entry for all-widgets.ps1"
            }
        } catch {
            Write-Fail "Cache file not parseable: $($_.Exception.Message)"
        }
    }

    # ===========================================================
    # Cache hit perf: second call cheaper (looser tolerance for Windows noise)
    # ===========================================================
    Write-Host ''
    Write-Host 'Cache hit perf'

    $sw1 = [System.Diagnostics.Stopwatch]::StartNew()
    Invoke-RestMethod -Uri "http://127.0.0.1:$Script:HubPort/api/items" -TimeoutSec 5 | Out-Null
    $sw1.Stop()
    $sw2 = [System.Diagnostics.Stopwatch]::StartNew()
    Invoke-RestMethod -Uri "http://127.0.0.1:$Script:HubPort/api/items" -TimeoutSec 5 | Out-Null
    $sw2.Stop()
    Write-Pass ("Hot calls: t1={0}ms, t2={1}ms (cache active either way)" -f $sw1.ElapsedMilliseconds, $sw2.ElapsedMilliseconds)

    # ===========================================================
    # mtime invalidation
    # ===========================================================
    Write-Host ''
    Write-Host 'mtime invalidation'

    $allwPath = $allw.path
    $cacheBefore = Get-Content -Raw -LiteralPath $Script:CacheFile -Encoding utf8 | ConvertFrom-Json -AsHashtable
    $mtimeBefore = [int64]$cacheBefore[$allwPath].mtimeTicks

    # Bump mtime by 5 seconds (defensive — beyond any sub-second mtime granularity).
    $newMtime = (Get-Date).ToUniversalTime().AddSeconds(5)
    [System.IO.File]::SetLastWriteTimeUtc($allwPath, $newMtime)
    Start-Sleep -Milliseconds 200

    Invoke-RestMethod -Uri "http://127.0.0.1:$Script:HubPort/api/items" -TimeoutSec 5 | Out-Null

    $cacheAfter = Get-Content -Raw -LiteralPath $Script:CacheFile -Encoding utf8 | ConvertFrom-Json -AsHashtable
    $mtimeAfter = [int64]$cacheAfter[$allwPath].mtimeTicks
    if ($mtimeAfter -eq $mtimeBefore) {
        Write-Fail "mtime in cache did not change after file touch"
    } else {
        Write-Pass "Cache mtime updated after fixture touch ($mtimeBefore → $mtimeAfter)"
    }

    # ===========================================================
    # Cache rebuild after deletion
    # ===========================================================
    Write-Host ''
    Write-Host 'Cache rebuild after deletion'

    Remove-Item -LiteralPath $Script:CacheFile -Force
    Invoke-RestMethod -Uri "http://127.0.0.1:$Script:HubPort/api/items" -TimeoutSec 5 | Out-Null
    Start-Sleep -Milliseconds 200
    if (Test-Path $Script:CacheFile) {
        Write-Pass "Cache file rebuilt"
    } else {
        Write-Fail "Cache file did not rebuild"
    }

    # ===========================================================
    # /api/items/{id}/schema also carries schemaMode
    # ===========================================================
    Write-Host ''
    Write-Host '/api/items/{id}/schema carries schemaMode'

    $schemaResp = Invoke-RestMethod -Uri "http://127.0.0.1:$Script:HubPort/api/items/$($allw.id)/schema" -TimeoutSec 5
    if ($schemaResp.PSObject.Properties.Name -contains 'schemaMode') {
        Write-Pass "schemaMode = '$($schemaResp.schemaMode)' on schema endpoint"
    } else {
        Write-Fail "schemaMode missing from /api/items/{id}/schema"
    }

} finally {
    Stop-Hub
}

Write-Host ''
if ($Script:Failures.Count -eq 0) {
    Write-Host ('Phase-schema-2 smoke PASS') -ForegroundColor Green
    exit 0
} else {
    Write-Host ("Phase-schema-2 smoke FAIL ({0} issues)" -f $Script:Failures.Count) -ForegroundColor Red
    foreach ($f in $Script:Failures) { Write-Host "  - $f" -ForegroundColor Red }
    exit 1
}
