#Requires -Version 5.1
<#
.SYNOPSIS
    Installer / updater / uninstaller for PowerShell Script Hub.

.DESCRIPTION
    Run via:
        irm https://raw.githubusercontent.com/Patryk-beep/powershell-script-hub/v1.5.0.0/install-hub.ps1 | iex
    Or download and invoke directly with -Install / -Update / -Uninstall.

    Targets PowerShell 5.1+ (Windows 10/11 default). Recommends pwsh 7 for Hub runtime.

.PARAMETER Install
    Default mode. Downloads release zip, verifies SHA256, extracts to InstallDir,
    writes hub-config.json, creates Start Menu shortcut, launches Hub.

.PARAMETER Update
    Re-downloads release and overwrites install dir. Preserves
    %LOCALAPPDATA%\Hub\hub-config.json (config lives outside install dir per K12).

.PARAMETER Uninstall
    Stops Hub, removes install dir and shortcut. Does not delete user scan-root
    folders or config (config removal is opt-in).

.EXAMPLE
    irm https://raw.githubusercontent.com/Patryk-beep/powershell-script-hub/v1.5.0.0/install-hub.ps1 | iex

.EXAMPLE
    .\install-hub.ps1 -Update

.EXAMPLE
    .\install-hub.ps1 -Uninstall

.NOTES
    Per-user install. No admin required. No PATH modification. No HKLM writes.
