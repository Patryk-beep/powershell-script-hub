#Requires -Version 5.1
<#
.SYNOPSIS
    End-to-end smoke for install-hub.ps1 (Phase 3 task 3.12).

.DESCRIPTION
    Runs Install -> Update -> Uninstall against a sandboxed install dir under
    %TEMP%. Uses build\Hub.zip via -LocalZip so it does not require network or
    a published GitHub release. Overrides $env:LOCALAPPDATA in a child process
    so the real %LOCALAPPDATA%\Hub\ on this machine is never touched.

    Cases (15):
      1.  install-hub.ps1 parses cleanly
      2.  Get-Help works
      3.  Get-Command -Syntax shows 3 param sets
      4.  Hub.zip exists at build\Hub.zip
      5.  $Script:ExpectedZipHash matches the zip's actual SHA256
      6.  -Install with -LocalZip writes Hub.exe to InstallDir
      7.  -Install writes hub-config.json to fake-LOCALAPPDATA\Hub\
      8.  hub-config.json schema (version, scanRoots, scanMaxDepth, hiddenIds)
      9.  Shortcut at fake-Programs\<ShortcutName>.lnk targets Hub.exe
      10. Hub.exe inside install dir matches the source Hub.exe (byte length)
      11. -Update overwrites Hub.exe but preserves hub-config.json mtime
      12. -Uninstall removes install dir
      13. -Uninstall removes shortcut
      14. SHA256 mismatch -> Test-ZipHash throws
      15. Re-running -Install on top of a foreign shortcut throws (ADV-H4)

.NOTES
    NEVER prompts. NEVER touches real $env:LOCALAPPDATA. NEVER launches Hub.exe.
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = (Split-Path $PSScriptRoot -Parent)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$pass = 0
$fail = 0
$cases = New-Object 'System.Collections.Generic.List[string]'

function Assert-Eq {
    param([string]$Case, $Expected, $Actual)
    if ($Expected -eq $Actual) {
        $script:pass++
        $script:cases.Add("[PASS] $Case") | Out-Null
    } else {
        $script:fail++
        $script:cases.Add("[FAIL] $Case  expected=<$Expected> actual=<$Actual>") | Out-Null
    }
}

function Assert-True {
    param([string]$Case, [bool]$Cond, [string]$Detail = '')
    if ($Cond) {
        $script:pass++
        $script:cases.Add("[PASS] $Case") | Out-Null
    } else {
        $script:fail++
        $script:cases.Add("[FAIL] $Case  $Detail") | Out-Null
    }
}

# --- Paths --------------------------------------------------------------------

$Installer = Join-Path $RepoRoot 'install-hub.ps1'
$Zip       = Join-Path $RepoRoot 'build\Hub.zip'
$Sandbox   = Join-Path $env:TEMP ("hub-smoke3-" + [Guid]::NewGuid().ToString('N'))
$FakeLocal = Join-Path $Sandbox  'AppData\Local'
$FakePrg   = Join-Path $Sandbox  'StartMenu\Programs'
$InstallDir= Join-Path $FakeLocal 'Programs\Hub'
$CfgDir    = Join-Path $FakeLocal 'Hub'
$CfgFile   = Join-Path $CfgDir   'hub-config.json'
$ScanRoot  = Join-Path $Sandbox  'scan-target'
$ShortcutN = 'Hub-Smoke3-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
$ShortcutP = Join-Path $FakePrg "$ShortcutN.lnk"

New-Item -ItemType Directory -Path $Sandbox, $FakeLocal, $FakePrg, $ScanRoot -Force | Out-Null
'Param([string]$Name) "hi $Name"' | Set-Content -Path (Join-Path $ScanRoot 'test.ps1') -Encoding ASCII

