#Requires -Version 5.1
# smoke-canvas-editor.ps1 — Canvas workflow editor smoke.
# Runs against a Hub already listening on $Port (default 8765).
# If Hub is not running, starts Hub.ps1 on a separate port (8770) with -Port override.

[CmdletBinding()]
param(
    [string]$HubScript = (Join-Path (Split-Path -Parent $PSScriptRoot) 'Hub.ps1'),
    [int]$Port = 8765,
    [int]$AltPort = 8770,
    [int]$BootTimeoutSeconds = 18
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:Failures = New-Object 'System.Collections.Generic.List[string]'
$Script:OwnedProc = $null     # only set if we started Hub ourselves
$Script:HubPort   = $Port

function Write-Pass { param([string]$M) Write-Host ('  [OK] '   + $M) -ForegroundColor Green }
function Write-Fail { param([string]$M) Write-Host ('  [FAIL] ' + $M) -ForegroundColor Red; $Script:Failures.Add($M) }
function Assert-Has { param([string]$Hay,[string]$Needle,[string]$Label) if ($Hay -match [regex]::Escape($Needle)) { Write-Pass $Label } else { Write-Fail "$Label — missing '$Needle'" } }

function Stop-OwnedHub {
    if ($Script:OwnedProc -and -not $Script:OwnedProc.HasExited) {
        & taskkill.exe /T /F /PID $Script:OwnedProc.Id 2>$null | Out-Null
    }
    $Script:OwnedProc = $null
    Start-Sleep -Milliseconds 800
}

function Start-HubOnAltPort {
    $Script:OwnedProc = Start-Process pwsh `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$HubScript`" -Port $AltPort -ExtraScanRoots `"$(Join-Path $PSScriptRoot 'fixtures')`"" `
        -PassThru -WindowStyle Hidden
    $script:HubPort = $AltPort
    $deadline = (Get-Date).AddSeconds($BootTimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $r = Invoke-WebRequest "http://127.0.0.1:$AltPort/api/health" -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
            if ($r.StatusCode -eq 200) { Write-Pass "Hub started on alt-port $AltPort"; return }
        } catch { Start-Sleep -Milliseconds 400 }
    }
    throw "Hub did not boot on port $AltPort within ${BootTimeoutSeconds}s"
}

function Invoke-Api {
    param([string]$Method, [string]$Path, $Body = $null, [hashtable]$Sess = $null)
    $base = "http://127.0.0.1:$Script:HubPort"
    $headers = @{ 'Content-Type' = 'application/json' }
    if ($Sess) { $headers['Origin'] = $base; $headers['X-Hub-CSRF'] = $Sess.Csrf }
    $params = @{ Uri = "$base$Path"; Method = $Method; Headers = $headers; UseBasicParsing = $true; TimeoutSec = 10; SkipHttpErrorCheck = $true }
    if ($Body) { $params['Body'] = ($Body | ConvertTo-Json -Depth 10 -Compress) }
    if ($Sess) { $params['WebSession'] = $Sess.Session }
    $r = Invoke-WebRequest @params
    $obj = $null; try { $obj = $r.Content | ConvertFrom-Json } catch { }
    return @{ Status = [int]$r.StatusCode; Body = $obj; Raw = $r.Content }
}

function New-HubSession {
    $base = "http://127.0.0.1:$Script:HubPort"
    $session = $null
    $null = Invoke-WebRequest $base -UseBasicParsing -SessionVariable session -TimeoutSec 5
    $cookie = ($session.Cookies.GetCookies($base) | Where-Object Name -eq 'hub-csrf').Value
    return @{ Session = $session; Csrf = $cookie }
}

foreach ($f in @('hub-error.log')) { try { [System.IO.File]::Delete((Join-Path $env:TEMP $f)) } catch { } }

Write-Host ''
Write-Host 'smoke-canvas-editor — visual workflow builder' -ForegroundColor Cyan

# Probe whether Hub is already running on $Port; start on AltPort if not.
$hubReady = $false
try {
    $r = Invoke-WebRequest "http://127.0.0.1:$Port/api/health" -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
    if ($r.StatusCode -eq 200) { $hubReady = $true; Write-Pass "Hub running on port $Port (using existing instance)" }
} catch { }