#>
[CmdletBinding(DefaultParameterSetName = 'Install')]
param(
    [Parameter(ParameterSetName = 'Install')]   [switch]$Install,
    [Parameter(ParameterSetName = 'Update')]    [switch]$Update,
    [Parameter(ParameterSetName = 'Uninstall')] [switch]$Uninstall,

    [string]   $InstallDir    = (Join-Path $env:LOCALAPPDATA 'Programs\Hub'),
    [string[]] $ScanRoots,
    [switch]   $Autostart,
    [switch]   $NoLaunch,
    [string]   $Version       = 'v1.5.0.0',
    [string]   $ShortcutName  = 'PowerShell Hub',
    [string]   $VerifyHash,

    # TEST-ONLY: skip network download and stage the zip from this local path.
    # Used by build-release.ps1 self-test and the Phase 3 task 3.12 dry run.
    [string]   $LocalZip
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Constants ----------------------------------------------------------------

# K25 — SHA256 of asset-only Hub.zip (no installer). Patched by build-release.ps1.
$Script:ExpectedZipHash = '1AB8AC73772735BB90B234C3E248CE537E22D28508460D2D4CEA49E220C7B17D'

# K12 — config dir lives OUTSIDE install dir. -Update never touches this.
$Script:ConfigDir       = Join-Path $env:LOCALAPPDATA 'Hub'
$Script:ConfigPath      = Join-Path $Script:ConfigDir  'hub-config.json'

# ADV-H4 — disambiguated shortcut name (default 'PowerShell Hub' via param).
$Script:ShortcutPath    = Join-Path ([Environment]::GetFolderPath('Programs')) "$ShortcutName.lnk"

# Same mutex Hub.exe uses for single-instance enforcement.
$Script:HubMutexName    = 'Global\HubInstance.' + ($env:USERNAME -replace '[^\w]', '_')

# Release source — K24 tag-pinned URLs constructed in Get-ReleaseUrl.
$Script:Repo            = 'Patryk-beep/powershell-script-hub'
$Script:AssetName       = 'Hub.zip'
$Script:RunKey          = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'

# --- Logging ------------------------------------------------------------------

function Write-Info  { param([string]$Msg) Write-Host "[hub] $Msg" -ForegroundColor Cyan }
function Write-Ok    { param([string]$Msg) Write-Host "[hub] $Msg" -ForegroundColor Green }
function Write-Warn2 { param([string]$Msg) Write-Host "[hub] $Msg" -ForegroundColor Yellow }
function Write-Err   { param([string]$Msg) Write-Host "[hub] $Msg" -ForegroundColor Red }

# --- Helpers (stubs filled in tasks 3.2 – 3.8) --------------------------------

function Test-Pwsh7 {
    # Returns $true iff pwsh.exe is on PATH and reports version >= 7.
    $cmd = Get-Command pwsh -ErrorAction SilentlyContinue
    if (-not $cmd) { return $false }
    try {
        $raw = & pwsh -NoProfile -NoLogo -Command '$PSVersionTable.PSVersion.Major' 2>$null
        $line = ($raw | Select-Object -First 1)
        $ver = 0
        if ([int]::TryParse([string]$line, [ref]$ver)) { return $ver -ge 7 }
        return $false
    }
    catch {
        return $false
    }
}

function Update-EnvPath {
    # winget install does NOT refresh the current shell's PATH. Reload from registry
    # so a freshly installed pwsh.exe is discoverable without restarting the session.
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = (@($machine, $user) | Where-Object { $_ }) -join ';'
}

function Install-Pwsh7Prompt {
    # K25 / ADV-C3 — install pwsh 7 only via the trusted winget source. Verify the
    # default 'winget' source resolves to the official MS CDN before invoking install,
    # so a tampered/replaced source cannot redirect the package fetch.
    $manualUrl = 'https://github.com/PowerShell/PowerShell/releases/latest'

    Write-Warn2 'PowerShell 7 (pwsh) is required to run user scripts from Hub.'
    $resp = Read-Host 'Install Microsoft.PowerShell via winget now? [Y/n]'
    $answer = if ($resp) { $resp.Trim().ToLowerInvariant() } else { '' }
    if ($answer -notin @('', 'y', 'yes')) {
        throw "PowerShell 7 install declined. Install manually from $manualUrl and re-run."
    }

    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) {
        throw "winget not found. Install 'App Installer' from Microsoft Store, or install pwsh manually: $manualUrl"
    }

    Write-Info 'Verifying winget source pin (Microsoft CDN)...'
    $sourcesRaw = ''
    try { $sourcesRaw = (& winget source list 2>&1 | Out-String) } catch { }
    if ($sourcesRaw -notmatch '\bwinget\b\s+https://cdn\.winget\.microsoft\.com/cache') {
        throw "winget default 'winget' source is missing or does not point to the official Microsoft CDN. Refusing to install. Run 'winget source reset' (admin) or install pwsh manually: $manualUrl"
    }

    Write-Info 'Installing Microsoft.PowerShell via winget...'
    & winget install Microsoft.PowerShell `
        --source winget `
        --silent `
        --accept-source-agreements `
        --accept-package-agreements
    $wingetExit = $LASTEXITCODE
    if ($wingetExit -ne 0) {
        throw "winget install failed (exit $wingetExit). Install pwsh manually: $manualUrl"
    }

    Update-EnvPath
    if (-not (Test-Pwsh7)) {
        throw "pwsh 7 still not detected after install. Open a new shell and re-run install-hub.ps1, or install manually: $manualUrl"
    }
    Write-Ok 'PowerShell 7 installed and detected.'
}

function Get-WebExceptionStatus {
    # Cross-version: PS5 throws System.Net.WebException, PS7 throws HttpResponseException.
    # Both expose .Response.StatusCode as System.Net.HttpStatusCode. Return [int] or $null.
    param($Exception)
    if (-not $Exception) { return $null }
    $resp = $null
    try { $resp = $Exception.Response } catch { return $null }
    if (-not $resp) { return $null }
    try { return [int]$resp.StatusCode } catch { return $null }
}

function Get-WebExceptionBody {
    # Best-effort response body read. PS5: GetResponseStream (sync). PS7: HttpResponseMessage.Content (async).
    param($Exception)
    if (-not $Exception) { return '' }
    $resp = $null
    try { $resp = $Exception.Response } catch { return '' }
    if (-not $resp) { return '' }
    try {
        $getStream = $resp.PSObject.Methods['GetResponseStream']
        if ($getStream) {
            $stream = $resp.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($stream)
            try { return $reader.ReadToEnd() } finally { $reader.Close() }
        }
        if ($resp.PSObject.Properties['Content']) {
            return $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        }
    }
    catch { }
    return ''
}

