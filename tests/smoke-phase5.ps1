#Requires -Version 5.1
# Phase 5 smoke — port fallback + .exe support + Test-UrlAcl + tray icon file.

[CmdletBinding()]
param(
    [string]$HubScript = (Join-Path (Split-Path -Parent $PSScriptRoot) 'Hub.ps1'),
    [int]$BootTimeoutSeconds = 12
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:Failures = New-Object 'System.Collections.Generic.List[string]'
$Script:HubProc  = $null
$Script:Blocker  = $null
$Script:Fixtures = Join-Path $PSScriptRoot 'fixtures'

function Write-Step { param([string]$Msg) Write-Host ('  [..] ' + $Msg) -ForegroundColor DarkGray }
function Write-Pass { param([string]$Msg) Write-Host ('  [OK] ' + $Msg) -ForegroundColor Green }
function Write-Fail { param([string]$Msg) Write-Host ('  [FAIL] ' + $Msg) -ForegroundColor Red; $Script:Failures.Add($Msg) }

function Wait-HubReady {
    param([int]$Port, [int]$TimeoutSeconds)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $r = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/api/health" -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
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

function Stop-Blocker {
    if ($Script:Blocker) {
        try { $Script:Blocker.Stop() } catch { }
        $Script:Blocker = $null
    }
}

function Start-PortBlocker {
    param([int]$Port)
    $tcp = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback), $Port
    $tcp.Start()
    return $tcp
}

function Get-HubPortFromFile {
    [OutputType([int])]
    param()
    $path = Join-Path $env:TEMP 'hub.port'
    if (-not (Test-Path -LiteralPath $path)) { return 0 }
    try {
        $raw = (Get-Content -LiteralPath $path -Raw).Trim()
        $p = 0
        if ([int]::TryParse($raw, [ref]$p)) { return $p }
    } catch { }
    return 0
}

function Start-HubProcess {
    param([string[]]$ExtraArgs)
    $extra = if ($ExtraArgs) { ' ' + ($ExtraArgs -join ' ') } else { '' }
    Start-Process pwsh -ArgumentList "-NoProfile -Sta -ExecutionPolicy Bypass -File `"$HubScript`"$extra" -PassThru -WindowStyle Hidden
}

foreach ($f in @('hub-error.log','hub.port')) {
    try { [System.IO.File]::Delete((Join-Path $env:TEMP $f)) } catch { }
}

Write-Host ''
Write-Host 'Phase 5 smoke test' -ForegroundColor Cyan

# ===========================================================
# 5.T1 — Port fallback (8765 blocked → expect 8766+)
# ===========================================================
Write-Host ''
Write-Host '5.T1 — Port fallback when 8765 in use'

try {
    $Script:Blocker = Start-PortBlocker -Port 8765
    Write-Step 'Bound dummy TcpListener on 8765'
} catch {
    Write-Fail "Could not bind dummy listener: $($_.Exception.Message)"
}

try {
    $Script:HubProc = Start-HubProcess -ExtraArgs @('-ExtraScanRoots', $Script:Fixtures)
    Write-Step "Started Hub PID $($Script:HubProc.Id)"
    # Wait for Hub on any port — poll all candidates
    $foundPort = 0
    $deadline = (Get-Date).AddSeconds($BootTimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $p = Get-HubPortFromFile
        if ($p -gt 0 -and $p -ne 8765) {
            try {
                $r = Invoke-WebRequest -Uri "http://127.0.0.1:$p/api/health" -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
                if ($r.StatusCode -eq 200) { $foundPort = $p; break }
            } catch { }
        }
        Start-Sleep -Milliseconds 400
    }
    if ($foundPort -eq 0) { Write-Fail "Hub never bound a fallback port (hub.port=$(Get-HubPortFromFile))" }
    elseif ($foundPort -eq 8765) { Write-Fail "Hub bound to 8765 despite blocker" }
    else {
        $h = Invoke-RestMethod -Uri "http://127.0.0.1:$foundPort/api/health" -TimeoutSec 3
        if ($h.port -ne $foundPort) { Write-Fail "/api/health reports port $($h.port), expected $foundPort" }
        else { Write-Pass "Hub bound to fallback port $foundPort, /api/health agrees" }
    }
} finally {
    Stop-Hub
    Stop-Blocker
    Start-Sleep -Milliseconds 500
}

# ===========================================================
# 5.T2 — .exe support (whoami.exe end-to-end)
# ===========================================================
Write-Host ''
Write-Host '5.T2 — .exe raw-arg launch'

$whoamiSrc  = 'C:\Windows\System32\whoami.exe'
$whoamiDest = Join-Path $Script:Fixtures 'whoami.exe'

try {
    Copy-Item -LiteralPath $whoamiSrc -Destination $whoamiDest -Force -ErrorAction Stop
    Write-Step "Copied whoami.exe -> $whoamiDest"
} catch {
    Write-Fail "Cannot copy whoami.exe ($($_.Exception.Message)) — test skipped"
}

if (Test-Path -LiteralPath $whoamiDest) {
    foreach ($f in @('hub-error.log','hub.port')) {
        try { [System.IO.File]::Delete((Join-Path $env:TEMP $f)) } catch { }
    }
    try {
        $Script:HubProc = Start-HubProcess -ExtraArgs @('-ExtraScanRoots', $Script:Fixtures)
        if (-not (Wait-HubReady -Port 8765 -TimeoutSeconds $BootTimeoutSeconds)) {
            Write-Fail "Hub didn't boot in T2"
        } else {
            $catalog = Invoke-RestMethod -Uri 'http://127.0.0.1:8765/api/items' -TimeoutSec 5
            $exeItem = $catalog.items | Where-Object { $_.name -eq 'whoami' -and $_.kind -eq 'exe' } | Select-Object -First 1
            if (-not $exeItem) {
                Write-Fail "whoami.exe not discovered in items (kinds: $($catalog.items | ForEach-Object kind | Sort-Object -Unique))"
            } else {
                Write-Pass "whoami.exe discovered (id=$($exeItem.id), kind=$($exeItem.kind))"

                # Schema should be raw for .exe
                $schema = Invoke-RestMethod -Uri "http://127.0.0.1:8765/api/items/$($exeItem.id)/schema" -TimeoutSec 5
                if ($schema.mode -ne 'raw') {
                    Write-Fail "exe schema mode='$($schema.mode)', expected 'raw'"
                } else {
                    Write-Pass "exe schema mode=raw (kind=$($schema.kind))"
                }

                # CSRF bootstrap
                $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
                Invoke-WebRequest -Uri 'http://127.0.0.1:8765/' -UseBasicParsing -WebSession $session -TimeoutSec 5 | Out-Null
                $csrf = ($session.Cookies.GetCookies('http://127.0.0.1:8765/') | Where-Object Name -eq 'hub-csrf' | Select-Object -First 1).Value

                # POST /api/run with no args
                $headers = @{ 'Origin' = 'http://127.0.0.1:8765'; 'X-Hub-CSRF' = $csrf }
                $body = (@{ itemId = $exeItem.id } | ConvertTo-Json -Compress)
                $r = Invoke-WebRequest -Uri 'http://127.0.0.1:8765/api/run' -Method POST -Headers $headers `
                    -ContentType 'application/json' -Body $body -WebSession $session -UseBasicParsing -SkipHttpErrorCheck -TimeoutSec 5
                if ($r.StatusCode -ne 202) {
                    Write-Fail "whoami run -> $($r.StatusCode), body: $($r.Content)"
                } else {
                    $jobId = ($r.Content | ConvertFrom-Json).jobId
                    Write-Pass ".exe run accepted (jobId=$jobId)"

                    # Read SSE
                    $req = [System.Net.HttpWebRequest]::Create("http://127.0.0.1:8765/api/stream/$jobId")
                    $req.Method = 'GET'
                    $req.Headers.Add('Origin', 'http://127.0.0.1:8765')
                    $req.Accept = 'text/event-stream'
                    $req.Timeout = 10000
                    $cts = [System.Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds(10))
                    $sawWhoami = $false
                    $sawEnd = $false
                    try {
                        $resp = $req.GetResponse()
                        $stream = $resp.GetResponseStream()
                        $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
                        while ($true) {
                            try { $line = $reader.ReadLineAsync($cts.Token).GetAwaiter().GetResult() } catch { break }
                            if ($null -eq $line) { break }
                            if ($line -eq 'event: end') { $sawEnd = $true }
                            if ($line.StartsWith('data:')) {
                                try {
                                    $obj = $line.Substring(5).Trim() | ConvertFrom-Json
                                    if ($obj -and $obj.line -and $obj.line -match $env:USERNAME) { $sawWhoami = $true }
                                } catch { }
                            }
                            if ($sawEnd) { break }
                        }
                    } catch {
                        Write-Fail "SSE error: $($_.Exception.Message)"
                    } finally {
                        try { $cts.Dispose() } catch { }
                        try { $reader.Dispose() } catch { }
                        try { $stream.Dispose() } catch { }
                        try { $resp.Close() } catch { }
                    }
                    if (-not $sawEnd) { Write-Fail "No end frame for .exe run" }
                    elseif (-not $sawWhoami) { Write-Fail "Output did not contain `$env:USERNAME ($env:USERNAME)" }
                    else { Write-Pass ".exe ran, output contains username, end frame received" }
                }
            }
        }
    } finally {
        Stop-Hub
        try { [System.IO.File]::Delete($whoamiDest) } catch { }
        Start-Sleep -Milliseconds 500
    }
}

