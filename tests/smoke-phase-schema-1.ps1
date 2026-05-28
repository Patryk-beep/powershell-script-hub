#Requires -Version 5.1
# Phase-schema-1 smoke — extended ConvertTo-WidgetSpec coverage on all-widgets.ps1 fixture.
# Asserts every new type + validator + metadata mapping introduced in Phase 1.

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

# === SETUP ===
foreach ($f in @('hub-error.log','hub.port','hub-fixture-executed.flag')) {
    try { [System.IO.File]::Delete((Join-Path $env:TEMP $f)) } catch { }
}

Write-Host ''
Write-Host 'Phase-schema-1 smoke (extended autodetect coverage)' -ForegroundColor Cyan
Write-Host ('  Hub source: ' + $HubScript)
Write-Host ('  Fixtures:   ' + $Script:Fixtures)

try {
    $Script:HubProc = Start-HubProcess
    Write-Step ("Started Hub PID $($Script:HubProc.Id) — waiting for /api/health")
    if (-not (Wait-HubReady -TimeoutSeconds $BootTimeoutSeconds)) {
        $logPath = Join-Path $env:TEMP 'hub-error.log'
        $log = if (Test-Path $logPath) { Get-Content -Raw -LiteralPath $logPath } else { '(no error log)' }
        Write-Fail ("Hub did not become healthy within $BootTimeoutSeconds s. Log:`n$log")
        Stop-Hub
        exit 1
    }
    Write-Pass 'Hub booted'

    $catalog = Invoke-RestMethod -Uri "http://127.0.0.1:$Script:HubPort/api/items" -TimeoutSec 5
    $items   = @($catalog.items)
    $allw    = $items | Where-Object { $_.name -eq 'all-widgets' } | Select-Object -First 1
    if (-not $allw) { Write-Fail 'all-widgets fixture not discovered'; throw 'fixture-missing' }
    Write-Pass "all-widgets fixture discovered ($($allw.id))"

    $schema = Invoke-RestMethod -Uri "http://127.0.0.1:$Script:HubPort/api/items/$($allw.id)/schema" -TimeoutSec 5
    if ($schema.mode -ne 'typed') { Write-Fail "Schema mode='$($schema.mode)', expected typed"; throw 'mode' }
    Write-Pass "Schema mode = typed"

    $fields = @($schema.fields)
    Write-Pass "Field count: $($fields.Count)"

    function Get-Field { param([string]$Name) ($fields | Where-Object { $_.name -eq $Name } | Select-Object -First 1) }
    function Assert-Field {
        param([string]$Name, [scriptblock]$Check, [string]$Desc)
        $f = Get-Field $Name
        if (-not $f) { Write-Fail "$Name missing"; return }
        try {
            $ok = & $Check $f
            if ($ok) { Write-Pass "$Name — $Desc" } else { Write-Fail "$Name failed check: $Desc (got widget='$($f.widget)')" }
        } catch { Write-Fail "$Name check threw: $($_.Exception.Message)" }
    }

    # ===========================================================
    # Type-to-widget mappings (new)
    # ===========================================================
    Write-Host ''
    Write-Host 'Type-to-widget mappings'

    Assert-Field 'Name'    { param($f) $f.widget -eq 'textbox' }          'textbox'
    Assert-Field 'Count'   { param($f) $f.widget -eq 'number' }           'number (int)'
    Assert-Field 'Ratio'   { param($f) $f.widget -eq 'number' -and $f.step -eq 'any' } 'number step=any (double)'
    Assert-Field 'Price'   { param($f) $f.widget -eq 'number' -and $f.step -eq 'any' } 'number step=any (decimal)'
    Assert-Field 'Enabled' { param($f) $f.widget -eq 'checkbox' }          'checkbox (bool)'
    Assert-Field 'Force'   { param($f) $f.widget -eq 'checkbox-switch' }   'checkbox-switch'
    Assert-Field 'When'    { param($f) $f.widget -eq 'datetime-local' }    'datetime-local'
    Assert-Field 'Id'      { param($f) $f.widget -eq 'textbox' -and $f.pattern -match '^\^\[0-9a-fA-F-\]\{36\}\$$' } 'guid → textbox with pattern'
    Assert-Field 'Target'  { param($f) $f.widget -eq 'url' }               'url (uri)'
    Assert-Field 'Pin'     { param($f) $f.widget -eq 'password' -and $f.help -match 'loopback' } 'password (securestring) with help note'
    Assert-Field 'Tags'    { param($f) $f.widget -eq 'textarea-multi' }    'textarea-multi (string[])'
    Assert-Field 'Map'     { param($f) $f.widget -eq 'textarea-multi' -and $f.help -match 'key=value' } 'hashtable → textarea-multi with hint'
    Assert-Field 'InputFile' { param($f) $f.widget -eq 'file' }            'file (FileInfo)'

    # ===========================================================
    # Validators
    # ===========================================================
    Write-Host ''
    Write-Host 'Validators'

    Assert-Field 'Mode'    { param($f) $f.widget -eq 'dropdown' -and (@($f.options) -join ',') -eq 'a,b,c' } 'ValidateSet → dropdown'
    Assert-Field 'Retries' { param($f) $f.widget -eq 'number' -and [int]$f.min -eq 1 -and [int]$f.max -eq 99 } 'ValidateRange → min/max'
    Assert-Field 'Slug'    { param($f) $f.pattern -eq '^[a-z]+$' } 'ValidatePattern → pattern'
    Assert-Field 'Code'    { param($f) [int]$f.minlength -eq 3 -and [int]$f.maxlength -eq 20 } 'ValidateLength → minlength/maxlength'
    Assert-Field 'NonEmpty'{ param($f) $f.required -eq $true } 'ValidateNotNullOrEmpty → required=true'

    # ===========================================================
    # Metadata (aliases / sets / position / comment-help)
    # ===========================================================
    Write-Host ''
    Write-Host 'Metadata'

    Assert-Field 'Destination' { param($f) (@($f.aliases) -join ',') -eq 'Out,Output' } 'Alias array'
    Assert-Field 'Required'    { param($f) $f.required -and $f.help -eq 'hm' } 'Mandatory + HelpMessage'
    Assert-Field 'AlphaOnly'   { param($f) $f.parameterSet -eq 'SetA' -and [int]$f.position -eq 0 } 'ParameterSet=SetA + Position=0'
    Assert-Field 'BetaOnly'    { param($f) $f.parameterSet -eq 'SetB' -and [int]$f.position -eq 0 } 'ParameterSet=SetB + Position=0'
    # Comment-based help on Name (no HelpMessage attr on Name) — should pull "Friendly display name"
    Assert-Field 'Name'        { param($f) $f.help -match 'display name' } 'Comment-based .PARAMETER help fallback'
    Assert-Field 'Slug'        { param($f) $f.help -match 'slug' } 'Comment-based help also reaches Slug'

    # ===========================================================
    # schemaMode field present
    # ===========================================================
    Write-Host ''
    Write-Host 'schemaMode field'
    if ($schema.PSObject.Properties.Name -contains 'schemaMode') {
        Write-Pass "schemaMode = '$($schema.schemaMode)'"
    } else {
        Write-Fail 'schemaMode field missing from /api/items/{id}/schema response'
    }

    # ===========================================================
    # Sentinel — no script execution during schema fetch
    # ===========================================================
    Write-Host ''
    Write-Host 'Sentinel — AST-only introspection'
    # all-widgets.ps1 body line is `Write-Output 'ok'` (no side-effect to filesystem),
    # so we rely on stderr/log absence + execution time. Repeat hit and ensure no error log.
    Invoke-RestMethod -Uri "http://127.0.0.1:$Script:HubPort/api/items/$($allw.id)/schema" -TimeoutSec 5 | Out-Null
    Start-Sleep -Milliseconds 300
    $logPath = Join-Path $env:TEMP 'hub-error.log'
    if (Test-Path $logPath) {
        $log = Get-Content -Raw -LiteralPath $logPath
        if ($log -match 'EXECUTED' -or $log -match 'all-widgets.ps1.*executed') {
            Write-Fail "Error log shows fixture execution markers!"
        } else {
            Write-Pass 'No execution markers in hub-error.log'
        }
    } else {
        Write-Pass 'No error log produced'
    }

} finally {
    Stop-Hub
}

Write-Host ''
if ($Script:Failures.Count -eq 0) {
    Write-Host ('Phase-schema-1 smoke PASS — extended autodetect verified') -ForegroundColor Green
    exit 0
} else {
    Write-Host ("Phase-schema-1 smoke FAIL ({0} issues)" -f $Script:Failures.Count) -ForegroundColor Red
    foreach ($f in $Script:Failures) { Write-Host "  - $f" -ForegroundColor Red }
    exit 1
}
