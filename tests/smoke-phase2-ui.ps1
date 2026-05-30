#Requires -Version 5.1
# smoke-phase2-ui.ps1 — Phase 2 frontend static smoke: presets UI, "what will run"
# argv preview, log viewer (filter/ANSI/wrap/copy/download), history re-run. Static
# assertions over served assets (like smoke-canvas-editor.ps1). Runs beside live Hub.exe.

[CmdletBinding()]
param(
    [string]$HubScript = (Join-Path (Split-Path -Parent $PSScriptRoot) 'Hub.ps1'),
    [int]$Port = 8799,
    [int]$BootTimeoutSeconds = 15
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:OrigTemp = $env:TEMP; $Script:OrigTmp = $env:TMP; $Script:OrigLocalAppData = $env:LOCALAPPDATA
$Script:Sandbox = Join-Path $Script:OrigTemp ('hub-smoke-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
[System.IO.Directory]::CreateDirectory($Script:Sandbox) | Out-Null
$env:TEMP = $Script:Sandbox; $env:TMP = $Script:Sandbox; $env:LOCALAPPDATA = $Script:Sandbox

$Script:Failures = New-Object 'System.Collections.Generic.List[string]'
$Script:HubProc  = $null
$Script:Fixtures = Join-Path $PSScriptRoot 'fixtures'
$Script:BaseUrl  = "http://127.0.0.1:$Port"

function Write-Pass { param([string]$M) Write-Host ('  [OK] '   + $M) -ForegroundColor Green }
function Write-Fail { param([string]$M) Write-Host ('  [FAIL] ' + $M) -ForegroundColor Red; $Script:Failures.Add($M) }
function Assert-Has { param([string]$Hay,[string]$Needle,[string]$Label) if ($Hay -match [regex]::Escape($Needle)) { Write-Pass $Label } else { Write-Fail "$Label — missing '$Needle'" } }
function Stop-Hub { if ($Script:HubProc -and -not $Script:HubProc.HasExited) { & taskkill.exe /T /F /PID $Script:HubProc.Id 2>$null | Out-Null }; $Script:HubProc = $null; Start-Sleep -Milliseconds 600 }

Write-Host ''
Write-Host 'smoke-phase2-ui — presets / argv-preview / log viewer / re-run' -ForegroundColor Cyan
try {
    $Script:HubProc = Start-Process pwsh `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$HubScript`" -ExtraScanRoots `"$Script:Fixtures`" -SkipMutex -Port $Port" `
        -PassThru -WindowStyle Hidden
    $deadline = (Get-Date).AddSeconds($BootTimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try { $r = Invoke-WebRequest "$Script:BaseUrl/api/health" -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop; if ($r.StatusCode -eq 200) { break } } catch { Start-Sleep -Milliseconds 300 }
    }
    Write-Pass 'Hub booted'

    $html = (Invoke-WebRequest "$Script:BaseUrl/" -UseBasicParsing -TimeoutSec 5).Content
    $app  = (Invoke-WebRequest "$Script:BaseUrl/app.js" -UseBasicParsing -TimeoutSec 5).Content
    $pres = (Invoke-WebRequest "$Script:BaseUrl/presets.js" -UseBasicParsing -TimeoutSec 5).Content
    $logv = (Invoke-WebRequest "$Script:BaseUrl/logviewer.js" -UseBasicParsing -TimeoutSec 5).Content
    $css  = (Invoke-WebRequest "$Script:BaseUrl/style.css" -UseBasicParsing -TimeoutSec 5).Content

    Write-Host ''; Write-Host '--- assets served + wired ---'
    Assert-Has $html 'presets.js'   'presets.js script tag'
    Assert-Has $html 'logviewer.js' 'logviewer.js script tag'
    Assert-Has $app  '...presetsMixin()'   'presetsMixin spread'
    Assert-Has $app  '...logViewerMixin()' 'logViewerMixin spread'
    Assert-Has $app  'reRunFromHistory'    'reRunFromHistory method'

    Write-Host ''; Write-Host '--- presets + argv-preview UI ---'
    Assert-Has $html 'presets-bar'   'presets bar markup'
    Assert-Has $html 'savePreset()'  'save-preset binding'
    Assert-Has $html 'applyPreset(p)' 'apply-preset binding'
    Assert-Has $html 'argv-preview'  '"what will run" block'
    Assert-Has $html 'argv-tok'      'argv token chips'
    Assert-Has $pres 'fetchArgvPreview' 'argv-preview fetch method'

    Write-Host ''; Write-Host '--- log viewer ---'
    Assert-Has $html 'log-filter'      'log filter input'
    Assert-Has $html 'ansiToHtml('     'ANSI render in log pane (x-html)'
    Assert-Has $html 'logMatches('     'log filter binding'
    Assert-Has $html 'toggleLogWrap()' 'wrap toggle binding'
    Assert-Has $html 'copyLog()'       'copy binding'
    Assert-Has $html 'downloadLog()'   'download binding'
    # XSS ordering: escape MUST precede colorization in ansiToHtml.
    $escIdx = $logv.IndexOf('_escapeHtml(s.slice(last, m.index))')
    $spanIdx = $logv.IndexOf('<span class=')
    if ($escIdx -ge 0 -and $spanIdx -ge 0 -and $escIdx -lt $spanIdx) { Write-Pass 'ansiToHtml escapes BEFORE injecting spans (XSS-safe ordering)' } else { Write-Fail 'ansiToHtml escape/span ordering not verified' }

    Write-Host ''; Write-Host '--- history re-run + css ---'
    Assert-Has $html 'reRunFromHistory(e)' 'history re-run button'
    Assert-Has $css  '.argv-tok'   'argv token style'
    Assert-Has $css  '.ansi-fg-1'  'ANSI color class'
    Assert-Has $css  '.preset-chip' 'preset chip style'

    Write-Host ''; Write-Host '--- backend route regression (served by Hub.ps1) ---'
    $r = Invoke-WebRequest "$Script:BaseUrl/api/presets" -UseBasicParsing -TimeoutSec 5 -SkipHttpErrorCheck
    if ([int]$r.StatusCode -eq 200) { Write-Pass 'GET /api/presets → 200 (route live, not 503)' } else { Write-Fail "GET /api/presets → $([int]$r.StatusCode)" }

} catch {
    Write-Fail "exception: $($_.Exception.Message)"
} finally {
    Stop-Hub
    $env:TEMP = $Script:OrigTemp; $env:TMP = $Script:OrigTmp; $env:LOCALAPPDATA = $Script:OrigLocalAppData
    try { if ($Script:Sandbox -and (Test-Path -LiteralPath $Script:Sandbox)) { Remove-Item -LiteralPath $Script:Sandbox -Recurse -Force -ErrorAction SilentlyContinue } } catch { }
}

Write-Host ''
if ($Script:Failures.Count -eq 0) { Write-Host 'smoke-phase2-ui PASS' -ForegroundColor Green; exit 0 }
else { Write-Host ("smoke-phase2-ui FAIL ({0}):" -f $Script:Failures.Count) -ForegroundColor Red; foreach ($f in $Script:Failures) { Write-Host "  - $f" -ForegroundColor Red }; exit 1 }