if (-not $hubReady) {
    Write-Host "  Hub not on port $Port — starting on alt-port $AltPort" -ForegroundColor Yellow
    try { Start-HubOnAltPort } catch { Write-Fail "Cannot start Hub: $_"; exit 1 }
}

$base = "http://127.0.0.1:$Script:HubPort"

try {
    $sess = $null   # created lazily

    # ── Static assets ──────────────────────────────────────────────────────────
    Write-Host ''
    Write-Host '--- Static assets ---'

    $cejs = (Invoke-WebRequest "$base/canvas-editor.js" -UseBasicParsing -TimeoutSec 5 -SkipHttpErrorCheck)
    if ([int]$cejs.StatusCode -ne 200) {
        Write-Fail "canvas-editor.js not served (HTTP $([int]$cejs.StatusCode))"
    } else {
        Write-Pass 'canvas-editor.js served (200)'
        $js = $cejs.Content
        Assert-Has $js 'canvasEditorMixin'   'canvasEditorMixin exported'
        Assert-Has $js 'detectCycle'         'detectCycle helper'
        Assert-Has $js 'topoSort'            'topoSort helper'
        Assert-Has $js 'bezierD'             'bezierD bezier helper'
        Assert-Has $js 'cnOpenNew'           'cnOpenNew method'
        Assert-Has $js 'cnOpenWorkflow'      'cnOpenWorkflow method'
        Assert-Has $js 'cnAddNode'           'cnAddNode method'
        Assert-Has $js 'cnAddEdge'           'cnAddEdge method'
        Assert-Has $js 'cnSave'             'cnSave method'
        Assert-Has $js 'cnFitScreen'        'cnFitScreen method'
        Assert-Has $js 'setPointerCapture'  'setPointerCapture drag-capture'
        Assert-Has $js 'pointer-events:none' 'pointer-events:none hit-test guard'
        Assert-Has $js 'cnTransformStyle'   'cnTransformStyle computed'
        Assert-Has $js 'cnBezier'           'cnBezier edge method'
        Assert-Has $js 'releasePointerCapture' 'releasePointerCapture on pointerup'
    }

    $appJs = (Invoke-WebRequest "$base/app.js" -UseBasicParsing -TimeoutSec 5).Content
    Assert-Has $appJs '...canvasEditorMixin()' 'mixin spread into hubApp'
    Assert-Has $appJs 'cnOpenNew'              'cnOpenNew called from wfNewForm'
    Assert-Has $appJs 'cnKeyDown'              'cnKeyDown hooked in init'
    # cnCanvasMode is defined in canvas-editor.js (mixin) — verify there too:
    Assert-Has $js   'cnCanvasMode'            'cnCanvasMode state in mixin'

    $html = (Invoke-WebRequest "$base/" -UseBasicParsing -TimeoutSec 5).Content
    Assert-Has $html 'canvas-editor.js'       'canvas-editor.js script tag in HTML'
    Assert-Has $html 'cn-root'                'cn-root container'
    Assert-Has $html 'cn-canvas-wrap'         'cn-canvas-wrap'
    Assert-Has $html 'cn-nodes-layer'         'cn-nodes-layer div'
    Assert-Has $html 'cn-svg'                 'SVG edge layer'
    Assert-Has $html 'cn-sidebar'             'script sidebar'
    Assert-Has $html 'cn-side-panel'          'params side panel'
    Assert-Has $html 'arrowhead-success'      'arrowhead-success SVG marker'
    Assert-Has $html 'arrowhead-failure'      'arrowhead-failure SVG marker'
    Assert-Has $html 'cnBezier'               'cnBezier binding in HTML'
    Assert-Has $html 'cnRubberBand'           'rubber-band in-progress edge'
    Assert-Has $html 'cnCanvasMode'           'cnCanvasMode if-guard'
    Assert-Has $html 'cn-ghost-node'          'ghost node during drag'

    $css = (Invoke-WebRequest "$base/style.css" -UseBasicParsing -TimeoutSec 5).Content
    Assert-Has $css '.cn-root'                'cn-root CSS rule'
    Assert-Has $css '.cn-canvas-wrap'         'cn-canvas-wrap rule'
    Assert-Has $css '.cn-node'                'cn-node rule'
    Assert-Has $css '.cn-node-selected'       'cn-node-selected rule'
    Assert-Has $css '.cn-port-in'             'cn-port-in rule'
    Assert-Has $css '.cn-port-success'        'cn-port-success rule'
    Assert-Has $css '.cn-port-failure'        'cn-port-failure rule'
    Assert-Has $css '.cn-svg'                 'cn-svg rule'
    Assert-Has $css '.cn-edge'                'cn-edge rule'
    Assert-Has $css '.cn-ghost-node'          'cn-ghost-node rule'
    Assert-Has $css '.cn-side-panel'          'cn-side-panel rule'

    # ── API round-trip: POST workflow with canvas field, GET back ─────────────
    Write-Host ''
    Write-Host '--- Canvas API round-trip ---'

    # Check if the workflows API is available (Hub.exe v1.4.13.0 returns 503 — it predates workflows).
    $wfProbe = Invoke-Api -Method GET -Path '/api/workflows'
    $apiAvailable = ($wfProbe.Status -eq 200)
    if (-not $apiAvailable) {
        Write-Host "  [SKIP] Workflow API not available (HTTP $($wfProbe.Status)) — Hub.exe may be the pre-workflow build." -ForegroundColor Yellow
        Write-Host "         Re-run with Hub.ps1 (not Hub.exe) for full API tests." -ForegroundColor Yellow
    }

    $sess = $null
    $scripts = @()
    if ($apiAvailable) {
        $sess = New-HubSession
        $items = (Invoke-Api -Method GET -Path '/api/items').Body
        $scripts = @($items.items | Where-Object { $_.kind -eq 'ps1' } | Select-Object -First 2)
        if ($scripts.Count -lt 2) {
            Write-Host '  [SKIP] Not enough ps1 scripts in catalog for run test' -ForegroundColor Yellow
            $scripts = @($items.items | Select-Object -First 2)
        }
    }

    if ($apiAvailable -and $scripts.Count -lt 1) {
        Write-Host '  [SKIP] No scripts in catalog — skipping API round-trip' -ForegroundColor Yellow
    }

    if ($apiAvailable -and $scripts.Count -ge 1) {

    $sc1 = $scripts[0]; $sc2 = if ($scripts.Count -ge 2) { $scripts[1] } else { $scripts[0] }

    $canvasBody = @{
        name  = 'canvas-smoke-' + ([guid]::NewGuid().ToString('N').Substring(0, 6))
        steps = @(
            @{ id = 's1'; scriptId = $sc1.path }
            @{ id = 's2'; scriptId = $sc2.path; onSuccess = 'stop' }
        )
        canvas = @{
            version   = 1
            nextStepN = 3
            nodes     = @(
                @{ id = 'n1'; stepId = 's1'; scriptId = $sc1.path; scriptName = $sc1.name; itemId = $sc1.id; x = 100; y = 120; params = @{} }
                @{ id = 'n2'; stepId = 's2'; scriptId = $sc2.path; scriptName = $sc2.name; itemId = $sc2.id; x = 420; y = 120; params = @{} }
            )
            edges     = @( @{ id = 'e1'; fromNode = 'n1'; fromPort = 'success'; toNode = 'n2' } )
            viewport  = @{ panX = 40; panY = 40; scale = 1.0 }
        }
    }

    $cr = Invoke-Api -Method POST -Path '/api/workflows' -Body $canvasBody -Sess $sess
    if ($cr.Status -ne 200) {
        Write-Fail "Round-trip POST failed ($($cr.Status)): $($cr.Raw)"
    } else {
        $wfId = $cr.Body.id
        Write-Pass "Canvas workflow created ($wfId)"

        $gr = Invoke-Api -Method GET -Path "/api/workflows/$wfId"
        if ($gr.Status -ne 200) {
            Write-Fail "Round-trip GET failed ($($gr.Status))"
        } else {
            $cn = $gr.Body.canvas
            if (-not $cn) { Write-Fail 'canvas field not in GET response' }
            else {
                if ($cn.version -eq 1)                        { Write-Pass 'canvas.version=1 preserved' }
                else                                           { Write-Fail "canvas.version expected 1, got $($cn.version)" }
                if (@($cn.nodes).Count -eq 2)                 { Write-Pass 'canvas: 2 nodes preserved' }
                else                                           { Write-Fail "canvas: expected 2 nodes, got $(@($cn.nodes).Count)" }
                if (@($cn.edges).Count -eq 1)                 { Write-Pass 'canvas: 1 edge preserved' }
                else                                           { Write-Fail "canvas: expected 1 edge, got $(@($cn.edges).Count)" }
                $n1 = @($cn.nodes | Where-Object { $_.id -eq 'n1' }) | Select-Object -First 1
                if ($n1 -and $n1.x -eq 100)                   { Write-Pass 'canvas: node position (x=100) preserved' }
                else                                           { Write-Fail "canvas: node x expected 100, got $($n1.x)" }
                if ($cn.viewport.panX -eq 40)                 { Write-Pass 'canvas: viewport.panX=40 preserved' }
                else                                           { Write-Fail "canvas: viewport.panX expected 40, got $($cn.viewport.panX)" }
            }
            # Verify steps array derived correctly.
            if (@($gr.Body.steps).Count -eq 2)                { Write-Pass 'steps[] has 2 entries' }
            else                                               { Write-Fail "steps[] expected 2, got $(@($gr.Body.steps).Count)" }
        }

        # Delete the test workflow.
        $dr = Invoke-Api -Method DELETE -Path "/api/workflows/$wfId" -Sess $sess
        if ($dr.Status -eq 200 -or $dr.Status -eq 204) { Write-Pass "Test workflow deleted ($wfId)" }
        else { Write-Fail "Delete failed ($($dr.Status))" }
    }

    }  # end: if catalog has scripts

    # ── Server-side 50-step cap ───────────────────────────────────────────────
    Write-Host ''
    Write-Host '--- Step count cap ---'
    if ($apiAvailable) {
        if ($null -eq $sess) { $sess = New-HubSession }
        $anyPath = if ($scripts.Count -ge 1) { $scripts[0].path } else { 'C:\fake\path.ps1' }
        $bigSteps = 1..51 | ForEach-Object { @{ id = "s$_"; scriptId = $anyPath } }
        $r = Invoke-Api -Method POST -Path '/api/workflows' -Body @{ name = 'too-many'; steps = $bigSteps } -Sess $sess
        if ($r.Status -eq 422) { Write-Pass '51 steps rejected (422)' }
        else { Write-Fail "51-step cap: expected 422, got $($r.Status)" }
    } else {
        Write-Host '  [SKIP] Step cap test requires workflow API' -ForegroundColor Yellow
    }

    # ── Regression: prior workflow features still work ────────────────────────
    Write-Host ''
    Write-Host '--- Regression: existing features ---'
    if ($apiAvailable) {
        if ($null -eq $sess) { $sess = New-HubSession }
        $wfList = (Invoke-Api -Method GET -Path '/api/workflows').Body
        if ($null -ne $wfList)                             { Write-Pass 'GET /api/workflows still works' }
        else                                               { Write-Fail 'GET /api/workflows broken' }
        $hist = (Invoke-Api -Method GET -Path '/api/history').Body
        if ($hist -and $null -ne $hist.entries)            { Write-Pass 'GET /api/history still works' }
        else                                               { Write-Fail 'GET /api/history broken' }
        $gitRoots = (Invoke-Api -Method GET -Path '/api/git-roots').Body
        if ($gitRoots -and $null -ne $gitRoots.gitRoots)  { Write-Pass 'GET /api/git-roots still works' }
        else                                               { Write-Fail 'GET /api/git-roots broken' }
    } else {
        Write-Host '  [SKIP] Regression API checks require workflow-enabled Hub' -ForegroundColor Yellow
    }

} finally {
    Stop-OwnedHub   # no-op if we used the existing Hub
}

Write-Host ''
if ($Script:Failures.Count -eq 0) {
    Write-Host 'smoke-canvas-editor PASS' -ForegroundColor Green
    exit 0
} else {
    Write-Host ("smoke-canvas-editor FAIL ({0} issue(s)):" -f $Script:Failures.Count) -ForegroundColor Red
    foreach ($f in $Script:Failures) { Write-Host "  - $f" -ForegroundColor Red }
    exit 1
}