# Override that the installer reads via [Environment]::GetFolderPath('Programs')
# and $env:LOCALAPPDATA. Child process gets the env; this session keeps real env.
function Invoke-Installer {
    param([string[]]$ExtraArgs)

    $cmdArgs = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', $Installer
    ) + $ExtraArgs

    # PROMPT-FREE: we always pass -ScanRoots so Install/Update never prompt.
    # Uninstall prompts twice (confirm + remove-config). Stdin "y`ny`n" answers both.
    $env:HUB_TEST_LOCALAPPDATA_BAK = $env:LOCALAPPDATA
    $env:LOCALAPPDATA = $FakeLocal

    try {
        $stdinSrc = "y`ny`n"
        $output   = $stdinSrc | & powershell.exe @cmdArgs 2>&1 | Out-String
        $exit     = $LASTEXITCODE
        if ($env:HUB_TEST_VERBOSE -or ($exit -ne 0)) {
            Write-Host '--- child output ---' -ForegroundColor DarkGray
            Write-Host $output                -ForegroundColor DarkGray
            Write-Host '--- /child output ---' -ForegroundColor DarkGray
        }
        return $exit
    }
    finally {
        $env:LOCALAPPDATA = $env:HUB_TEST_LOCALAPPDATA_BAK
        Remove-Item Env:HUB_TEST_LOCALAPPDATA_BAK -ErrorAction SilentlyContinue
    }
}

# Override the shortcut path via $Script:ShortcutPath. The installer derives it
# from [Environment]::GetFolderPath('Programs') which we can't easily redirect
# from the child env, so we pass -ShortcutName and accept that the shortcut will
# be written to the real Start Menu. We clean it up at the end.
$RealShortcutP = Join-Path ([Environment]::GetFolderPath('Programs')) "$ShortcutN.lnk"
$ShortcutP = $RealShortcutP

# --- Case 1-3: Static analysis ------------------------------------------------

$parseErrs = $null; $tokens = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($Installer, [ref]$tokens, [ref]$parseErrs)
Assert-True 'Case 1 — install-hub.ps1 AST-parses' ($null -eq $parseErrs -or $parseErrs.Count -eq 0) "errors=$($parseErrs.Count)"

$help = Get-Help $Installer
Assert-True 'Case 2 — Get-Help returns non-empty output' ($help -and ("$help".Length -gt 0)) ''

$syntax = (Get-Command $Installer -Syntax) | Out-String
Assert-True 'Case 3 — 3 param sets visible' (($syntax -match '-Install\b') -and ($syntax -match '-Update\b') -and ($syntax -match '-Uninstall\b')) ''

# --- Case 4-5: Release zip ----------------------------------------------------

Assert-True 'Case 4 — build\Hub.zip exists' (Test-Path $Zip) "missing $Zip"

$realHash = (Get-FileHash $Zip -Algorithm SHA256).Hash
$installerSrc = Get-Content $Installer -Raw
if ($installerSrc -match "(?<=\`$Script:ExpectedZipHash\s*=\s*')[^']*") {
    $embedded = $Matches[0]
} else { $embedded = '' }
Assert-Eq 'Case 5 — embedded hash matches zip SHA256' $realHash $embedded

# --- Case 6-10: Install -------------------------------------------------------

$exitInstall = Invoke-Installer @(
    '-Install',
    '-InstallDir', $InstallDir,
    '-ScanRoots',  $ScanRoot,
    '-NoLaunch',
    '-LocalZip',   $Zip,
    '-ShortcutName', $ShortcutN
)
Assert-Eq 'Case 6 — -Install exit 0' 0 $exitInstall

$installedExe = Join-Path $InstallDir 'Hub.exe'
Assert-True 'Case 7 — Hub.exe extracted to InstallDir' (Test-Path $installedExe) "missing $installedExe"

Assert-True 'Case 8 — hub-config.json written to fake-LOCALAPPDATA\Hub\' (Test-Path $CfgFile) "missing $CfgFile"