function Get-ReleaseUrl {
    # K24 — tag-pinned by default. 'latest' opt-in path calls the GitHub API.
    # ADV-C3 — distinguish 403 (rate-limit) from 404 (no release) in error messages.
    # ADV-M3 — URL-encode tag segment to defeat any traversal in caller-supplied $Tag.
    param([Parameter(Mandatory)][string]$Tag)

    if ($Tag -ne 'latest') {
        $encTag = [System.Uri]::EscapeDataString($Tag)
        return "https://github.com/$($Script:Repo)/releases/download/$encTag/$($Script:AssetName)"
    }

    $api = "https://api.github.com/repos/$($Script:Repo)/releases/latest"
    $rel = $null
    try {
        $rel = Invoke-RestMethod -Uri $api -UseBasicParsing -ErrorAction Stop -Headers @{
            'User-Agent' = 'install-hub.ps1'
            'Accept'     = 'application/vnd.github+json'
        }
    }
    catch {
        $status = Get-WebExceptionStatus $_.Exception
        if ($status -eq 403) {
            $body = Get-WebExceptionBody $_.Exception
            if ($body -match 'API rate limit exceeded') {
                throw "GitHub API rate-limited. Try again in ~1 hour, or pass -Version v1.5.0.0 to skip 'latest' lookup."
            }
            throw "GitHub API returned 403 (not rate-limit). Body: $body"
        }
        if ($status -eq 404) {
            throw "No release found at $api (404). Verify the repository has a published release."
        }
        throw
    }

    $asset = $rel.assets | Where-Object { $_.name -eq $Script:AssetName } | Select-Object -First 1
    if (-not $asset) {
        throw "Release found but no asset named '$($Script:AssetName)'. Check release contents."
    }
    return $asset.browser_download_url
}

