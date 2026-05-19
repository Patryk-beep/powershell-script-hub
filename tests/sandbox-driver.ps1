#Requires -Version 5.1
<#
.SYNOPSIS
    Driver executed inside Windows Sandbox to verify install-hub.ps1 end-to-end
    from a fresh, install-everything-from-scratch environment (Phase 4 K27).

.DESCRIPTION
    Windows Sandbox is a free disposable VM on Windows 10/11 Pro+ (enable via
    "Turn Windows features on or off" -> "Windows Sandbox"). The .wsb file maps
    this script in read-only and auto-runs it on logon. The sandbox starts with
    no pwsh, no gh, no Hub binaries on disk — exactly what a first-time user
    sees.

    To run: see tests\sandbox-install-test.wsb.example. Generate a real .wsb
    with tests\build-sandbox-wsb.ps1 (it injects your repo path); the generated
    .wsb is gitignored.

.NOTES
    Result log: %USERPROFILE%\Desktop\install-test.log inside the sandbox.
    Review BEFORE closing the sandbox window — closing destroys the VM.
#>
[CmdletBinding()]
param(
    [string]$Tag = 'v1.1.0',
    [string]$RepoSlug = 'Patryk-beep/powershell-script-hub'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$desktop = [Environment]::GetFolderPath('Desktop')
$log = Join-Path $desktop 'install-test.log'
Start-Transcript -Path $log -Force | Out-Null

try {
    Write-Host '=== Phase 4 sandbox install test ===' -ForegroundColor Cyan
    Write-Host "Tag:      $Tag"
    Write-Host "Repo:     $RepoSlug"
    Write-Host "Driver:   $PSCommandPath"
    Write-Host "User:     $env:USERNAME"
    Write-Host "Host:     $env:COMPUTERNAME"
    Write-Host ''

    # 1. Confirm fresh env
    $pwshBefore = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($pwshBefore) {
        Write-Host "[warn] pwsh already present at $($pwshBefore.Source) — not a clean env!" -ForegroundColor Yellow
    } else {
        Write-Host '[ok]  No pwsh on PATH — clean env confirmed.' -ForegroundColor Green
    }
    $hubBefore = Test-Path 'C:\Users\WDAGUtilityAccount\AppData\Local\Programs\Hub'
    if ($hubBefore) {
        Write-Host '[warn] Hub install dir already exists.' -ForegroundColor Yellow
    } else {
        Write-Host '[ok]  No prior Hub install.' -ForegroundColor Green
    }

    # 2. Force TLS 1.2 for fresh Win10 boxes
    try {
        [Net.ServicePointManager]::SecurityProtocol = `
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch { }

    # 3. Download the installer from the PUBLIC tag-pinned URL
    $installerUrl = "https://raw.githubusercontent.com/$RepoSlug/$Tag/install-hub.ps1"
    Write-Host "Fetching installer: $installerUrl"
    New-Item -ItemType Directory -Path 'C:\Temp' -Force | Out-Null
    $installerPath = 'C:\Temp\install-hub.ps1'
    Invoke-WebRequest -Uri $installerUrl -OutFile $installerPath -UseBasicParsing -Headers @{
        'User-Agent' = 'sandbox-driver'
    }
    Write-Host "[ok]  Installer downloaded ($((Get-Item $installerPath).Length) bytes)" -ForegroundColor Green

    # 4. Stage a scan-root folder so the install runs non-interactively
    $scanRoot = 'C:\Users\WDAGUtilityAccount\Tools'
    New-Item -ItemType Directory -Path $scanRoot -Force | Out-Null

    # 5. Pipe 'y' to handle pwsh-7-install prompt (default is yes anyway)
    Write-Host ''
    Write-Host '=== Running install-hub.ps1 -Install ===' -ForegroundColor Cyan
    'y' | & $installerPath -Install -ScanRoots $scanRoot -NoLaunch
    $installerExit = $LASTEXITCODE
    Write-Host "Installer exit: $installerExit"
    if ($installerExit -ne 0) {
        throw "Installer exited with $installerExit"
    }

    # 6. Verify install artifacts
    Write-Host ''
    Write-Host '=== Verifying install ===' -ForegroundColor Cyan
    $exe = Join-Path $env:LOCALAPPDATA 'Programs\Hub\Hub.exe'
    $cfg = Join-Path $env:LOCALAPPDATA 'Hub\hub-config.json'
    $lnk = Join-Path ([Environment]::GetFolderPath('Programs')) 'PowerShell Hub.lnk'

    foreach ($pair in @(
        @{ Label = 'Hub.exe';          Path = $exe },
        @{ Label = 'hub-config.json';  Path = $cfg },
        @{ Label = 'Start Menu link';  Path = $lnk }
    )) {
        if (Test-Path $pair.Path) {
            Write-Host "[ok]  $($pair.Label): $($pair.Path)" -ForegroundColor Green
        } else {
            Write-Host "[err] $($pair.Label) MISSING: $($pair.Path)" -ForegroundColor Red
        }
    }

    # 7. Launch Hub and probe /api/health
    Write-Host ''
    Write-Host '=== Launching Hub.exe ===' -ForegroundColor Cyan
    Start-Process -FilePath $exe
    $healthOk = $false
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 500
        try {
            $h = Invoke-RestMethod -Uri 'http://127.0.0.1:8765/api/health' -TimeoutSec 1 -ErrorAction Stop
            if ($h.version) {
                Write-Host "[ok]  Hub responded: version=$($h.version), jobs=$($h.jobs)" -ForegroundColor Green
                $healthOk = $true
                break
            }
        } catch { }
    }
    if (-not $healthOk) {
        Write-Host '[err] Hub did not respond on 127.0.0.1:8765 within 20s.' -ForegroundColor Red
    }

    if ($healthOk) {
        Write-Host ''
        Write-Host 'INSTALL TEST PASSED' -ForegroundColor Green
    } else {
        Write-Host ''
        Write-Host 'INSTALL TEST FAILED' -ForegroundColor Red
    }
}
catch {
    Write-Host ''
    Write-Host "INSTALL TEST FAILED: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
}
finally {
    Write-Host ''
    Write-Host "Log: $log"
    Write-Host 'Keep the sandbox window open to review. Closing it deletes the VM.'
    Stop-Transcript | Out-Null
}