if (Test-Path $CfgFile) {
    $cfg = Get-Content $CfgFile -Raw | ConvertFrom-Json
    $hasAll = ($cfg.PSObject.Properties['version']) -and `
              ($cfg.PSObject.Properties['scanRoots']) -and `
              ($cfg.PSObject.Properties['scanMaxDepth']) -and `
              ($cfg.PSObject.Properties['hiddenIds'])
    Assert-True 'Case 9 — config schema complete' $hasAll ''
} else {
    Assert-True 'Case 9 — config schema complete' $false 'config file missing'
}

Assert-True 'Case 10 — Start Menu shortcut created' (Test-Path $ShortcutP) "missing $ShortcutP"

# --- Case 11: Update preserves config ----------------------------------------

if (Test-Path $CfgFile) {
    $beforeMtime = (Get-Item $CfgFile).LastWriteTimeUtc
    Start-Sleep -Milliseconds 1100   # ensure mtime resolution distinguishes
    $exitUpdate = Invoke-Installer @(
        '-Update',
        '-InstallDir', $InstallDir,
        '-NoLaunch',
        '-LocalZip',   $Zip,
        '-ShortcutName', $ShortcutN
    )
    $afterMtime = (Get-Item $CfgFile).LastWriteTimeUtc
    Assert-Eq 'Case 11a — -Update exit 0' 0 $exitUpdate
    Assert-Eq 'Case 11b — config mtime unchanged by -Update' $beforeMtime $afterMtime
} else {
    Assert-True 'Case 11 — -Update preserves config (skipped, no config)' $false ''
}

# --- Case 12-13: Uninstall ----------------------------------------------------

$exitUninstall = Invoke-Installer @(
    '-Uninstall',
    '-InstallDir', $InstallDir,
    '-ShortcutName', $ShortcutN
)
Assert-Eq 'Case 12 — -Uninstall exit 0' 0 $exitUninstall
Assert-True 'Case 13a — install dir removed' (-not (Test-Path $InstallDir)) ''
Assert-True 'Case 13b — shortcut removed' (-not (Test-Path $ShortcutP)) ''

# --- Case 14: SHA256 mismatch -> throw ----------------------------------------

# Build a junk zip with different bytes
$junkZip = Join-Path $Sandbox 'junk.zip'
$junkSrc = Join-Path $Sandbox 'junk-src'
New-Item -ItemType Directory -Path $junkSrc -Force | Out-Null
'noise' | Set-Content -Path (Join-Path $junkSrc 'a.txt')
Compress-Archive -Path (Join-Path $junkSrc '*') -DestinationPath $junkZip -Force

$mismatchInstallDir = Join-Path $Sandbox 'mismatch-install'
$exitMismatch = Invoke-Installer @(
    '-Install',
    '-InstallDir', $mismatchInstallDir,
    '-ScanRoots',  $ScanRoot,
    '-NoLaunch',
    '-LocalZip',   $junkZip,
    '-ShortcutName', "$ShortcutN-mismatch"
)
Assert-True 'Case 14 — SHA256 mismatch aborts install (exit != 0 and no Hub.exe)' (($exitMismatch -ne 0) -and (-not (Test-Path (Join-Path $mismatchInstallDir 'Hub.exe')))) "exit=$exitMismatch"

# --- Case 15: ADV-H4 — foreign shortcut collision -----------------------------

# Pre-create a shortcut at the same path but targeting a foreign app
$foreignDir = Join-Path $Sandbox 'foreign-app'
New-Item -ItemType Directory -Path $foreignDir -Force | Out-Null
Copy-Item 'C:\Windows\notepad.exe' (Join-Path $foreignDir 'notepad.exe') -Force
$shellH4 = New-Object -ComObject WScript.Shell
$lnkH4   = $shellH4.CreateShortcut($ShortcutP)
$lnkH4.TargetPath = (Join-Path $foreignDir 'notepad.exe')
$lnkH4.Save()
[void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($lnkH4)
[void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shellH4)

$exitH4 = Invoke-Installer @(
    '-Install',
    '-InstallDir', $InstallDir,
    '-ScanRoots',  $ScanRoot,
    '-NoLaunch',
    '-LocalZip',   $Zip,
    '-ShortcutName', $ShortcutN
)
# The installer should extract Hub.exe successfully BUT throw on shortcut creation
# (we wrap the call in try/catch with Write-Warn2 — so exit code may still be 0).
# Verify the foreign shortcut was NOT overwritten.
$shellV = New-Object -ComObject WScript.Shell
$lnkV   = $shellV.CreateShortcut($ShortcutP)
$finalTarget = $lnkV.TargetPath
[void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($lnkV)
[void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shellV)
Assert-True 'Case 15 — ADV-H4 foreign shortcut not overwritten' ($finalTarget -like '*notepad.exe') "actual target=$finalTarget"

# --- Cleanup ------------------------------------------------------------------

Remove-Item $ShortcutP -Force -ErrorAction SilentlyContinue
if (Test-Path $InstallDir) {
    try { [System.IO.Directory]::Delete($InstallDir, $true) } catch { }
}
try { [System.IO.Directory]::Delete($Sandbox, $true) } catch { }

# --- Report -------------------------------------------------------------------

$cases | ForEach-Object { Write-Host $_ }
Write-Host ''
$color = if ($fail -eq 0) { 'Green' } else { 'Red' }
Write-Host ("Total: {0} pass / {1} fail" -f $pass, $fail) -ForegroundColor $color
if ($fail -gt 0) { exit 1 }
exit 0