function Save-Release {
    # Download to caller-supplied temp path. Force TLS 1.2 on PS5 boxes where the
    # default ServicePointManager still allows SSL3/TLS1.0.
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Dest
    )
    Write-Info "Downloading $Url"
    try {
        [Net.ServicePointManager]::SecurityProtocol = `
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch { }

    try {
        Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing -Headers @{
            'User-Agent' = 'install-hub.ps1'
        } -ErrorAction Stop
    }
    catch {
        $status = Get-WebExceptionStatus $_.Exception
        if ($status -eq 404) {
            throw "Asset download 404: $Url. Verify the tag and asset name."
        }
        throw
    }

    if (-not (Test-Path $Dest)) {
        throw "Download did not produce $Dest"
    }
    $size = (Get-Item $Dest).Length
    Write-Info "Downloaded $size bytes -> $Dest"
}

function Test-ZipHash {
    # K25 — SHA256 verify. Placeholder '<SHA256_HEX_...>' counts as unset (dev runs).
    # When -VerifyHash is supplied at the script level, caller passes it in here.
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$ExpectedHash
    )
    if (-not $ExpectedHash -or $ExpectedHash -match '^<.*>$') {
        Write-Warn2 'SHA256 verification skipped (no expected hash embedded). Pass -VerifyHash <sha256> to enforce.'
        return
    }
    $actual = (Get-FileHash -Path $Path -Algorithm SHA256).Hash
    if ($actual -ne $ExpectedHash.ToUpperInvariant()) {
        throw "Hub.zip SHA256 mismatch. Expected $($ExpectedHash.ToUpperInvariant()), got $actual. Aborting."
    }
    Write-Ok "SHA256 verified ($actual)."
}

function Expand-Release {
    # Extract verified zip into install dir. Caller is responsible for stopping Hub.exe
    # first; locked Hub.exe will fail Expand-Archive.
    param(
        [Parameter(Mandatory)][string]$Zip,
        [Parameter(Mandatory)][string]$To
    )
    if (-not (Test-Path $To)) {
        New-Item -ItemType Directory -Path $To -Force | Out-Null
    }
    Expand-Archive -Path $Zip -DestinationPath $To -Force
    Write-Ok "Extracted to $To"
}

function Read-ScanRoots {
    # Interactive prompt for scan-root folders. Defaults: %USERPROFILE%\Tools +
    # %USERPROFILE%\Documents\Scripts. Returns string[]. Auto-creates missing folders.
    # K22 — installer-side sanity only: cap at 16 + require rooted path. Hub.ps1
    # re-validates with the full 7-rule Test-ValidScanRoot at runtime.
    $defaults = @(
        (Join-Path $env:USERPROFILE 'Tools'),
        (Join-Path $env:USERPROFILE 'Documents\Scripts')
    )

    Write-Host ''
    Write-Info 'Hub scans these folders for .ps1 / .exe tools:'
    for ($i = 0; $i -lt $defaults.Count; $i++) {
        Write-Host ("  [{0}] {1}" -f ($i + 1), $defaults[$i])
    }
    $resp = Read-Host 'Use these defaults? [Y/n]'
    $answer = if ($resp) { $resp.Trim().ToLowerInvariant() } else { '' }

    $roots = New-Object 'System.Collections.Generic.List[string]'
    if ($answer -in @('', 'y', 'yes')) {
        foreach ($d in $defaults) { $roots.Add($d) | Out-Null }
    }
    else {
        Write-Info 'Enter one folder per line. Empty line to finish (cap 16).'
        while ($roots.Count -lt 16) {
            $p = Read-Host ("  scan-root [{0}]" -f ($roots.Count + 1))
            if ([string]::IsNullOrWhiteSpace($p)) { break }
            $p = $p.Trim('"', "'", ' ')
            if (-not [System.IO.Path]::IsPathRooted($p)) {
                Write-Warn2 "Path must be absolute (rooted): $p — skipped."
                continue
            }
            $roots.Add($p) | Out-Null
        }
        if ($roots.Count -eq 0) {
            Write-Warn2 'No paths entered. Falling back to defaults.'
            foreach ($d in $defaults) { $roots.Add($d) | Out-Null }
        }
    }

    foreach ($r in $roots) {
        if (-not (Test-Path $r)) {
            try {
                New-Item -ItemType Directory -Path $r -Force | Out-Null
                Write-Info "Created $r"
            }
            catch {
                Write-Warn2 "Could not create $r ($($_.Exception.Message)). Hub will skip it."
            }
        }
    }
    return ,$roots.ToArray()
}

function Write-ConfigFile {
    # K12 — writes config to %LOCALAPPDATA%\Hub\hub-config.json (OUTSIDE install dir).
    # No-BOM UTF-8 so Hub.ps1's ConvertFrom-Json never trips on a leading FEFF.
    param([Parameter(Mandatory)][string[]]$ScanRoots)

    if (-not (Test-Path $Script:ConfigDir)) {
        New-Item -ItemType Directory -Path $Script:ConfigDir -Force | Out-Null
    }

    # Skip overwrite if file exists and same content already (idempotent on re-install).
    $payload = [ordered]@{
        version      = 1
        scanRoots    = @($ScanRoots)
        scanMaxDepth = 1
        hiddenIds    = @()
    }
    $json = ($payload | ConvertTo-Json -Depth 4)

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Script:ConfigPath, $json, $utf8NoBom)
    Write-Ok "Config written to $Script:ConfigPath"
}

function Resolve-LongPath {
    # Canonicalize a Windows path: resolve 8.3 short aliases (e.g. PB62C~1.SZA)
    # to long form so string comparisons survive $env:TEMP / $env:LOCALAPPDATA
    # returning 8.3 forms on accounts whose username contains characters that
    # force NTFS 8.3 generation. Get-Item.FullName resolves; GetFullPath does NOT.
    param([Parameter(Mandatory)][string]$Path)
    try { return (Get-Item -LiteralPath $Path -ErrorAction Stop).FullName }
    catch { return [System.IO.Path]::GetFullPath($Path) }
}

function New-StartMenuShortcut {
    # ADV-H4 — disambiguated name ('PowerShell Hub'). Pre-check existing shortcut
    # at the same path: only overwrite when the existing target is inside $InstallDir,
    # so we never trash a different app's link that happens to share the name.
    param([Parameter(Mandatory)][string]$Target)

    if (Test-Path $Script:ShortcutPath) {
        $existingTarget = $null
        $shell = New-Object -ComObject WScript.Shell
        $existing = $null
        try {
            $existing = $shell.CreateShortcut($Script:ShortcutPath)
            $existingTarget = $existing.TargetPath
        }
        finally {
            if ($existing) { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($existing) }
            [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
        }
        if ($existingTarget) {
            $existingResolved = Resolve-LongPath $existingTarget
            $installResolved  = if (Test-Path $InstallDir) { Resolve-LongPath $InstallDir } else { [System.IO.Path]::GetFullPath($InstallDir) }
            if (-not $existingResolved.StartsWith($installResolved, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Shortcut name conflict: '$Script:ShortcutPath' already targets '$existingTarget'. Pass -ShortcutName <unique-name> to override."
            }
        }
    }

    $programsDir = Split-Path $Script:ShortcutPath -Parent
    if (-not (Test-Path $programsDir)) {
        New-Item -ItemType Directory -Path $programsDir -Force | Out-Null
    }

    $shell = New-Object -ComObject WScript.Shell
    $lnk = $null
    try {
        $lnk = $shell.CreateShortcut($Script:ShortcutPath)
        $lnk.TargetPath       = $Target
        $lnk.IconLocation     = "$Target,0"
        $lnk.Description      = 'Local web dashboard for PowerShell scripts and .exe tools'
        $lnk.WorkingDirectory = (Split-Path $Target -Parent)
        $lnk.Save()
    }
    finally {
        if ($lnk) { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($lnk) }
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
    }
    Write-Ok "Shortcut created at $Script:ShortcutPath"
}

function Set-AutostartKey {
    # HKCU\...\Run value name = $ShortcutName so different installs (e.g. parallel
    # forks with -ShortcutName 'Hub Dev') don't collide on the same registry key.
    param(
        [Parameter(Mandatory)][bool]$On,
        [string]$Target
    )
    if ($On) {
        if (-not $Target) { throw 'Set-AutostartKey: -Target required when -On $true.' }
        try {
            Set-ItemProperty -Path $Script:RunKey -Name $ShortcutName -Value ('"' + $Target + '"') -ErrorAction Stop
            Write-Ok "Autostart enabled (HKCU\...\Run\$ShortcutName)."
        }
        catch {
            Write-Warn2 "Autostart write failed: $($_.Exception.Message)"
        }
    }
    else {
        Remove-ItemProperty -Path $Script:RunKey -Name $ShortcutName -ErrorAction SilentlyContinue
    }
}

function Stop-RunningHub {
    # K1 — taskkill /T /F /PID for process-tree kill (same shape Hub uses on jobs).
    # We do NOT discriminate by install path: any running 'Hub' process holds a
    # potential file lock against this extract, so kill them all.
    $procs = Get-Process -Name 'Hub' -ErrorAction SilentlyContinue
    if (-not $procs) { return }
    Write-Info "Stopping $($procs.Count) running Hub.exe process(es)..."
    foreach ($p in $procs) {
        try { & taskkill.exe /T /F /PID $p.Id 2>&1 | Out-Null } catch { }
    }
    for ($i = 0; $i -lt 25; $i++) {
        if (-not (Get-Process -Name 'Hub' -ErrorAction SilentlyContinue)) { return }
        Start-Sleep -Milliseconds 200
    }
    Write-Warn2 'Hub.exe may still be running. Extract may fail if file is locked.'
}

function Start-Hub {
    # Launch Hub.exe then probe /api/health on 127.0.0.1:8765 for up to ~15s.
    # Hub.exe opens the browser itself; we just verify the listener bound.
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { throw "Hub.exe not found: $Path" }
    Write-Info "Launching $Path"
    Start-Process -FilePath $Path | Out-Null

    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Milliseconds 500
        try {
            $r = Invoke-WebRequest -Uri 'http://127.0.0.1:8765/api/health' `
                -UseBasicParsing -TimeoutSec 1 -ErrorAction Stop
            if ($r.StatusCode -eq 200) {
                Write-Ok 'Hub responding on http://127.0.0.1:8765'
                return
            }
        }
        catch { }
    }
    Write-Warn2 'Hub did not respond on 127.0.0.1:8765 within 15s. Open Hub from Start Menu to retry.'
}