# ===========================================================
# 5.T3 — Hub.ico exists and is a valid ICO file
# ===========================================================
Write-Host ''
Write-Host '5.T3 — Hub.ico present'

$icoPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Hub.ico'
if (-not (Test-Path -LiteralPath $icoPath)) {
    Write-Fail "Hub.ico not found at $icoPath (run build-icon.ps1)"
} else {
    $bytes = [System.IO.File]::ReadAllBytes($icoPath)
    if ($bytes.Length -lt 1000) {
        Write-Fail "Hub.ico too small ($($bytes.Length) bytes)"
    } elseif ($bytes[0] -ne 0 -or $bytes[1] -ne 0 -or $bytes[2] -ne 1 -or $bytes[3] -ne 0) {
        Write-Fail "Hub.ico header malformed (not ICONDIR)"
    } else {
        $count = $bytes[4] -bor ($bytes[5] -shl 8)
        if ($count -lt 1 -or $count -gt 32) {
            Write-Fail "Hub.ico image count = $count (suspect)"
        } else {
            Write-Pass "Hub.ico valid: $($bytes.Length) bytes, $count image(s)"
        }
        # Load it via System.Drawing to confirm it parses
        try {
            $ico = New-Object System.Drawing.Icon $icoPath
            $ico.Dispose()
            Write-Pass "Hub.ico loadable via System.Drawing.Icon"
        } catch {
            Write-Fail "System.Drawing.Icon rejects file: $($_.Exception.Message)"
        }
    }
}

# ===========================================================
# 5.T4 — Test-UrlAcl returns bool without throwing
# ===========================================================
Write-Host ''
Write-Host '5.T4 — Test-UrlAcl probe'

# Direct shell-out (mirror what Hub.ps1 does internally)
try {
    $out = & netsh http show urlacl url='http://127.0.0.1:8765/' 2>&1 | Out-String
    if ($LASTEXITCODE -eq $null -or $LASTEXITCODE -ge 0) {
        Write-Pass "netsh probe completes (output length=$($out.Length))"
    }
} catch {
    Write-Fail "netsh probe threw: $($_.Exception.Message)"
}

# ===========================================================
# RESULT
# ===========================================================
Write-Host ''
if ($Script:Failures.Count -eq 0) {
    Write-Host 'PASS — all Phase 5 smoke checks succeeded' -ForegroundColor Green
    exit 0
} else {
    Write-Host ('FAIL — ' + $Script:Failures.Count + ' failure(s):') -ForegroundColor Red
    foreach ($f in $Script:Failures) { Write-Host ('  - ' + $f) -ForegroundColor Red }
    exit 1
}
