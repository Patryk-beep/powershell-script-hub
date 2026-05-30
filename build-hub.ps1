# build-hub.ps1
# Compiles Hub.ps1 -> Hub.exe via PS2EXE. Models the WavTo16k rebuild pattern.
#
# Usage:
#   pwsh -File build-hub.ps1                       # build + smoke
#   pwsh -File build-hub.ps1 -Version 1.0.1.0      # bump version
#   pwsh -File build-hub.ps1 -SkipSmoke            # skip post-build smoke

[CmdletBinding()]
param(
    [string]$Version    = '1.6.0.0',
    [switch]$SkipSmoke
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = $PSScriptRoot
$source      = Join-Path $projectRoot 'Hub.ps1'
$output      = Join-Path $projectRoot 'Hub.exe'
$icon        = Join-Path $projectRoot 'Hub.ico'
$smoke       = Join-Path $projectRoot 'tests\smoke-final.ps1'

function Write-Step { param([string]$M) Write-Host "==> $M" -ForegroundColor Cyan }

# --- 1. Parse-check (catch syntax errors before PS2EXE swallows them) ---
Write-Step 'Parse-checking Hub.ps1'
$tokens = $null
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile(
    $source, [ref]$tokens, [ref]$errors) | Out-Null
if ($errors -and $errors.Count -gt 0) {
    $errors | ForEach-Object {
        Write-Host ("PARSE ERROR @ line {0}: {1}" -f $_.Extent.StartLineNumber, $_.Message) -ForegroundColor Red
    }
    exit 1
}
Write-Host '  OK'

# --- 2. Kill any running Hub instances so the .exe isn't locked ---
Write-Step 'Killing running Hub.exe instances'
$running = Get-CimInstance Win32_Process -Filter "Name='Hub.exe'"
foreach ($r in @($running)) {
    Write-Host "  Stopping PID $($r.ProcessId)"
    Stop-Process -Id $r.ProcessId -Force -ErrorAction SilentlyContinue
}
if ($running) { Start-Sleep -Milliseconds 600 }

# --- 3. Verify Hub.ico exists (regenerate if missing) ---
if (-not (Test-Path -LiteralPath $icon)) {
    Write-Step 'Hub.ico missing — running build-icon.ps1'
    & (Join-Path $projectRoot 'build-icon.ps1')
}

# --- 4. ExecutionPolicy override + load PS2EXE ---
# OneDrive-redirected Documents\PowerShell\Modules has Restricted policy by default
# (WavTo16k HANDOFF §3 lesson). Process-scoped override is enough.
Write-Step 'Loading ps2exe'
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
try {
    Import-Module ps2exe -ErrorAction Stop
} catch {
    Write-Host '  ps2exe module not installed.' -ForegroundColor Red
    Write-Host '  Install with: Install-Module ps2exe -Scope CurrentUser' -ForegroundColor Yellow
    exit 1
}

# --- 5. Compile ---
Write-Step "Compiling Hub.ps1 -> Hub.exe (v$Version)"
$ps2exeArgs = @{
    inputFile   = $source
    outputFile  = $output
    iconFile    = $icon
    noConsole   = $true   # GUI subsystem — required, see WavTo16k §4
    STA         = $true   # WinForms requires single-thread apartment
    title       = 'Hub - Script & Tool Dashboard'
    description = 'Local web dashboard for PowerShell scripts and .exe tools'
    company     = 'Hub'
    product     = 'Hub'
    version     = $Version
}
Invoke-PS2EXE @ps2exeArgs

if (-not (Test-Path -LiteralPath $output)) {
    Write-Host 'Compile produced no output.' -ForegroundColor Red
    exit 1
}
$size = (Get-Item -LiteralPath $output).Length
Write-Host ("  Hub.exe: $size bytes")

# --- 6. Optional smoke ---
if (-not $SkipSmoke) {
    Write-Step 'Running final smoke test against Hub.exe'
    if (-not (Test-Path -LiteralPath $smoke)) {
        Write-Host '  tests\smoke-final.ps1 missing — skipping' -ForegroundColor Yellow
    } else {
        & $smoke
        if ($LASTEXITCODE -ne 0) {
            Write-Host 'Final smoke FAILED.' -ForegroundColor Red
            exit $LASTEXITCODE
        }
    }
}

Write-Step "Done. Hub.exe v$Version is at $output"