# --- Mode dispatchers (filled in tasks 3.3 – 3.8) -----------------------------

function Remove-PathSafe {
    # PS5 Remove-Item -ErrorAction SilentlyContinue does NOT suppress 8.3-alias
    # traversal errors when $ErrorActionPreference='Stop'. Use the .NET APIs so
    # cleanup never propagates a failure.
    param([Parameter(Mandatory)][string]$Path, [switch]$Recurse)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    try {
        $item = Get-Item -LiteralPath $Path -ErrorAction Stop
        if ($item.PSIsContainer) {
            [System.IO.Directory]::Delete($Path, [bool]$Recurse)
        } else {
            [System.IO.File]::Delete($Path)
        }
    } catch { }
}

function Get-StagedZip {
    # Shared helper for Install / Update — downloads or copies the release zip
    # into a temp file, verifies SHA256, returns the temp path. Caller is
    # responsible for Remove-PathSafe on the returned path (finally block).
    $tmpZip = Join-Path $env:TEMP ("Hub-installer-" + [Guid]::NewGuid().ToString('N') + '.zip')

    if ($LocalZip) {
        if (-not (Test-Path $LocalZip)) { throw "-LocalZip path does not exist: $LocalZip" }
        Write-Info "Staging local zip: $LocalZip"
        Copy-Item -LiteralPath $LocalZip -Destination $tmpZip -Force
    }
    else {
        $url = Get-ReleaseUrl -Tag $Version
        Save-Release -Url $url -Dest $tmpZip
    }

    $hashToCheck = if ($VerifyHash) { $VerifyHash } else { $Script:ExpectedZipHash }
    Test-ZipHash -Path $tmpZip -ExpectedHash $hashToCheck
    return $tmpZip
}

