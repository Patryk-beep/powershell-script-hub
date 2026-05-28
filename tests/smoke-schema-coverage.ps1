#Requires -Version 5.1
# Aggregate coverage smoke — re-runs phase-schema-1, phase-schema-2, phase-schema-3 in sequence
# AND adds end-to-end / contract assertions called for by P4 design doc § 9.

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
$Script:Sentinel  = Join-Path $Script:Fixtures 'sentinel-coverage.ps1'

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
    Start-Process pwsh -ArgumentList "-NoProfile -Sta -ExecutionPolicy Bypass -File `"$HubScript`" -ExtraScanRoots `"$Script:Fixtures`"" -PassThru -WindowStyle Hidden
}

Write-Host ''
Write-Host '=== smoke-schema-coverage — aggregate verification ===' -ForegroundColor Cyan

# --- Sub-smoke runs (delegate to phase-specific files) ---
foreach ($sub in @('smoke-phase-schema-1.ps1','smoke-phase-schema-2.ps1','smoke-phase-schema-3.ps1')) {
    Write-Host ''
    Write-Host "--- $sub ---" -ForegroundColor Yellow
    pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot $sub)
    if ($LASTEXITCODE -ne 0) { Write-Fail "$sub exited $LASTEXITCODE" } else { Write-Pass "$sub green" }
}

# --- Additional contract + sentinel checks ---
foreach ($f in @('hub-error.log','hub.port')) {
    try { [System.IO.File]::Delete((Join-Path $env:TEMP $f)) } catch { }
}

# Write a fresh sentinel fixture whose body would write a file to TEMP if executed.
$sentinelFlag = Join-Path $env:TEMP 'hub-sentinel-coverage.flag'
try { [System.IO.File]::Delete($sentinelFlag) } catch { }
@"
# Sentinel for smoke-schema-coverage — body MUST NOT run during catalog scan or schema fetch.
param([string]`$X)
Set-Content -LiteralPath '$sentinelFlag' -Value 'EXECUTED' -Encoding utf8
Write-Output 'EXECUTED'
"@ | Set-Content -LiteralPath $Script:Sentinel -Encoding utf8

try {
    Write-Host ''
    Write-Host '--- Contract + sentinel ---' -ForegroundColor Yellow

    $Script:HubProc = Start-HubProcess
    if (-not (Wait-HubReady -TimeoutSeconds $BootTimeoutSeconds)) {
        Write-Fail 'Hub did not boot for coverage smoke'
        Stop-Hub
    } else {
        Write-Pass 'Hub booted'

        $base = "http://127.0.0.1:$Script:HubPort"
        $catalog = Invoke-RestMethod -Uri "$base/api/items" -TimeoutSec 5
        $items = @($catalog.items)

        # /api/items contract: every item carries schemaMode; paramPreview present on typed ps1; null on cloud / exe.
        $missingMode = $items | Where-Object { -not ($_.PSObject.Properties.Name -contains 'schemaMode') }
        if ($missingMode) { Write-Fail "schemaMode missing on $($missingMode.Count) items" }
        else { Write-Pass 'schemaMode present on every item' }

        $exeBad = $items | Where-Object { $_.kind -eq 'exe' -and $null -ne $_.paramPreview }
        if ($exeBad) { Write-Fail ".exe item has non-null paramPreview" }
        else { Write-Pass '.exe items have paramPreview = null' }

        $cloudBad = $items | Where-Object { $_.cloudOnly -and ($null -ne $_.paramPreview) }
        if ($cloudBad) { Write-Fail "cloud-only item has paramPreview" }
        else { Write-Pass 'cloud-only items have paramPreview = null' }

        # sentinel: schema fetch must NOT execute the script body.
        $sentItem = $items | Where-Object { $_.name -eq 'sentinel-coverage' } | Select-Object -First 1
        if (-not $sentItem) { Write-Fail 'sentinel fixture not discovered' }
        else {
            Invoke-RestMethod -Uri "$base/api/items/$($sentItem.id)/schema" -TimeoutSec 5 | Out-Null
            Start-Sleep -Milliseconds 300
            if (Test-Path -LiteralPath $sentinelFlag) {
                Write-Fail 'SENTINEL: schema fetch EXECUTED the script — security violation'
            } else {
                Write-Pass 'Sentinel: schema fetch did NOT execute the script'
            }
        }

        # cache file existence
        if (Test-Path $Script:CacheFile) { Write-Pass 'cache file written' }
        else { Write-Fail 'cache file missing' }
    }
} finally {
    Stop-Hub
    try { [System.IO.File]::Delete($Script:Sentinel) } catch { }
    try { [System.IO.File]::Delete($sentinelFlag) } catch { }
}

Write-Host ''
if ($Script:Failures.Count -eq 0) {
    Write-Host 'smoke-schema-coverage PASS' -ForegroundColor Green
    exit 0
} else {
    Write-Host ("smoke-schema-coverage FAIL ({0} issues)" -f $Script:Failures.Count) -ForegroundColor Red
    foreach ($f in $Script:Failures) { Write-Host "  - $f" -ForegroundColor Red }
    exit 1
}