function Invoke-Install {
    # Full install flow: pwsh detect -> stage zip -> verify -> extract ->
    # config -> shortcut -> autostart -> launch. Each step prints progress.
    if (-not (Test-Pwsh7)) { Install-Pwsh7Prompt }

    Stop-RunningHub

    if (-not (Test-Path $InstallDir)) {
        New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    }

    $tmpZip = $null
    try {
        $tmpZip = Get-StagedZip
        Expand-Release -Zip $tmpZip -To $InstallDir
    }
    finally {
        if ($tmpZip) { Remove-PathSafe -Path $tmpZip }
    }

    if (-not $ScanRoots) { $ScanRoots = Read-ScanRoots }
    Write-ConfigFile -ScanRoots $ScanRoots

    $exe = Join-Path $InstallDir 'Hub.exe'
    if (-not (Test-Path $exe)) { throw "Hub.exe missing after extract: $exe" }

    try { New-StartMenuShortcut -Target $exe }
    catch { Write-Warn2 "Shortcut creation failed: $($_.Exception.Message)" }

    Set-AutostartKey -On ([bool]$Autostart) -Target $exe

    if (-not $NoLaunch) { Start-Hub -Path $exe }

    Write-Ok ""
    Write-Ok "Hub installed at $InstallDir"
    Write-Ok "Open http://127.0.0.1:8765 in your browser."
    if (-not $Autostart) {
        Write-Info 'Tip: re-run with -Autostart to launch Hub at sign-in.'
    }
}

function Invoke-Update {
    # K12 — config lives at $Script:ConfigPath outside install dir; update never
    # touches it. Mutex-guard (same name Hub uses) prevents racing a running Hub.
    $mutex = New-Object System.Threading.Mutex($false, $Script:HubMutexName)
    $acquired = $false
    try { $acquired = $mutex.WaitOne(0) } catch { $acquired = $false }
    if (-not $acquired) {
        $mutex.Dispose()
        throw 'Hub instance is running. Close it (taskkill /F /IM Hub.exe) then re-run -Update.'
    }
    try {
        Stop-RunningHub

        if (-not (Test-Path $InstallDir)) {
            throw "Install dir not found: $InstallDir. Use -Install for a fresh install."
        }

        $tmpZip = $null
        try {
            $tmpZip = Get-StagedZip
            Expand-Release -Zip $tmpZip -To $InstallDir
        }
        finally {
            if ($tmpZip) { Remove-PathSafe -Path $tmpZip }
        }

        Write-Ok "Hub updated to $Version. Config preserved at $Script:ConfigPath."

        $exe = Join-Path $InstallDir 'Hub.exe'
        if (-not $NoLaunch) { Start-Hub -Path $exe }
    }
    finally {
        try { $mutex.ReleaseMutex() } catch { }
        $mutex.Dispose()
    }
}

function Invoke-Uninstall {
    # ADV-H4 — only remove the shortcut at $Script:ShortcutPath if its target is
    # inside the install dir we're removing. Otherwise it's a different app's link
    # that happened to share the name.
    $mutex = New-Object System.Threading.Mutex($false, $Script:HubMutexName)
    $acquired = $false
    try { $acquired = $mutex.WaitOne(0) } catch { $acquired = $false }
    if (-not $acquired) {
        $mutex.Dispose()
        throw 'Hub instance is running. Close it then re-run -Uninstall.'
    }
    try {
        Stop-RunningHub

        if (-not (Test-Path $InstallDir)) {
            Write-Warn2 "Install dir not found: $InstallDir. Nothing to remove."
            return
        }

        # Read shortcut target BEFORE removing install dir; resolve 8.3 aliases so
        # the StartsWith compare is path-canonical (same fix as New-StartMenuShortcut).
        $shortcutIsOurs = $false
        $existingTarget = $null
        if (Test-Path $Script:ShortcutPath) {
            $shell = New-Object -ComObject WScript.Shell
            $lnk = $null
            try {
                $lnk = $shell.CreateShortcut($Script:ShortcutPath)
                $existingTarget = $lnk.TargetPath
                if ($existingTarget) {
                    $existingResolved = Resolve-LongPath $existingTarget
                    $installResolved  = Resolve-LongPath $InstallDir
                    $shortcutIsOurs = $existingResolved.StartsWith($installResolved, [StringComparison]::OrdinalIgnoreCase)
                }
            }
            finally {
                if ($lnk) { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($lnk) }
                [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
            }
        }

        $confirm = Read-Host "Remove $InstallDir and all contents? [y/N]"
        if ($confirm -notmatch '^(?i)(y|yes)$') {
            Write-Info 'Uninstall cancelled.'
            return
        }
        Remove-PathSafe -Path $InstallDir -Recurse

        if ($shortcutIsOurs) {
            Remove-PathSafe -Path $Script:ShortcutPath
            Write-Ok "Removed shortcut $Script:ShortcutPath"
        }
        elseif (Test-Path $Script:ShortcutPath) {
            Write-Warn2 "Shortcut $Script:ShortcutPath targets a different app ($existingTarget) — left in place."
        }

        Remove-ItemProperty -Path $Script:RunKey -Name $ShortcutName -ErrorAction SilentlyContinue

        if (Test-Path $Script:ConfigDir) {
            $cfgPrompt = Read-Host "Also remove config at ${Script:ConfigDir}? [y/N]"
            if ($cfgPrompt -match '^(?i)(y|yes)$') {
                Remove-PathSafe -Path $Script:ConfigDir -Recurse
                Write-Ok "Removed $Script:ConfigDir"
            }
        }
        Write-Ok 'Uninstalled. Your scan-root folders were not deleted.'
    }
    finally {
        try { $mutex.ReleaseMutex() } catch { }
        $mutex.Dispose()
    }
}

# --- Entry --------------------------------------------------------------------

try {
    switch ($PSCmdlet.ParameterSetName) {
        'Install'   { Invoke-Install }
        'Update'    { Invoke-Update }
        'Uninstall' { Invoke-Uninstall }
        default     { throw "Unknown parameter set: $($PSCmdlet.ParameterSetName)" }
    }
}
catch {
    Write-Err $_.Exception.Message
    exit 1
}
