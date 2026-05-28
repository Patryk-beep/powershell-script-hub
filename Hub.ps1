# Script & Tool Hub Dashboard
# Version 1.0.0.0
# Source. Compiled to Hub.exe via build-hub.ps1 (Phase 6).

param(
    # Extra scan roots appended to defaults — used by tests with fixture folders.
    [string[]]$ExtraScanRoots = @(),

    # Test-only knobs to verify TTL sweeper behaviour without waiting 30 minutes.
    # 0 = use production defaults.
    [int]$FastTtlSeconds = 0,
    [int]$FastSweepSeconds = 0,

    # Override the default port (8765) — used by tests to avoid conflicting with a running Hub.
    [int]$Port = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$Script:Version          = '1.4.13.0'
$Script:Port             = if ($Port -gt 0) { $Port } else { 8765 }
$Script:Listener         = $null
$Script:ListenerHealthy  = $true
$Script:HubMutex         = $null
$Script:Tray             = $null
$Script:Jobs             = [hashtable]::Synchronized(@{})
$Script:Running          = $true   # main-loop flag; Quit menu sets to $false
$Script:CsrfCookieName   = 'hub-csrf'
$Script:CsrfHeader       = 'X-Hub-CSRF'
# Job runtime caps (ADV-002, ADV-010)
$Script:JobBufferLineCap    = 10000
$Script:JobLineByteCap      = 4096
$Script:JobTtlMinutes       = 30
$Script:JobLruCap           = 50
$Script:LastSweepAt         = Get-Date
$Script:SweepIntervalSeconds = 60
if ($FastTtlSeconds   -gt 0) { $Script:JobTtlMinutes      = $FastTtlSeconds / 60.0 }
if ($FastSweepSeconds -gt 0) { $Script:SweepIntervalSeconds = $FastSweepSeconds }
# State routes — exact paths or regex (anchored ^$ at match time).
# K21: '/api/setup' and '/api/browse-folder' use exact literal strings (no regex metachars).
$Script:StateRoutes      = @(
    '/api/run',
    '/api/jobs/.+?/kill',
    '/api/setup',
    '/api/browse-folder',
    '/api/workflows',
    '/api/workflows/.+?',
    '/api/workflows/.+?/run',
    '/api/workflow-runs/.+?/kill',
    '/api/git-roots'
)

# Discovery surface: depth-1 (root + immediate subdirs). Hidden dirs (`.*`, `_*`) skipped.
$Script:ScanMaxDepth      = 1
$Script:AllowedExtensions = @('.ps1', '.exe')

# Hub config (K12) — at %LOCALAPPDATA%\Hub\, NOT next to exe (ADV-C2 OneDrive KFM).
# Decouples config from install dir; survives reinstalls; stable for -Update mode.
$Script:ConfigVersion = 1
$Script:MaxScanRoots  = 16                                                       # K22
$Script:ConfigDir     = Join-Path $env:LOCALAPPDATA 'Hub'
$Script:ConfigPath    = Join-Path $Script:ConfigDir 'hub-config.json'
$Script:NeedsSetup    = $false
$Script:Config        = $null                                                    # populated by Get-HubConfigOrDefault at startup
$Script:LastBrowseFolderAt = [DateTime]::MinValue                                # ADV-M6 rate-limit

# PS2EXE-safe script root resolution.
# Reason: $PSScriptRoot is $null when running from PS2EXE-compiled .exe.
$Script:ScriptRoot = if ($PSScriptRoot) {
    $PSScriptRoot
} else {
    $entry = [System.Reflection.Assembly]::GetEntryAssembly()
    if ($entry -and $entry.Location) {
        [System.IO.Path]::GetDirectoryName($entry.Location)
    } else {
        [System.IO.Path]::GetDirectoryName([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
    }
}
# Reason: GetFullPath (not Resolve-Path) — 8.3 short-alias under dot-username breaks StartsWith.
$Script:ScriptRoot = [System.IO.Path]::GetFullPath($Script:ScriptRoot)
$Script:WwwRoot    = [System.IO.Path]::GetFullPath((Join-Path $Script:ScriptRoot 'wwwroot'))
$Script:InstallDir = $Script:ScriptRoot                                          # K22 — used by Test-ValidScanRoot

# Ensure config dir exists at startup (K12). Fail hard with MessageBox if uncreatable.
try {
    if (-not [System.IO.Directory]::Exists($Script:ConfigDir)) {
        [System.IO.Directory]::CreateDirectory($Script:ConfigDir) | Out-Null
    }
} catch {
    [System.Windows.Forms.MessageBox]::Show(
        "Cannot create config directory:`n$Script:ConfigDir`n`n$($_.Exception.Message)",
        'Hub - Setup error', 'OK', 'Error') | Out-Null
    exit 1
}

if (-not (Test-Path -LiteralPath $Script:WwwRoot)) {
    [System.Windows.Forms.MessageBox]::Show(
        "Missing wwwroot directory:`n$Script:WwwRoot",
        'Hub - Setup error', 'OK', 'Error') | Out-Null
    exit 1
}

# Dot-source feature modules (ADV2-003: after all $Script: globals + config dir creation,
# before any function definitions so modules can define functions at load time).
. (Join-Path $Script:ScriptRoot 'Hub-Workflows.ps1')
. (Join-Path $Script:ScriptRoot 'Hub-WorkflowEngine.ps1')
. (Join-Path $Script:ScriptRoot 'Hub-Triggers.ps1')
. (Join-Path $Script:ScriptRoot 'Hub-Git.ps1')
. (Join-Path $Script:ScriptRoot 'Hub-History.ps1')

function Write-HubError {
    param($Err)
    $logPath = Join-Path $env:TEMP 'hub-error.log'
    $ts = (Get-Date).ToString('o')
    $msg = if ($Err -is [System.Management.Automation.ErrorRecord]) {
        "$($Err.Exception.GetType().FullName): $($Err.Exception.Message)`n$($Err.ScriptStackTrace)"
    } else { "$Err" }
    try { Add-Content -LiteralPath $logPath -Value "[$ts] $msg" -Encoding utf8 } catch { }
}

function Test-SingleInstance {
    [OutputType([bool])]
    param()
    # Per-user mutex name — different OS users get independent Hubs.
    $userTag = ($env:USERNAME -replace '[^A-Za-z0-9_.-]', '_')
    $mutexName = "Global\HubInstance.$userTag"
    $createdNew = $false
    $Script:HubMutex = [System.Threading.Mutex]::new($false, $mutexName, [ref]$createdNew)
    if (-not $createdNew) {
        $portFile = Join-Path $env:TEMP 'hub.port'
        $targetPort = $Script:Port
        if (Test-Path -LiteralPath $portFile) {
            try {
                $raw = (Get-Content -LiteralPath $portFile -ErrorAction Stop -Raw).Trim()
                $parsed = 0
                if ([int]::TryParse($raw, [ref]$parsed) -and $parsed -ge 1024 -and $parsed -le 65535) {
                    $targetPort = $parsed
                }
            } catch { }
        }
        try { Start-Process "http://127.0.0.1:$targetPort/" } catch { }
        return $false
    }
    return $true
}

function New-CsrfToken {
    [OutputType([string])]
    param()
    return [guid]::NewGuid().Guid
}

function Get-MimeType {
    [OutputType([string])]
    param([string]$Extension)
    switch -Regex ($Extension.ToLowerInvariant()) {
        '\.html?$' { 'text/html; charset=utf-8'; break }
        '\.js$'    { 'application/javascript; charset=utf-8'; break }
        '\.css$'   { 'text/css; charset=utf-8'; break }
        '\.json$'  { 'application/json; charset=utf-8'; break }
        '\.svg$'   { 'image/svg+xml'; break }
        '\.png$'   { 'image/png'; break }
        '\.ico$'   { 'image/x-icon'; break }
        '\.txt$'   { 'text/plain; charset=utf-8'; break }
        '\.woff2$' { 'font/woff2'; break }
        '\.woff$'  { 'font/woff'; break }
        default    { 'application/octet-stream' }
    }
}

function Write-JsonResponse {
    param([System.Net.HttpListenerContext]$Context, [int]$Status, $Body)
    $json  = $Body | ConvertTo-Json -Depth 6 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $Context.Response.StatusCode      = $Status
    $Context.Response.ContentType     = 'application/json; charset=utf-8'
    $Context.Response.ContentLength64 = $bytes.LongLength
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
}

function Write-TextResponse {
    param([System.Net.HttpListenerContext]$Context, [int]$Status, [string]$Text)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $Context.Response.StatusCode      = $Status
    $Context.Response.ContentType     = 'text/plain; charset=utf-8'
    $Context.Response.ContentLength64 = $bytes.LongLength
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
}

function Get-RequestCsrfCookie {
    [OutputType([string])]
    param([System.Net.HttpListenerRequest]$Request)
    if ($null -eq $Request.Cookies) { return $null }
    foreach ($c in $Request.Cookies) {
        if ($c.Name -eq $Script:CsrfCookieName) { return $c.Value }
    }
    return $null
}

function Test-IsStateRoute {
    [OutputType([bool])]
    param([string]$Path)
    foreach ($pattern in $Script:StateRoutes) {
        if ($Path -match "^$pattern$") { return $true }
    }
    return $false
}

function Invoke-SecurityMiddleware {
    [OutputType([bool])]
    param([System.Net.HttpListenerContext]$Context, [int]$Port)
    $req  = $Context.Request
    $path = $req.Url.AbsolutePath

    # Set CSRF cookie on root GET if absent.
    # Reason: NOT HttpOnly — JS must read this cookie to send X-Hub-CSRF on state requests.
    if ($path -eq '/' -and $req.HttpMethod -eq 'GET') {
        $existing = Get-RequestCsrfCookie -Request $req
        if (-not $existing) {
            $token = New-CsrfToken
            $Context.Response.Headers.Add('Set-Cookie', "$Script:CsrfCookieName=$token; Path=/; SameSite=Strict")
        }
        return $true
    }

    # Enforcement applies only to /api/* — static files have their own traversal guard.
    if (-not $path.StartsWith('/api/')) { return $true }

    # Origin allowlist
    $origin = $req.Headers['Origin']
    if ($origin) {
        if ($origin -notmatch '^https?://(127\.0\.0\.1|localhost)(:\d+)?$') {
            Write-JsonResponse -Context $Context -Status 403 -Body @{ error = 'origin' }
            return $false
        }
    } elseif ($req.HttpMethod -ne 'GET') {
        Write-JsonResponse -Context $Context -Status 403 -Body @{ error = 'origin' }
        return $false
    }

    # Host header pin — DNS-rebinding defense.
    $hostHeader = $req.Headers['Host']
    if (-not $hostHeader -or ($hostHeader -ne "127.0.0.1:$Port" -and $hostHeader -ne "localhost:$Port")) {
        Write-JsonResponse -Context $Context -Status 421 -Body @{ error = 'host' }
        return $false
    }

    # Content-Type strict for POST
    if ($req.HttpMethod -eq 'POST') {
        $ct = if ($req.ContentType) { ($req.ContentType -split ';')[0].Trim().ToLowerInvariant() } else { $null }
        if ($ct -ne 'application/json') {
            Write-JsonResponse -Context $Context -Status 415 -Body @{ error = 'content-type' }
            return $false
        }
    }

    # CSRF token check for state routes (non-GET only — GET requests are read-only and never mutate state).
    if ($req.HttpMethod -ne 'GET' -and (Test-IsStateRoute -Path $path)) {
        $cookie = Get-RequestCsrfCookie -Request $req
        $header = $req.Headers[$Script:CsrfHeader]
        if (-not $cookie -or -not $header -or $cookie -ne $header) {
            Write-JsonResponse -Context $Context -Status 403 -Body @{ error = 'csrf' }
            return $false
        }
    }

    return $true
}

function Invoke-StaticFileRoute {
    param([System.Net.HttpListenerContext]$Context, [string]$WwwRoot)
    $path = $Context.Request.Url.AbsolutePath
    $relative = if ($path -eq '/') { 'index.html' } else { $path.TrimStart('/') }
    $candidate = Join-Path $WwwRoot $relative
    try {
        $resolved = [System.IO.Path]::GetFullPath($candidate)
    } catch {
        Write-TextResponse -Context $Context -Status 404 -Text 'Not Found'
        return
    }
    if (-not $resolved.StartsWith($WwwRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-TextResponse -Context $Context -Status 404 -Text 'Not Found'
        return
    }
    if (-not [System.IO.File]::Exists($resolved)) {
        Write-TextResponse -Context $Context -Status 404 -Text 'Not Found'
        return
    }
    $ext   = [System.IO.Path]::GetExtension($resolved)
    $bytes = [System.IO.File]::ReadAllBytes($resolved)
    $Context.Response.StatusCode      = 200
    $Context.Response.ContentType     = Get-MimeType -Extension $ext
    $Context.Response.ContentLength64 = $bytes.LongLength
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
}

function Read-ScriptAst {
    # Parse a .ps1 with explicit UTF-8 decoding + BOM detection. PS5 (Hub.exe runtime)
    # otherwise defaults to the system codepage and mis-decodes UTF-8 multi-byte glyphs
    # (e.g. ✓ ✗) as garbage, producing spurious parse-errors that fall through to raw mode.
    # Returns @{ ast; tokens; errors } — ast is $null on hard read failure.
    [OutputType([hashtable])]
    param([string]$Path)
    $out = @{ ast = $null; tokens = $null; errors = @() }
    $reader = $null
    try {
        # StreamReader with detectEncodingFromByteOrderMarks=$true honours UTF-8 / UTF-16 / UTF-32 BOMs;
        # falls back to the supplied encoding (UTF-8) when no BOM is present.
        $reader = New-Object System.IO.StreamReader($Path, [System.Text.Encoding]::UTF8, $true)
        $text = $reader.ReadToEnd()
    } catch {
        Write-HubError $_
        return $out
    } finally {
        if ($null -ne $reader) { try { $reader.Dispose() } catch { } }
    }
    try {
        $tokens = $null; $errors = $null
        $out.ast    = [System.Management.Automation.Language.Parser]::ParseInput(
            $text, $Path, [ref]$tokens, [ref]$errors)
        $out.tokens = $tokens
        $out.errors = $errors
    } catch {
        Write-HubError $_
    }
    return $out
}

function Get-HubCacheDir {
    [OutputType([string])]
    param()
    $base = $env:LOCALAPPDATA
    if ([string]::IsNullOrWhiteSpace($base)) {
        $base = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), 'HubFallback')
    }
    $dir = Join-Path $base 'Hub'
    if (-not [System.IO.Directory]::Exists($dir)) {
        try { New-Item -ItemType Directory -Path $dir -Force | Out-Null } catch { Write-HubError $_ }
    }
    return $dir
}

function Get-SchemaCache {
    [OutputType([hashtable])]
    param()
    $path = Join-Path (Get-HubCacheDir) 'schema-cache.json'
    if (-not [System.IO.File]::Exists($path)) { return @{} }
    try {
        $raw = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
        if ([string]::IsNullOrWhiteSpace($raw)) { return @{} }
        $obj = $raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        if ($null -eq $obj) { return @{} }
        return $obj
    } catch {
        Write-HubError $_
        return @{}
    }
}

function Save-SchemaCache {
    param([hashtable]$Cache)
    if ($null -eq $Cache) { return }
    $dir  = Get-HubCacheDir
    $path = Join-Path $dir 'schema-cache.json'
    $tmp  = $path + '.tmp'
    try {
        $json = $Cache | ConvertTo-Json -Depth 8 -Compress
        [System.IO.File]::WriteAllText($tmp, $json, [System.Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $tmp -Destination $path -Force
    } catch {
        Write-HubError $_
        try { if ([System.IO.File]::Exists($tmp)) { [System.IO.File]::Delete($tmp) } } catch { }
    }
}

function Get-ItemDescription {
    # Returns a single-line description for a .ps1 or .exe item.
    #   .ps1 → AST GetHelpContent().Synopsis (no script execution)
    #   .exe → FileVersionInfo.FileDescription, fallback ProductName
    # Whitespace collapsed; capped at 280 chars.
    [OutputType([string])]
    param([string]$Path, [string]$Kind)
    try {
        if ($Kind -eq 'ps1') {
            $parsed = Read-ScriptAst -Path $Path
            $ast = $parsed.ast
            if ($null -eq $ast) { return '' }
            $help = $ast.GetHelpContent()
            if ($help -and $help.Synopsis) {
                $line = ($help.Synopsis -replace '\s+', ' ').Trim()
                if ($line.Length -gt 280) { $line = $line.Substring(0, 277) + '…' }
                return $line
            }
            return ''
        }
        elseif ($Kind -eq 'exe') {
            $info = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
            $desc = ''
            if ($info -and $info.FileDescription) { $desc = "$($info.FileDescription)" }
            elseif ($info -and $info.ProductName)  { $desc = "$($info.ProductName)" }
            $desc = ($desc -replace '\s+', ' ').Trim()
            if ($desc.Length -gt 280) { $desc = $desc.Substring(0, 277) + '…' }
            return $desc
        }
        return ''
    } catch {
        Write-HubError $_
        return ''
    }
}

function ConvertTo-StableId {
    [OutputType([string])]
    param([string]$Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Path)
        $hash  = $sha.ComputeHash($bytes)
        $hex   = -join ($hash[0..5] | ForEach-Object { $_.ToString('x2') })
        return $hex
    } finally { $sha.Dispose() }
}

function Get-DefaultScanRoots {
    [OutputType([string[]])]
    param()
    return @(
        (Join-Path $env:USERPROFILE 'Tools'),
        (Join-Path $env:USERPROFILE 'Documents\Scripts')
    )
}

function Test-ValidScanRoot {
    # K22, ADV-C1: 7-rule rejection. Returns $true only if all checks pass.
    [OutputType([bool])]
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    # Rule 7: contains traversal segments (defensive pre-canonicalize check)
    if ($Path.Contains('..')) { return $false }
    # Rule 2: UNC paths rejected before canonicalize (since GetFullPath preserves UNC).
    if ($Path.StartsWith('\\')) { return $false }
    # Canonicalize.
    try { $canonical = [System.IO.Path]::GetFullPath($Path) } catch { return $false }
    # Rule 1: must equal canonical (i.e. absolute & well-formed).
    if ($canonical -ne [System.IO.Path]::GetFullPath($canonical)) { return $false }
    if (-not [System.IO.Path]::IsPathRooted($canonical)) { return $false }
    $cmp = [System.StringComparison]::OrdinalIgnoreCase

    $sysRoot = "$env:SystemRoot"
    $progF1  = "$env:ProgramFiles"
    $progF2  = "${env:ProgramFiles(x86)}"
    # Rule 3: system root
    if ($sysRoot -and ($canonical.Equals($sysRoot, $cmp) -or $canonical.StartsWith($sysRoot + '\', $cmp))) { return $false }
    # Rule 4: Program Files
    if ($progF1 -and ($canonical.Equals($progF1, $cmp) -or $canonical.StartsWith($progF1 + '\', $cmp))) { return $false }
    if ($progF2 -and ($canonical.Equals($progF2, $cmp) -or $canonical.StartsWith($progF2 + '\', $cmp))) { return $false }
    # Rule 5: install dir reflection
    if ($Script:InstallDir -and ($canonical.Equals($Script:InstallDir, $cmp) -or $canonical.StartsWith($Script:InstallDir.TrimEnd('\') + '\', $cmp))) { return $false }
    # Rule 6: config dir reflection
    if ($Script:ConfigDir -and ($canonical.Equals($Script:ConfigDir, $cmp) -or $canonical.StartsWith($Script:ConfigDir.TrimEnd('\') + '\', $cmp))) { return $false }
    return $true
}

function Read-HubConfig {
    # Returns hashtable or $null on missing/malformed/unknown-version (ADV-H3).
    # NOTE: avoids `ConvertFrom-Json -AsHashtable` (PS6+ only). Hub.exe is PS2EXE-compiled
    # against .NET Framework / Windows PowerShell 5, so we parse as PSCustomObject and
    # convert manually.
    [OutputType([hashtable])]
    param()
    if (-not [System.IO.File]::Exists($Script:ConfigPath)) { return $null }
    try {
        $raw = [System.IO.File]::ReadAllText($Script:ConfigPath, [System.Text.Encoding]::UTF8)
        $obj = $raw | ConvertFrom-Json
        if ($null -eq $obj) { return $null }

        $versionProp = $obj.PSObject.Properties['version']
        if (-not $versionProp -or [int]$versionProp.Value -ne $Script:ConfigVersion) {
            $seen = if ($versionProp) { $versionProp.Value } else { '<missing>' }
            Write-HubError "hub-config.json has unknown version '$seen'; expected $Script:ConfigVersion. Falling back to defaults."
            return $null
        }

        $rootsProp = $obj.PSObject.Properties['scanRoots']
        if (-not $rootsProp -or $null -eq $rootsProp.Value) {
            Write-HubError 'hub-config.json missing or malformed scanRoots; falling back.'
            return $null
        }
        $roots = @($rootsProp.Value | ForEach-Object { [string]$_ } | Where-Object { $_ })

        $depthProp = $obj.PSObject.Properties['scanMaxDepth']
        $depth = if ($depthProp) { [int]$depthProp.Value } else { 1 }

        $grProp   = $obj.PSObject.Properties['gitRoots']
        $gitRoots = if ($grProp -and $grProp.Value) { @($grProp.Value) } else { @() }

        return @{ version = $Script:ConfigVersion; scanRoots = $roots; scanMaxDepth = $depth; gitRoots = $gitRoots }
    } catch {
        Write-HubError $_
        return $null
    }
}

function Write-HubConfig {
    # Atomic-ish: write temp then delete + move (sub-ms window). Portable across PS5/PS7.
    # [File]::Replace 3-arg overload rejects null backup arg under some .NET runtimes
    # (PS 7.5 reported "The path is empty"). Delete-then-move avoids the overload issue.
    param([hashtable]$Config)
    if (-not $Config) { throw 'Write-HubConfig: Config is required' }
    $tmp = $Script:ConfigPath + '.tmp'
    $json = $Config | ConvertTo-Json -Depth 4
    [System.IO.File]::WriteAllText($tmp, $json, [System.Text.Encoding]::UTF8)
    if ([System.IO.File]::Exists($Script:ConfigPath)) {
        [System.IO.File]::Delete($Script:ConfigPath)
    }
    [System.IO.File]::Move($tmp, $Script:ConfigPath)
}

function Get-HubConfigOrDefault {
    # Returns persisted config OR builds default and sets $Script:NeedsSetup = $true.
    [OutputType([hashtable])]
    param()
    $cfg = Read-HubConfig
    if ($null -ne $cfg) { return $cfg }
    $Script:NeedsSetup = $true
    return @{
        version      = $Script:ConfigVersion
        scanRoots    = (Get-DefaultScanRoots)
        scanMaxDepth = 1
    }
}

function Get-EffectiveScanRoots {
    # K23 — config.scanRoots + test-only $ExtraScanRoots. /api/config never returns this.
    [OutputType([string[]])]
    param()
    $roots = @()
    if ($Script:Config -and $Script:Config.scanRoots) { $roots = @($Script:Config.scanRoots) }
    if ($ExtraScanRoots) { $roots = $roots + @($ExtraScanRoots | Where-Object { $_ }) }
    if ($Script:GitScanRoots -and $Script:GitScanRoots.Count -gt 0) { $roots = $roots + @($Script:GitScanRoots) }
    return @($roots | Where-Object { $_ })
}

function Get-HubItems {
    [OutputType([hashtable])]
    param()
    $items    = New-Object 'System.Collections.Generic.List[hashtable]'
    $warnings = New-Object 'System.Collections.Generic.List[string]'

    # Schema cache (advisory): keyed by full path → @{ mtime; size; description; paramPreview; schemaMode }.
    $cache     = Get-SchemaCache
    $nextCache = @{}

    # Build a lookup of scan-root prefixes for defence-in-depth verification (ADV-C1).
    $scanRoots = @(Get-EffectiveScanRoots)
    $rootNorms = @()
    foreach ($r in $scanRoots) {
        try { $rootNorms += ([System.IO.Path]::GetFullPath($r)) } catch { Write-HubError $_ }
    }

    foreach ($root in $scanRoots) {
        if (-not [System.IO.Directory]::Exists($root)) {
            $warnings.Add("Scan root unavailable: $root")
            continue
        }

        # Build list of dirs to scan: root + immediate subdirs (skip .* / _*).
        $dirs = New-Object 'System.Collections.Generic.List[string]'
        $dirs.Add($root)
        if ($Script:ScanMaxDepth -ge 1) {
            try {
                foreach ($sub in [System.IO.Directory]::EnumerateDirectories(
                        $root, '*', [System.IO.SearchOption]::TopDirectoryOnly)) {
                    $leaf = [System.IO.Path]::GetFileName($sub)
                    if ($leaf.StartsWith('.') -or $leaf.StartsWith('_')) { continue }
                    $dirs.Add($sub)
                }
            } catch {
                Write-HubError $_
                $warnings.Add("Cannot enumerate subdirs of: $root")
            }
        }

        foreach ($dir in $dirs) {
            try {
                $files = [System.IO.Directory]::EnumerateFiles(
                    $dir, '*', [System.IO.SearchOption]::TopDirectoryOnly)
            } catch {
                Write-HubError $_
                $warnings.Add("Cannot enumerate: $dir")
                continue
            }
            foreach ($path in $files) {
                try {
                    $ext = [System.IO.Path]::GetExtension($path).ToLowerInvariant()
                    if ($Script:AllowedExtensions -notcontains $ext) { continue }
                    # OneDrive ghost-file detection (ADV-009).
                    # FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS = 0x00400000
                    # FILE_ATTRIBUTE_RECALL_ON_OPEN        = 0x00040000
                    # Reading these flags does NOT materialize the file — only content access does.
                    $attrs = [int]([System.IO.File]::GetAttributes($path))
                    $cloudOnly = (($attrs -band 0x00400000) -ne 0) -or (($attrs -band 0x00040000) -ne 0)
                    $mtime = [System.IO.File]::GetLastWriteTimeUtc($path)
                    $kind = $ext.TrimStart('.')

                    # Defence in depth — re-confirm path is under a current scan root (cache may be stale).
                    $resolved = [System.IO.Path]::GetFullPath($path)
                    $underRoot = $false
                    foreach ($rn in $rootNorms) {
                        if ($resolved.StartsWith($rn, [System.StringComparison]::OrdinalIgnoreCase)) {
                            $underRoot = $true; break
                        }
                    }
                    if (-not $underRoot) {
                        $warnings.Add("Skipped (not under scan root): $path")
                        continue
                    }

                    # Cache key: path + mtime ticks + size. Hit ⇒ reuse description/preview/schemaMode.
                    $size = 0
                    try { $size = (Get-Item -LiteralPath $path -Force).Length } catch { }
                    $mtimeTicks = $mtime.Ticks
                    $cacheKey   = $path
                    $cached     = $null
                    if ($cache.ContainsKey($cacheKey)) {
                        $candidate = $cache[$cacheKey]
                        if ($null -ne $candidate -and
                            $candidate.ContainsKey('mtimeTicks') -and
                            $candidate.ContainsKey('size') -and
                            [int64]$candidate.mtimeTicks -eq $mtimeTicks -and
                            [int64]$candidate.size -eq $size) {
                            $cached = $candidate
                        }
                    }

                    if ($cloudOnly) {
                        # OneDrive ghost: never parse.
                        $desc         = ''
                        $paramPreview = $null
                        $schemaMode   = 'raw'
                    } elseif ($cached) {
                        $desc         = [string]$cached.description
                        $paramPreview = $cached.paramPreview
                        $schemaMode   = [string]$cached.schemaMode
                    } else {
                        $meta = Get-ItemMetadata -Path $path -Kind $kind -CloudOnly:$false
                        $desc         = $meta.description
                        $paramPreview = $meta.paramPreview
                        $schemaMode   = $meta.schemaMode
                    }

                    $items.Add(@{
                        id           = ConvertTo-StableId -Path $path
                        name         = [System.IO.Path]::GetFileNameWithoutExtension($path)
                        kind         = $kind
                        path         = $path
                        # Containing directory (depth-1 friendly), not scan root.
                        root         = [System.IO.Path]::GetDirectoryName($path)
                        mtime        = $mtime.ToString('o')
                        cloudOnly    = $cloudOnly
                        description  = $desc
                        paramPreview = $paramPreview
                        schemaMode   = $schemaMode
                    })

                    # Cache only non-cloud items (cloud has nothing to cache).
                    if (-not $cloudOnly) {
                        $nextCache[$cacheKey] = @{
                            mtimeTicks   = $mtimeTicks
                            size         = $size
                            description  = $desc
                            paramPreview = $paramPreview
                            schemaMode   = $schemaMode
                        }
                    }
                } catch {
                    Write-HubError $_
                    continue
                }
            }
        }
    }

    # Persist cache (best-effort).
    Save-SchemaCache -Cache $nextCache

    $sorted = $items | Sort-Object -Property @{Expression = { $_.name.ToLowerInvariant() }}
    return @{ items = @($sorted); warnings = @($warnings) }
}

function Invoke-ItemsRoute {
    param([System.Net.HttpListenerContext]$Context)
    if ($Context.Request.HttpMethod -ne 'GET') {
        Write-JsonResponse -Context $Context -Status 405 -Body @{ error = 'method-not-allowed' }
        return
    }
    try {
        $result = Get-HubItems
        Write-JsonResponse -Context $Context -Status 200 -Body $result
    } catch {
        Write-HubError $_
        Write-JsonResponse -Context $Context -Status 500 -Body @{ error = 'scan-failed' }
    }
}

function Get-ParamHelpFromComments {
    # Extracts comment-based help .PARAMETER entries. Returns hashtable keyed by lowercase name.
    [OutputType([hashtable])]
    param([System.Management.Automation.Language.ScriptBlockAst]$Ast)
    $out = @{}
    if ($null -eq $Ast) { return $out }
    try {
        $help = $Ast.GetHelpContent()
        if ($help -and $help.Parameters) {
            foreach ($k in $help.Parameters.Keys) {
                $v = $help.Parameters[$k]
                if ($null -ne $v) {
                    $out[$k.ToLowerInvariant()] = ($v -replace '\s+', ' ').Trim()
                }
            }
        }
    } catch {
        Write-HubError $_
    }
    return $out
}

function ConvertTo-WidgetSpec {
    [OutputType([hashtable])]
    param(
        [System.Management.Automation.Language.ParameterAst]$ParamAst,
        [hashtable]$CommentHelp = $null
    )

    $spec = @{
        name         = $ParamAst.Name.VariablePath.UserPath
        widget       = 'textbox'
        type         = 'string'
        required     = $false
        default      = $null
        help         = $null
        aliases      = @()
        position     = $null
        parameterSet = '__AllParameterSets'
        allowEmpty   = $false
        options      = $null
        min          = $null
        max          = $null
        step         = $null
        pattern      = $null
        minlength    = $null
        maxlength    = $null
        countMin     = $null
        countMax     = $null
    }

    if ($ParamAst.DefaultValue) {
        $dv = $ParamAst.DefaultValue
        if ($dv -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
            $spec.default = $dv.Value
        } elseif ($dv -is [System.Management.Automation.Language.ConstantExpressionAst]) {
            $spec.default = $dv.Value
        } elseif ($dv -is [System.Management.Automation.Language.VariableExpressionAst]) {
            # e.g. $true / $false / $null
            $vp = $dv.VariablePath.UserPath
            switch ($vp.ToLowerInvariant()) {
                'true'  { $spec.default = $true; break }
                'false' { $spec.default = $false; break }
                'null'  { $spec.default = $null; break }
                default { $spec.default = $dv.Extent.Text }
            }
        } else {
            $spec.default = $dv.Extent.Text
        }
    }

    $typeName = $null
    foreach ($attr in $ParamAst.Attributes) {
        if ($attr -is [System.Management.Automation.Language.TypeConstraintAst]) {
            $typeName = $attr.TypeName.Name
            continue
        }
        if ($attr -is [System.Management.Automation.Language.AttributeAst]) {
            $aname = $attr.TypeName.Name
            if ($aname -eq 'Parameter' -or $aname -eq 'ParameterAttribute') {
                foreach ($named in $attr.NamedArguments) {
                    switch ($named.ArgumentName) {
                        'Mandatory' {
                            # Mandatory or Mandatory=$true
                            if ($named.ExpressionOmitted) {
                                $spec.required = $true
                            } elseif ($named.Argument -is [System.Management.Automation.Language.VariableExpressionAst] -and
                                      $named.Argument.VariablePath.UserPath.ToLowerInvariant() -eq 'true') {
                                $spec.required = $true
                            }
                        }
                        'HelpMessage' {
                            if ($named.Argument -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                                $spec.help = $named.Argument.Value
                            }
                        }
                        'Position' {
                            try {
                                if ($named.Argument -is [System.Management.Automation.Language.ConstantExpressionAst]) {
                                    $spec.position = [int]$named.Argument.Value
                                }
                            } catch { Write-HubError $_ }
                        }
                        'ParameterSetName' {
                            if ($named.Argument -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                                $spec.parameterSet = $named.Argument.Value
                            }
                        }
                    }
                }
            } elseif ($aname -eq 'ValidateSet' -or $aname -eq 'ValidateSetAttribute') {
                $vals = @()
                foreach ($pa in $attr.PositionalArguments) {
                    if ($pa -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                        $vals += $pa.Value
                    } elseif ($pa -is [System.Management.Automation.Language.ConstantExpressionAst]) {
                        $vals += [string]$pa.Value
                    }
                }
                if ($vals.Count -gt 0) {
                    $spec.widget  = 'dropdown'
                    $spec.options = $vals
                }
            } elseif ($aname -eq 'ValidateRange' -or $aname -eq 'ValidateRangeAttribute') {
                try {
                    if ($attr.PositionalArguments.Count -ge 2) {
                        $a0 = $attr.PositionalArguments[0]
                        $a1 = $attr.PositionalArguments[1]
                        if ($a0 -is [System.Management.Automation.Language.ConstantExpressionAst] -and
                            $a1 -is [System.Management.Automation.Language.ConstantExpressionAst]) {
                            $spec.min = $a0.Value
                            $spec.max = $a1.Value
                        }
                    }
                } catch { Write-HubError $_ }
            } elseif ($aname -eq 'ValidatePattern' -or $aname -eq 'ValidatePatternAttribute') {
                try {
                    if ($attr.PositionalArguments.Count -ge 1 -and
                        $attr.PositionalArguments[0] -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                        $spec.pattern = $attr.PositionalArguments[0].Value
                    }
                } catch { Write-HubError $_ }
            } elseif ($aname -eq 'ValidateLength' -or $aname -eq 'ValidateLengthAttribute') {
                try {
                    if ($attr.PositionalArguments.Count -ge 2 -and
                        $attr.PositionalArguments[0] -is [System.Management.Automation.Language.ConstantExpressionAst] -and
                        $attr.PositionalArguments[1] -is [System.Management.Automation.Language.ConstantExpressionAst]) {
                        $spec.minlength = [int]$attr.PositionalArguments[0].Value
                        $spec.maxlength = [int]$attr.PositionalArguments[1].Value
                    }
                } catch { Write-HubError $_ }
            } elseif ($aname -eq 'ValidateCount' -or $aname -eq 'ValidateCountAttribute') {
                try {
                    if ($attr.PositionalArguments.Count -ge 2 -and
                        $attr.PositionalArguments[0] -is [System.Management.Automation.Language.ConstantExpressionAst] -and
                        $attr.PositionalArguments[1] -is [System.Management.Automation.Language.ConstantExpressionAst]) {
                        $spec.countMin = [int]$attr.PositionalArguments[0].Value
                        $spec.countMax = [int]$attr.PositionalArguments[1].Value
                    }
                } catch { Write-HubError $_ }
            } elseif ($aname -eq 'ValidateNotNullOrEmpty' -or $aname -eq 'ValidateNotNullOrEmptyAttribute' -or
                      $aname -eq 'ValidateNotNull' -or $aname -eq 'ValidateNotNullAttribute') {
                $spec.required = $true
            } elseif ($aname -eq 'ValidateScript' -or $aname -eq 'ValidateScriptAttribute') {
                $note = 'Custom validation runs server-side.'
                if ([string]::IsNullOrEmpty($spec.help)) { $spec.help = $note }
                else { $spec.help = "$($spec.help) $note" }
            } elseif ($aname -eq 'Alias' -or $aname -eq 'AliasAttribute') {
                $als = @()
                foreach ($pa in $attr.PositionalArguments) {
                    if ($pa -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                        $als += $pa.Value
                    }
                }
                if ($als.Count -gt 0) { $spec.aliases = $als }
            } elseif ($aname -eq 'AllowNull' -or $aname -eq 'AllowNullAttribute' -or
                      $aname -eq 'AllowEmptyString' -or $aname -eq 'AllowEmptyStringAttribute' -or
                      $aname -eq 'AllowEmptyCollection' -or $aname -eq 'AllowEmptyCollectionAttribute') {
                $spec.allowEmpty = $true
            }
        }
    }

    if ($typeName) {
        # Normalize: strip namespace (e.g. System.Guid → guid). Brackets stay so array types match.
        $bare = $typeName
        $lastDot = $bare.LastIndexOf('.')
        if ($lastDot -ge 0 -and -not $bare.StartsWith('System.IO.', [System.StringComparison]::OrdinalIgnoreCase)) {
            $bare = $bare.Substring($lastDot + 1)
        }
        $tnLow = $bare.ToLowerInvariant()
        $spec.type = $tnLow
        if ($spec.widget -ne 'dropdown') {
            switch -Regex ($tnLow) {
                '^string$'                                 { $spec.widget = 'textbox';         break }
                '^(int|int32|int64|long|uint32)$'          { $spec.widget = 'number';          break }
                '^(double|decimal|float|single)$'          { $spec.widget = 'number'; $spec.step = 'any'; break }
                '^(bool|boolean)$'                         { $spec.widget = 'checkbox';        break }
                '^(switch|switchparameter)$'               { $spec.widget = 'checkbox-switch'; break }
                '^datetime$'                               { $spec.widget = 'datetime-local';  break }
                '^guid$'                                   {
                    $spec.widget = 'textbox'
                    if ([string]::IsNullOrEmpty($spec.pattern)) {
                        $spec.pattern = '^[0-9a-fA-F-]{36}$'
                    }
                    break
                }
                '^uri$'                                    { $spec.widget = 'url';             break }
                '^(securestring|pscredential)$'            {
                    $spec.widget = 'password'
                    $note = 'Sent over loopback as plain string. Not stored.'
                    if ([string]::IsNullOrEmpty($spec.help)) { $spec.help = $note }
                    break
                }
                '^(string\[\]|int\[\]|object\[\]|double\[\]|bool\[\]|switch\[\])$' {
                    $spec.widget = 'textarea-multi'; break
                }
                '^hashtable$'                              {
                    $spec.widget = 'textarea-multi'
                    $note = 'One key=value per line.'
                    if ([string]::IsNullOrEmpty($spec.help)) { $spec.help = $note }
                    break
                }
                '^(system\.io\.fileinfo|fileinfo)$'        { $spec.widget = 'file';            break }
                '^scriptblock$'                            {
                    $spec.widget = 'unsupported'
                    $note = 'ScriptBlock parameters not editable in typed mode.'
                    if ([string]::IsNullOrEmpty($spec.help)) { $spec.help = $note }
                    break
                }
                default                                    { $spec.widget = 'textbox' }
            }
        }
    }

    # Comment-based help fallback when no [Parameter(HelpMessage=...)] attribute set it.
    if ([string]::IsNullOrEmpty($spec.help) -and $CommentHelp) {
        $key = $spec.name.ToLowerInvariant()
        if ($CommentHelp.ContainsKey($key)) {
            $spec.help = $CommentHelp[$key]
        }
    }

    return $spec
}

function Get-ParamSchema {
    [OutputType([hashtable])]
    param([string]$ScriptPath)

    $ext = [System.IO.Path]::GetExtension($ScriptPath).ToLowerInvariant()
    if ($ext -eq '.exe') {
        return @{ mode = 'raw'; schemaMode = 'raw'; fields = @(); kind = 'exe' }
    }
    if ($ext -ne '.ps1') {
        return @{ mode = 'raw'; schemaMode = 'raw'; fields = @(); kind = 'unknown' }
    }

    $parsed = Read-ScriptAst -Path $ScriptPath
    $ast    = $parsed.ast
    $errors = $parsed.errors
    if ($null -eq $ast) {
        return @{ mode = 'raw'; schemaMode = 'raw'; fields = @(); reason = 'parse-failed' }
    }
    if ($errors -and $errors.Count -gt 0) {
        # Surface the first parse error to the log so future "raw mode" mysteries are diagnosable.
        try { Write-HubError ("Parse error in {0} L{1}: {2}" -f $ScriptPath, $errors[0].Extent.StartLineNumber, $errors[0].Message) } catch { }
        return @{ mode = 'raw'; schemaMode = 'raw'; fields = @(); reason = 'parse-errors' }
    }

    $paramBlock = $ast.FindAll(
        { param($x) $x -is [System.Management.Automation.Language.ParamBlockAst] },
        $false) | Select-Object -First 1

    if (-not $paramBlock -or $paramBlock.Parameters.Count -eq 0) {
        return @{ mode = 'raw'; schemaMode = 'raw'; fields = @(); reason = 'no-param-block' }
    }

    $commentHelp = Get-ParamHelpFromComments -Ast $ast

    $fields = New-Object 'System.Collections.Generic.List[hashtable]'
    foreach ($p in $paramBlock.Parameters) {
        try {
            $fields.Add( (ConvertTo-WidgetSpec -ParamAst $p -CommentHelp $commentHelp) )
        } catch {
            Write-HubError $_
            # Skip this field; continue rest
        }
    }

    # schemaMode: 'typed' (no unsupported widgets), 'partial' (mix), 'raw' (required unsupported → caller falls back to raw).
    $schemaMode = 'typed'
    $hasUnsupported = $false
    $hasRequiredUnsupported = $false
    foreach ($f in $fields) {
        if ($f.widget -eq 'unsupported') {
            $hasUnsupported = $true
            if ($f.required) { $hasRequiredUnsupported = $true }
        }
    }
    if ($hasRequiredUnsupported) { $schemaMode = 'raw' }
    elseif ($hasUnsupported)     { $schemaMode = 'partial' }

    return @{ mode = 'typed'; schemaMode = $schemaMode; fields = @($fields) }
}

function Get-ParamPreview {
    # Slim per-card preview derived from an already-parsed AST.
    # Returns $null when no ParamBlockAst. Otherwise a hashtable with count / requiredCount / typeTags / parameterSets.
    [OutputType([object])]
    param([System.Management.Automation.Language.ScriptBlockAst]$Ast)

    if ($null -eq $Ast) { return $null }

    $paramBlock = $Ast.FindAll(
        { param($x) $x -is [System.Management.Automation.Language.ParamBlockAst] },
        $false) | Select-Object -First 1
    if (-not $paramBlock) { return $null }

    $params = @($paramBlock.Parameters)
    if ($params.Count -eq 0) {
        return @{ count = 0; requiredCount = 0; typeTags = @(); parameterSets = 0 }
    }

    # Build a quick lookup of (name → widget) by running each through ConvertTo-WidgetSpec.
    # This is the canonical mapping and stays in sync with the schema endpoint automatically.
    $tagFromWidget = @{
        'textbox'          = 'string'
        'number'           = 'number'
        'checkbox'         = 'bool'
        'checkbox-switch'  = 'switch'
        'dropdown'         = 'dropdown'
        'textarea-multi'   = 'multi'
        'file'             = 'file'
        'password'         = 'password'
        'datetime-local'   = 'datetime'
        'url'              = 'url'
        'unsupported'      = 'unsupported'
    }

    $count = $params.Count
    $requiredCount = 0
    $sets = New-Object 'System.Collections.Generic.HashSet[string]'
    $tagFreq = @{}
    $requiredTags = New-Object 'System.Collections.Generic.HashSet[string]'

    foreach ($p in $params) {
        try {
            $spec = ConvertTo-WidgetSpec -ParamAst $p
            if ($spec.required) { $requiredCount++ }
            if ($spec.parameterSet -and $spec.parameterSet -ne '__AllParameterSets') {
                [void]$sets.Add($spec.parameterSet)
            }
            # Tag derivation — prefer hashtable / guid special-cases when type matches, else widget map.
            $tag = $null
            if ($spec.type -eq 'hashtable')                  { $tag = 'hashtable' }
            elseif ($spec.type -eq 'guid')                   { $tag = 'guid' }
            elseif ($tagFromWidget.ContainsKey($spec.widget)) { $tag = $tagFromWidget[$spec.widget] }
            else                                              { $tag = 'other' }
            if (-not $tagFreq.ContainsKey($tag)) { $tagFreq[$tag] = 0 }
            $tagFreq[$tag]++
            if ($spec.required) { [void]$requiredTags.Add($tag) }
        } catch {
            Write-HubError $_
        }
    }

    # Build ordered tag list: required-first, then by frequency desc, then alpha. Slice top 4.
    $allTags = @($tagFreq.Keys)
    $sorted = $allTags | Sort-Object @{
        Expression = {
            $isReq = if ($requiredTags.Contains($_)) { 0 } else { 1 }
            "$isReq|$([int]::MaxValue - $tagFreq[$_])|$_"
        }
    }
    $top4 = @($sorted | Select-Object -First 4)

    return @{
        count          = $count
        requiredCount  = $requiredCount
        typeTags       = $top4
        parameterSets  = $sets.Count
    }
}

function Get-ItemMetadata {
    # Single-pass AST: returns @{ description; paramPreview; schemaMode } for a .ps1
    # or .exe item. cloudOnly items skip parse entirely.
    [OutputType([hashtable])]
    param([string]$Path, [string]$Kind, [bool]$CloudOnly)

    $out = @{
        description  = ''
        paramPreview = $null
        schemaMode   = 'raw'
    }

    if ($CloudOnly) { return $out }

    if ($Kind -eq 'exe') {
        $out.description = Get-ItemDescription -Path $Path -Kind 'exe'
        return $out
    }
    if ($Kind -ne 'ps1') { return $out }

    $parsed = Read-ScriptAst -Path $Path
    $ast    = $parsed.ast
    $errors = $parsed.errors
    if ($null -eq $ast) { return $out }

    # Description — synopsis from comment-based help.
    try {
        $help = $ast.GetHelpContent()
        if ($help -and $help.Synopsis) {
            $line = ($help.Synopsis -replace '\s+', ' ').Trim()
            if ($line.Length -gt 280) { $line = $line.Substring(0, 277) + '…' }
            $out.description = $line
        }
    } catch {
        Write-HubError $_
    }

    if ($errors -and $errors.Count -gt 0) {
        # Parse errors — description may still be useful; preview/schemaMode stay 'raw'.
        try { Write-HubError ("Parse error in {0} L{1}: {2}" -f $Path, $errors[0].Extent.StartLineNumber, $errors[0].Message) } catch { }
        return $out
    }

    # paramPreview + schemaMode (typed/partial/raw) from the same AST.
    try {
        $preview = Get-ParamPreview -Ast $ast
        $out.paramPreview = $preview
        if ($null -eq $preview -or $preview.count -eq 0) {
            $out.schemaMode = 'raw'
        } else {
            # Walk fields once to decide typed/partial/raw via unsupported widget detection.
            $paramBlock = $ast.FindAll(
                { param($x) $x -is [System.Management.Automation.Language.ParamBlockAst] },
                $false) | Select-Object -First 1
            $hasUnsupported = $false
            $hasRequiredUnsupported = $false
            $commentHelp = Get-ParamHelpFromComments -Ast $ast
            foreach ($p in $paramBlock.Parameters) {
                try {
                    $spec = ConvertTo-WidgetSpec -ParamAst $p -CommentHelp $commentHelp
                    if ($spec.widget -eq 'unsupported') {
                        $hasUnsupported = $true
                        if ($spec.required) { $hasRequiredUnsupported = $true }
                    }
                } catch { Write-HubError $_ }
            }
            if ($hasRequiredUnsupported) { $out.schemaMode = 'raw' }
            elseif ($hasUnsupported)     { $out.schemaMode = 'partial' }
            else                          { $out.schemaMode = 'typed' }
        }
    } catch {
        Write-HubError $_
    }

    return $out
}

function Invoke-SchemaRoute {
    param([System.Net.HttpListenerContext]$Context, [string]$ItemId)
    if ($Context.Request.HttpMethod -ne 'GET') {
        Write-JsonResponse -Context $Context -Status 405 -Body @{ error = 'method-not-allowed' }
        return
    }
    try {
        $catalog = Get-HubItems
        $item = $catalog.items | Where-Object { $_.id -eq $ItemId } | Select-Object -First 1
        if (-not $item) {
            Write-JsonResponse -Context $Context -Status 404 -Body @{ error = 'not-found' }
            return
        }
        # Defence in depth — re-confirm path is under a configured scan root.
        $resolved = [System.IO.Path]::GetFullPath($item.path)
        $underRoot = $false
        foreach ($r in (Get-EffectiveScanRoots)) {
            $rNorm = [System.IO.Path]::GetFullPath($r)
            if ($resolved.StartsWith($rNorm, [System.StringComparison]::OrdinalIgnoreCase)) {
                $underRoot = $true
                break
            }
        }
        if (-not $underRoot) {
            Write-JsonResponse -Context $Context -Status 404 -Body @{ error = 'not-found' }
            return
        }
        $schema = Get-ParamSchema -ScriptPath $resolved
        $schema.scriptPath = $resolved
        $schema.itemId     = $ItemId
        Write-JsonResponse -Context $Context -Status 200 -Body $schema
    } catch {
        Write-HubError $_
        Write-JsonResponse -Context $Context -Status 500 -Body @{ error = 'schema-failed' }
    }
}

function Invoke-HealthRoute {
    param([System.Net.HttpListenerContext]$Context)
    $jobsCount = 0
    if ($null -ne $Script:Jobs) { try { $jobsCount = $Script:Jobs.Count } catch { } }
    $status = if ($Script:ListenerHealthy) { 'ok' } else { 'degraded' }
    $code   = if ($Script:ListenerHealthy) { 200 } else { 503 }
    Write-JsonResponse -Context $Context -Status $code -Body @{
        status          = $status
        listenerHealthy = $Script:ListenerHealthy
        port            = $Script:Port
        jobs            = $jobsCount
        version         = $Script:Version
    }
}

function New-JobId {
    [OutputType([string])]
    param()
    $guid = [guid]::NewGuid().ToByteArray()
    return -join ($guid[0..7] | ForEach-Object { $_.ToString('x2') })
}

function Split-RawArgs {
    [OutputType([string[]])]
    param([string]$RawArgs)
    if ([string]::IsNullOrWhiteSpace($RawArgs)) { return @() }
    $errors = $null
    try {
        $tokens = [System.Management.Automation.PSParser]::Tokenize($RawArgs, [ref]$errors)
    } catch {
        return @($RawArgs -split '\s+' | Where-Object { $_ })
    }
    $allowed = @('Command','CommandArgument','String','Number','CommandParameter','Identifier','Variable')
    $result = New-Object 'System.Collections.Generic.List[string]'
    foreach ($t in $tokens) {
        if ($allowed -contains "$($t.Type)") {
            [void]$result.Add($t.Content)
        }
    }
    return $result.ToArray()
}

function Build-Argv {
    [OutputType([string[]])]
    param(
        [hashtable]$Schema,
        [hashtable]$Values = @{},
        [string]$RawArgs = $null
    )

    if (-not $Schema -or $Schema.mode -eq 'raw') {
        return ,(Split-RawArgs -RawArgs $RawArgs)
    }

    $argv = New-Object 'System.Collections.Generic.List[string]'
    foreach ($f in @($Schema.fields)) {
        $name = $f.name
        $val = $null
        if ($Values.ContainsKey($name)) { $val = $Values[$name] }

        # Required check
        $missing = ($null -eq $val) -or ("$val".Trim() -eq '')
        if ($f.required -and $missing) {
            throw [System.ArgumentException]::new("Required field missing: $name")
        }

        # Skip non-required empty values
        if ($missing) { continue }

        # ValidateSet server-side re-validation (ADV-004)
        if ($f.widget -eq 'dropdown' -and $f.options) {
            $opts = @($f.options) | ForEach-Object { "$_" }
            if ($opts -notcontains "$val") {
                throw [System.ArgumentException]::new("ValidateSet rejection: $name='$val'")
            }
        }

        switch ($f.widget) {
            'checkbox-switch' {
                # [switch] — only emit flag if truthy; absence == false
                if ($val -and "$val" -ne 'False' -and "$val" -ne '0') {
                    [void]$argv.Add('-' + $name)
                }
                break
            }
            'checkbox' {
                # [bool] — emit -Name <True|False>
                $bv = if ($val -and "$val" -ne 'False' -and "$val" -ne '0') { 'True' } else { 'False' }
                [void]$argv.Add('-' + $name)
                [void]$argv.Add($bv)
                break
            }
            'number' {
                [void]$argv.Add('-' + $name)
                [void]$argv.Add("$val")
                break
            }
            'textarea-multi' {
                $lines = "$val" -split "(`r`n|`r|`n)" |
                    ForEach-Object { $_.Trim() } |
                    Where-Object { $_ -and ($_ -notmatch '^[\r\n]+$') }
                foreach ($v in $lines) {
                    [void]$argv.Add('-' + $name)
                    [void]$argv.Add($v)
                }
                break
            }
            default {
                # textbox / dropdown / file
                [void]$argv.Add('-' + $name)
                [void]$argv.Add("$val")
            }
        }
    }
    return ,$argv.ToArray()
}

function New-JobRecord {
    [OutputType([hashtable])]
    param(
        [string]$JobId,
        [string]$ItemId,
        [System.Diagnostics.Process]$Process
    )
    return @{
        id            = $JobId
        itemId        = $ItemId
        pid           = $Process.Id
        process       = $Process
        buffer        = New-Object 'System.Collections.Generic.List[hashtable]'
        bufferTrimmed = $false
        subscribers   = New-Object 'System.Collections.Generic.List[hashtable]'
        status        = 'running'
        startedAt     = (Get-Date)
        endedAt       = $null
        exitCode      = $null
        stdoutTask    = $null
        stderrTask    = $null
        stdoutEof     = $false
        stderrEof     = $false
        workflowRunId = $null
    }
}

function ConvertTo-CmdLineArg {
    # Win32 CommandLineToArgvW escaping. Used because ProcessStartInfo.ArgumentList
    # is .NET Core only — PS2EXE-compiled Hub.exe runs on .NET Framework where only
    # the single Arguments string exists. This produces a quoted argv-safe string.
    [OutputType([string])]
    param([string]$Arg)
    if ($null -eq $Arg) { return '""' }
    if ($Arg -eq '')    { return '""' }
    if ($Arg -notmatch '[\s"]') { return $Arg }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $i = 0
    $len = $Arg.Length
    while ($i -lt $len) {
        $bs = 0
        while ($i -lt $len -and $Arg[$i] -eq '\') { $bs++; $i++ }
        if ($i -eq $len) {
            [void]$sb.Append('\' * ($bs * 2))
            break
        }
        if ($Arg[$i] -eq '"') {
            [void]$sb.Append('\' * ($bs * 2 + 1))
            [void]$sb.Append('"')
        } else {
            [void]$sb.Append('\' * $bs)
            [void]$sb.Append($Arg[$i])
        }
        $i++
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function Join-CmdLineArgs {
    [OutputType([string])]
    param([string[]]$ArgArray)
    if (-not $ArgArray -or $ArgArray.Count -eq 0) { return '' }
    $parts = foreach ($a in $ArgArray) { ConvertTo-CmdLineArg $a }
    return ($parts -join ' ')
}

function Start-HubJob {
    [OutputType([string])]
    param(
        [string]$ItemPath,
        [string]$Kind,
        [string[]]$Argv = @(),
        [string]$ItemId,
        [string]$WorkflowRunId = $null
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $argList = New-Object 'System.Collections.Generic.List[string]'
    if ($Kind -eq 'ps1') {
        $psi.FileName = 'pwsh'
        # -NonInteractive prevents Read-Host hangs (ADV-006).
        # -NoProfile + Bypass for predictability.
        $argList.Add('-NoProfile')
        $argList.Add('-NonInteractive')
        $argList.Add('-ExecutionPolicy')
        $argList.Add('Bypass')
        $argList.Add('-File')
        $argList.Add($ItemPath)
        foreach ($a in $Argv) { $argList.Add([string]$a) }
    } else {
        $psi.FileName = $ItemPath
        foreach ($a in $Argv) { $argList.Add([string]$a) }
    }
    # NOTE: Use Arguments (single string) not ArgumentList (.NET Core only).
    # Build via Win32 escaping helper so spaces / quotes in user inputs are safe.
    $psi.Arguments = Join-CmdLineArgs -ArgArray $argList.ToArray()
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.RedirectStandardInput  = $true
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding  = [System.Text.Encoding]::UTF8

    $jobId = New-JobId
    $proc = $null

    # Setup order with explicit try-catch (ADV-005):
    # (1) Start process; (2) close stdin (EOF); (3) build job record; (4) register.
    # ANY throw after (1) → Kill, NO registration, rethrow.
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
        try { $proc.StandardInput.Close() } catch { Write-HubError $_ }
        $job = New-JobRecord -JobId $jobId -ItemId $ItemId -Process $proc
        if ($WorkflowRunId) { $job.workflowRunId = $WorkflowRunId }
        $Script:Jobs[$jobId] = $job
        return $jobId
    } catch {
        if ($proc) {
            try { if (-not $proc.HasExited) { $proc.Kill($true) } } catch { }
            try { $proc.Dispose() } catch { }
        }
        # Ensure no stale registration if we crashed mid-build
        if ($Script:Jobs.ContainsKey($jobId)) { $Script:Jobs.Remove($jobId) }
        throw
    }
}

function Add-JobBufferLine {
    param(
        [hashtable]$Job,
        [string]$Stream,   # 'out' | 'err' | 'sys'
        [string]$Line
    )
    # Per-line cap (ADV-010) — 4 KB hard limit with explicit marker.
    if ($Line.Length -gt $Script:JobLineByteCap) {
        $Line = $Line.Substring(0, $Script:JobLineByteCap - 18) + ' [...truncated]'
    }
    $entry = @{ stream = $Stream; line = $Line; ts = (Get-Date).ToString('o') }
    [void]$Job.buffer.Add($entry)

    # Total buffer cap.
    if ($Job.buffer.Count -gt $Script:JobBufferLineCap) {
        $Job.buffer.RemoveAt(0)
        if (-not $Job.bufferTrimmed) {
            $Job.buffer.Insert(0, @{ stream = 'sys'; line = '[buffer trimmed]'; ts = $entry.ts })
            $Job.bufferTrimmed = $true
        }
    }

    Send-JobLineToSubscribers -Job $Job -Entry $entry
}

function ConvertTo-SsePayload {
    [OutputType([byte[]])]
    param([string]$EventName, $Data)
    $json = $Data | ConvertTo-Json -Depth 6 -Compress
    $payload = "event: $EventName`ndata: $json`n`n"
    return [System.Text.Encoding]::UTF8.GetBytes($payload)
}

function Send-JobLineToSubscribers {
    param([hashtable]$Job, [hashtable]$Entry)
    if ($Job.subscribers.Count -eq 0) { return }
    $bytes = ConvertTo-SsePayload -EventName 'line' -Data $Entry
    $dead = New-Object 'System.Collections.Generic.List[hashtable]'
    foreach ($sub in @($Job.subscribers)) {
        try {
            $sub.stream.Write($bytes, 0, $bytes.Length)
            $sub.stream.Flush()
        } catch {
            [void]$dead.Add($sub)
        }
    }
    foreach ($d in $dead) {
        [void]$Job.subscribers.Remove($d)
        try { $d.context.Response.Close() } catch { }
    }
}

function Send-JobEnd {
    param([hashtable]$Job)
    if ($Job.subscribers.Count -eq 0) { return }
    $bytes = ConvertTo-SsePayload -EventName 'end' -Data @{
        exitCode = $Job.exitCode
        status   = $Job.status
        endedAt  = if ($Job.endedAt) { $Job.endedAt.ToString('o') } else { $null }
    }
    foreach ($sub in @($Job.subscribers)) {
        try {
            $sub.stream.Write($bytes, 0, $bytes.Length)
            $sub.stream.Flush()
        } catch { }
        try { $sub.context.Response.OutputStream.Close() } catch { }
        try { $sub.context.Response.Close() } catch { }
    }
    $Job.subscribers.Clear()
}

function Read-JobStreamPipe {
    param([hashtable]$Job, [string]$Stream)
    $reader  = if ($Stream -eq 'out') { $Job.process.StandardOutput } else { $Job.process.StandardError }
    $taskKey = if ($Stream -eq 'out') { 'stdoutTask' } else { 'stderrTask' }
    $eofKey  = if ($Stream -eq 'out') { 'stdoutEof' } else { 'stderrEof' }
    if ($Job.$eofKey) { return }
    while ($true) {
        if ($null -eq $Job.$taskKey) {
            try {
                $Job.$taskKey = $reader.ReadLineAsync()
            } catch {
                $Job.$eofKey = $true
                return
            }
        }
        if (-not $Job.$taskKey.IsCompleted) { return }
        $line = $null
        try {
            $line = $Job.$taskKey.GetAwaiter().GetResult()
        } catch {
            $Job.$eofKey = $true
            $Job.$taskKey = $null
            return
        }
        $Job.$taskKey = $null
        if ($null -eq $line) {
            $Job.$eofKey = $true
            return
        }
        Add-JobBufferLine -Job $Job -Stream $Stream -Line $line
    }
}

function Step-Jobs {
    if ($null -eq $Script:Jobs -or $Script:Jobs.Count -eq 0) {
        # Still sweep occasionally even when empty.
        $now = Get-Date
        if (($now - $Script:LastSweepAt).TotalSeconds -ge $Script:SweepIntervalSeconds) {
            $Script:LastSweepAt = $now
        }
        return
    }
    foreach ($id in @($Script:Jobs.Keys)) {
        $job = $Script:Jobs[$id]
        if ($null -eq $job) { continue }
        if ($job.status -in @('done','failed','killed')) { continue }

        Read-JobStreamPipe -Job $job -Stream 'out'
        Read-JobStreamPipe -Job $job -Stream 'err'

        if ($job.process.HasExited -and $job.stdoutEof -and $job.stderrEof) {
            $job.exitCode = $job.process.ExitCode
            if ($job.status -eq 'running') {
                $job.status = if ($job.exitCode -eq 0) { 'done' } else { 'failed' }
            }
            $job.endedAt = Get-Date
            Send-JobEnd -Job $job
            Write-HubHistory -Job $job -WorkflowRunId $job.workflowRunId
            try { $job.process.Dispose() } catch { }
        }
    }

    Advance-WorkflowRuns
    Advance-TriggerSchedules

    $now = Get-Date
    if (($now - $Script:LastSweepAt).TotalSeconds -ge $Script:SweepIntervalSeconds) {
        Invoke-JobSweep
        $Script:LastSweepAt = $now
    }
}

function Invoke-JobSweep {
    if ($null -eq $Script:Jobs) { return }
    $now = Get-Date
    $cutoff = $now.AddMinutes(-$Script:JobTtlMinutes)
    $toRemove = New-Object 'System.Collections.Generic.List[string]'
    foreach ($id in @($Script:Jobs.Keys)) {
        $job = $Script:Jobs[$id]
        if ($null -eq $job) { continue }
        if ($job.status -eq 'running') { continue }
        if ($job.subscribers.Count -gt 0) { continue }
        if ($null -ne $job.endedAt -and $job.endedAt -lt $cutoff) {
            [void]$toRemove.Add($id)
        }
    }
    foreach ($id in $toRemove) {
        $j = $Script:Jobs[$id]
        try { if ($j -and $j.process) { $j.process.Dispose() } } catch { }
        $Script:Jobs.Remove($id)
    }
    # LRU cap
    if ($Script:Jobs.Count -gt $Script:JobLruCap) {
        $terminal = @($Script:Jobs.Values | Where-Object { $_.status -in @('done','failed','killed') -and $_.subscribers.Count -eq 0 -and -not $_.workflowRunId }) |
            Sort-Object endedAt
        $excess = $Script:Jobs.Count - $Script:JobLruCap
        for ($i = 0; $i -lt $excess -and $i -lt $terminal.Count; $i++) {
            $j = $terminal[$i]
            try { $j.process.Dispose() } catch { }
            $Script:Jobs.Remove($j.id)
        }
    }
}

function Stop-JobTree {
    [OutputType([bool])]
    param([int]$ProcessId)
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'taskkill.exe'
        [void]$psi.ArgumentList.Add('/T')
        [void]$psi.ArgumentList.Add('/F')
        [void]$psi.ArgumentList.Add('/PID')
        [void]$psi.ArgumentList.Add("$ProcessId")
        $psi.UseShellExecute        = $false
        $psi.CreateNoWindow         = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        [void]$p.WaitForExit(5000)
        return ($p.ExitCode -eq 0)
    } catch {
        Write-HubError $_
        return $false
    }
}

function Invoke-RunRoute {
    param([System.Net.HttpListenerContext]$Context)
    if ($Context.Request.HttpMethod -ne 'POST') {
        Write-JsonResponse -Context $Context -Status 405 -Body @{ error = 'method-not-allowed' }
        return
    }
    # Parse JSON body
    $body = $null
    try {
        $reader = New-Object System.IO.StreamReader($Context.Request.InputStream, [System.Text.Encoding]::UTF8)
        $text = $reader.ReadToEnd()
        $body = $text | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-JsonResponse -Context $Context -Status 400 -Body @{ error = 'bad-json' }
        return
    }
    $itemIdProp = if ($null -ne $body) { $body.PSObject.Properties['itemId'] } else { $null }
    if (-not $itemIdProp -or -not $itemIdProp.Value) {
        Write-JsonResponse -Context $Context -Status 400 -Body @{ error = 'itemId-required' }
        return
    }
    $itemIdValue = "$($itemIdProp.Value)"

    # Resolve item + re-validate scan root
    $catalog = Get-HubItems
    $item = $catalog.items | Where-Object { $_.id -eq $itemIdValue } | Select-Object -First 1
    if (-not $item) {
        Write-JsonResponse -Context $Context -Status 404 -Body @{ error = 'unknown-item' }
        return
    }
    $resolved = [System.IO.Path]::GetFullPath($item.path)
    $underRoot = $false
    foreach ($r in (Get-EffectiveScanRoots)) {
        $rNorm = [System.IO.Path]::GetFullPath($r)
        if ($resolved.StartsWith($rNorm, [System.StringComparison]::OrdinalIgnoreCase)) { $underRoot = $true; break }
    }
    if (-not $underRoot) {
        Write-JsonResponse -Context $Context -Status 404 -Body @{ error = 'unknown-item' }
        return
    }

    # Build argv from typed values OR raw args
    $schema = Get-ParamSchema -ScriptPath $resolved
    $values = @{}
    $valuesProp = $body.PSObject.Properties['values']
    if ($valuesProp -and $valuesProp.Value) {
        foreach ($p in $valuesProp.Value.PSObject.Properties) { $values[$p.Name] = $p.Value }
    }
    $rawArgs = $null
    $rawProp = $body.PSObject.Properties['rawArgs']
    if ($rawProp -and $rawProp.Value) { $rawArgs = [string]$rawProp.Value }

    try {
        $argv = Build-Argv -Schema $schema -Values $values -RawArgs $rawArgs
    } catch [System.ArgumentException] {
        Write-JsonResponse -Context $Context -Status 400 -Body @{ error = $_.Exception.Message }
        return
    } catch {
        Write-HubError $_
        Write-JsonResponse -Context $Context -Status 400 -Body @{ error = 'argv-failed' }
        return
    }

    try {
        $jobId = Start-HubJob -ItemPath $resolved -Kind $item.kind -Argv $argv -ItemId $item.id
    } catch [System.ComponentModel.Win32Exception] {
        Write-HubError $_
        Write-JsonResponse -Context $Context -Status 500 -Body @{ error = 'spawn-failed'; detail = $_.Exception.Message }
        return
    } catch {
        Write-HubError $_
        Write-JsonResponse -Context $Context -Status 500 -Body @{ error = 'spawn-failed' }
        return
    }

    Write-JsonResponse -Context $Context -Status 202 -Body @{ jobId = $jobId }
}

function Invoke-StreamRoute {
    [OutputType([bool])]
    param([System.Net.HttpListenerContext]$Context, [string]$JobId)
    if ($Context.Request.HttpMethod -ne 'GET') {
        Write-JsonResponse -Context $Context -Status 405 -Body @{ error = 'method-not-allowed' }
        return $true
    }
    $job = $Script:Jobs[$JobId]
    if (-not $job) {
        Write-JsonResponse -Context $Context -Status 404 -Body @{ error = 'unknown-job' }
        return $true
    }
    $resp = $Context.Response
    $resp.StatusCode      = 200
    $resp.ContentType     = 'text/event-stream; charset=utf-8'
    $resp.Headers['Cache-Control']     = 'no-cache'
    $resp.Headers['X-Accel-Buffering'] = 'no'
    $resp.SendChunked = $true

    $stream = $resp.OutputStream

    # Replay buffer
    foreach ($entry in @($job.buffer)) {
        try {
            $bytes = ConvertTo-SsePayload -EventName 'line' -Data $entry
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush()
        } catch {
            return $true
        }
    }

    # If terminal — send end frame, close
    if ($job.status -in @('done','failed','killed')) {
        try {
            $bytes = ConvertTo-SsePayload -EventName 'end' -Data @{
                exitCode = $job.exitCode
                status   = $job.status
                endedAt  = if ($job.endedAt) { $job.endedAt.ToString('o') } else { $null }
            }
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush()
        } catch { }
        return $true
    }

    # Register subscriber, keep response open
    [void]$job.subscribers.Add(@{ context = $Context; stream = $stream })
    return $false
}

function Invoke-KillRoute {
    param([System.Net.HttpListenerContext]$Context, [string]$JobId)
    if ($Context.Request.HttpMethod -ne 'POST') {
        Write-JsonResponse -Context $Context -Status 405 -Body @{ error = 'method-not-allowed' }
        return
    }
    $job = $Script:Jobs[$JobId]
    if (-not $job) {
        Write-JsonResponse -Context $Context -Status 404 -Body @{ error = 'unknown-job' }
        return
    }
    if ($job.status -ne 'running') {
        Write-JsonResponse -Context $Context -Status 200 -Body @{ status = $job.status; message = 'already-terminal' }
        return
    }
    [void](Stop-JobTree -ProcessId $job.pid)
    $job.status = 'killed'
    $job.endedAt = Get-Date
    # Process exit + EOF flush detected by Step-Jobs on next pump iteration, which fires Send-JobEnd.
    $Context.Response.StatusCode = 204
}

function Invoke-ConfigRoute {
    # GET /api/config — read-only, NOT a state route, NO CSRF required.
    # Returns persisted-only scanRoots per K23 (excludes $ExtraScanRoots test paths).
    param([System.Net.HttpListenerContext]$Context)
    if ($Context.Request.HttpMethod -ne 'GET') {
        Write-JsonResponse -Context $Context -Status 405 -Body @{ error = 'method-not-allowed' }
        return
    }
    Write-JsonResponse -Context $Context -Status 200 -Body @{
        scanRoots    = @($Script:Config.scanRoots)
        scanMaxDepth = $Script:Config.scanMaxDepth
        needsSetup   = $Script:NeedsSetup
        defaults     = (Get-DefaultScanRoots)
        maxScanRoots = $Script:MaxScanRoots
    }
}

function Invoke-SetupRoute {
    # POST /api/setup — state route (CSRF + Origin + Host + Content-Type middleware applies).
    # Body: { scanRoots: [string[]] }. K22 validation pipeline.
    param([System.Net.HttpListenerContext]$Context)
    if ($Context.Request.HttpMethod -ne 'POST') {
        Write-JsonResponse -Context $Context -Status 405 -Body @{ error = 'method-not-allowed' }
        return
    }
    try {
        $reader = New-Object System.IO.StreamReader($Context.Request.InputStream, [System.Text.Encoding]::UTF8)
        $raw = $reader.ReadToEnd()
        $reader.Dispose()
        $body = $raw | ConvertFrom-Json
    } catch {
        Write-JsonResponse -Context $Context -Status 400 -Body @{ error = 'bad-json' }
        return
    }
    $rootsProp = $body.PSObject.Properties['scanRoots']
    if (-not $rootsProp -or $null -eq $rootsProp.Value) {
        Write-JsonResponse -Context $Context -Status 400 -Body @{ error = 'no-scan-roots' }
        return
    }
    $incoming = @($rootsProp.Value | ForEach-Object { [string]$_ } | Where-Object { $_ })
    if ($incoming.Count -eq 0) {
        Write-JsonResponse -Context $Context -Status 400 -Body @{ error = 'no-scan-roots' }
        return
    }
    if ($incoming.Count -gt $Script:MaxScanRoots) {
        Write-JsonResponse -Context $Context -Status 400 -Body @{ error = 'too-many-roots'; max = $Script:MaxScanRoots }
        return
    }
    # Validate each, then canonicalize, then dedup.
    $canonical = New-Object 'System.Collections.Generic.List[string]'
    foreach ($p in $incoming) {
        if (-not (Test-ValidScanRoot -Path $p)) {
            Write-JsonResponse -Context $Context -Status 400 -Body @{ error = 'invalid-path'; path = $p }
            return
        }
        $full = [System.IO.Path]::GetFullPath($p)
        $exists = $false
        foreach ($c in $canonical) {
            if ($c.Equals($full, [System.StringComparison]::OrdinalIgnoreCase)) { $exists = $true; break }
        }
        if (-not $exists) { [void]$canonical.Add($full) }
    }
    $gitRoots  = if ($Script:Config -and $Script:Config.ContainsKey('gitRoots')) { $Script:Config['gitRoots'] } else { @() }
    $newConfig = @{
        version      = $Script:ConfigVersion
        scanRoots    = @($canonical)
        scanMaxDepth = $Script:ScanMaxDepth
        gitRoots     = $gitRoots
    }
    try {
        Write-HubConfig -Config $newConfig
    } catch {
        Write-HubError $_
        Write-JsonResponse -Context $Context -Status 500 -Body @{ error = 'config-write-failed' }
        return
    }
    # On success: update in-memory state, clear NeedsSetup.
    $Script:Config = $newConfig
    $Script:NeedsSetup = $false
    Write-JsonResponse -Context $Context -Status 200 -Body @{ ok = $true; scanRoots = @($canonical) }
}

function Invoke-BrowseFolderRoute {
    # POST /api/browse-folder — state route. Opens native FolderBrowserDialog (STA main thread).
    # Rate-limited to one call per 2 seconds (ADV-M6).
    param([System.Net.HttpListenerContext]$Context)
    if ($Context.Request.HttpMethod -ne 'POST') {
        Write-JsonResponse -Context $Context -Status 405 -Body @{ error = 'method-not-allowed' }
        return
    }
    # ADV-M6 rate limit.
    $now = Get-Date
    if (($now - $Script:LastBrowseFolderAt).TotalMilliseconds -lt 2000) {
        Write-JsonResponse -Context $Context -Status 429 -Body @{ error = 'rate-limited'; retryAfter = 2 }
        return
    }
    $Script:LastBrowseFolderAt = $now

    $dialog = $null
    $owner  = $null
    try {
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        # NOTE: UseDescriptionForTitle is .NET 5+ — PS2EXE-compiled Hub.exe targets .NET Framework
        # so we keep to properties available in 4.x. Description shows in the dialog body.
        $dialog.Description         = 'Select a folder for Hub to scan'
        $dialog.ShowNewFolderButton = $true
        if (Test-Path -LiteralPath $env:USERPROFILE) {
            $dialog.SelectedPath = $env:USERPROFILE
        }

        # ShowDialog without an owner can land behind the browser window. Create an
        # invisible TopMost off-screen Form so the dialog inherits foreground z-order.
        $owner = New-Object System.Windows.Forms.Form
        $owner.FormBorderStyle = 'FixedToolWindow'
        $owner.ShowInTaskbar   = $false
        $owner.StartPosition   = 'Manual'
        $owner.Location        = New-Object System.Drawing.Point(-32000, -32000)
        $owner.Size            = New-Object System.Drawing.Size(1, 1)
        $owner.TopMost         = $true
        $owner.Show()
        [System.Windows.Forms.Application]::DoEvents()

        # ShowDialog blocks the listener pump until the user clicks OK or Cancel.
        # That's acceptable here: setup is interactive. The /api/browse-folder rate-limit
        # ($Script:LastBrowseFolderAt, 2s) prevents the frontend from queueing more dialogs.
        $result = $dialog.ShowDialog($owner)
        if ($result -ne [System.Windows.Forms.DialogResult]::OK) {
            Write-JsonResponse -Context $Context -Status 200 -Body @{ path = ''; cancelled = $true }
            return
        }
        Write-JsonResponse -Context $Context -Status 200 -Body @{ path = $dialog.SelectedPath; cancelled = $false }
    } catch {
        Write-HubError $_
        Write-JsonResponse -Context $Context -Status 500 -Body @{ error = 'browse-failed' }
    } finally {
        if ($dialog) { try { $dialog.Dispose() } catch { } }
        if ($owner)  { try { $owner.Close(); $owner.Dispose() } catch { } }
    }
}

function Invoke-Route {
    [OutputType([bool])]
    param([System.Net.HttpListenerContext]$Context)
    $path = $Context.Request.Url.AbsolutePath
    try {
        if ($path -eq '/api/health')  { Invoke-HealthRoute  -Context $Context; return $true }
        if ($path -eq '/api/version') { Write-JsonResponse  -Context $Context -Status 200 -Body @{ version = $Script:Version }; return $true }
        if ($path -eq '/api/config') { Invoke-ConfigRoute -Context $Context; return $true }
        if ($path -eq '/api/setup')  { Invoke-SetupRoute  -Context $Context; return $true }
        if ($path -eq '/api/browse-folder') { Invoke-BrowseFolderRoute -Context $Context; return $true }
        if ($path -eq '/api/items')  { Invoke-ItemsRoute  -Context $Context; return $true }
        if ($path -match '^/api/items/([0-9a-f]{12})/schema$') {
            Invoke-SchemaRoute -Context $Context -ItemId $matches[1]
            return $true
        }
        if ($path -eq '/api/run') { Invoke-RunRoute -Context $Context; return $true }
        if ($path -match '^/api/stream/([0-9a-f]{16})$') {
            return (Invoke-StreamRoute -Context $Context -JobId $matches[1])
        }
        if ($path -match '^/api/jobs/([0-9a-f]{16})/kill$') {
            Invoke-KillRoute -Context $Context -JobId $matches[1]
            return $true
        }
        if ($path -eq '/api/workflows') {
            Invoke-WorkflowsRoute -Context $Context; return $true
        }
        if ($path -match '^/api/workflows/([^/]+)$') {
            Invoke-WorkflowByIdRoute -Context $Context -WorkflowId $matches[1]; return $true
        }
        if ($path -match '^/api/workflows/([^/]+)/run$') {
            Invoke-WorkflowRunTriggerRoute -Context $Context -WorkflowId $matches[1]; return $true
        }
        if ($path -match '^/api/workflow-runs/([^/]+)/stream$') {
            return (Invoke-WorkflowRunStreamRoute -Context $Context -RunId $matches[1])
        }
        if ($path -match '^/api/workflow-runs/([^/]+)/kill$') {
            Invoke-WorkflowRunKillRoute -Context $Context -RunId $matches[1]; return $true
        }
        if ($path -match '^/api/workflow-runs/([^/]+)$') {
            return (Invoke-WorkflowRunRoute -Context $Context -RunId $matches[1])
        }
        if ($path -eq '/api/git-roots') {
            Invoke-GitRootsRoute -Context $Context; return $true
        }
        if ($path -eq '/api/history') {
            Invoke-HistoryRoute -Context $Context; return $true
        }
        if ($path -like '/api/*') {
            Write-JsonResponse -Context $Context -Status 503 -Body @{ error = 'not-yet-implemented'; path = $path }
            return $true
        }
        Invoke-StaticFileRoute -Context $Context -WwwRoot $Script:WwwRoot
        return $true
    } catch {
        Write-HubError $_
        try { Write-JsonResponse -Context $Context -Status 500 -Body @{ error = 'internal' } } catch { }
        return $true
    }
}

function Start-HubListener {
    [OutputType([System.Net.HttpListener])]
    param([int]$Port = 8765)
    $listener = [System.Net.HttpListener]::new()
    $listener.Prefixes.Add("http://127.0.0.1:$Port/")
    $listener.Start()
    return $listener
}

function Test-UrlAcl {
    [OutputType([bool])]
    param([int]$Port = 8765)
    try {
        $out = & netsh http show urlacl url=("http://127.0.0.1:$Port/") 2>&1 | Out-String
    } catch { return $false }
    return ($out -match 'Reserved URL')
}

function Get-UrlAclRegisterCommand {
    [OutputType([string])]
    param([int]$Port)
    $user = "$env:USERDOMAIN\$env:USERNAME"
    return "netsh http add urlacl url=`"http://127.0.0.1:$Port/`" user=`"$user`""
}

function Initialize-HubPort {
    [OutputType([hashtable])]
    param([int]$Preferred = 8765)

    # Read prev-run hint, sanity-check.
    $hint = 0
    $portFile = Join-Path $env:TEMP 'hub.port'
    if (Test-Path -LiteralPath $portFile) {
        try {
            $raw = (Get-Content -LiteralPath $portFile -Raw -ErrorAction Stop).Trim()
            $parsed = 0
            if ([int]::TryParse($raw, [ref]$parsed) -and $parsed -ge 1024 -and $parsed -le 65535) {
                $hint = $parsed
            }
        } catch { }
    }

    # Candidate order: hint (if different) → preferred → preferred+1..+10.
    $candidates = New-Object 'System.Collections.Generic.List[int]'
    if ($hint -gt 0 -and $hint -ne $Preferred) { [void]$candidates.Add($hint) }
    [void]$candidates.Add($Preferred)
    for ($p = $Preferred + 1; $p -le $Preferred + 10; $p++) {
        if (-not $candidates.Contains($p)) { [void]$candidates.Add($p) }
    }

    $lastError = $null
    foreach ($port in $candidates) {
        $listener = $null
        try {
            $listener = [System.Net.HttpListener]::new()
            $listener.Prefixes.Add("http://127.0.0.1:$port/")
            $listener.Start()
            return @{ listener = $listener; port = $port }
        } catch [System.Net.HttpListenerException] {
            $lastError = $_
            try { if ($listener) { $listener.Close() } } catch { }
            # ErrorCode 5 = ERROR_ACCESS_DENIED — URL-ACL missing for ALL ports under this user.
            # Bail out and surface guidance.
            if ($_.Exception.ErrorCode -eq 5) { throw }
            # ErrorCode 183 / 32 = ERROR_ALREADY_EXISTS / SHARING_VIOLATION — port busy.
            continue
        }
    }
    if ($lastError) { throw $lastError }
    throw "No port in range $Preferred..$($Preferred + 10) available."
}

function Invoke-RouterPump {
    # One pump iteration:
    #   1. Step jobs (drain stdout/stderr, send SSE frames, sweep terminal jobs).
    #   2. If an HTTP request is ready, dispatch it.
    # Reason for the polling structure: async callbacks fire on ThreadPool
    # threads with no PowerShell runspace (see PSInvalidOperationException
    # docs). Driving everything from the STA main thread keeps the runspace
    # available for every script-block invocation.
    Step-Jobs

    if ($null -eq $Script:PendingContext) {
        $Script:PendingContext = $Script:Listener.BeginGetContext($null, $null)
    }
    # Short wait so Step-Jobs runs ~50x/sec when idle. Keeps stdout drain
    # responsive without burning CPU.
    if (-not $Script:PendingContext.AsyncWaitHandle.WaitOne(20)) {
        return
    }
    $ctx = $null
    try {
        $ctx = $Script:Listener.EndGetContext($Script:PendingContext)
    } catch [System.Net.HttpListenerException] {
        $Script:Running = $false
        return
    } catch {
        Write-HubError $_
        return
    } finally {
        $Script:PendingContext = $null
    }

    $shouldClose = $true
    try {
        if (Invoke-SecurityMiddleware -Context $ctx -Port $Script:Port) {
            $rv = Invoke-Route -Context $ctx
            if ($null -ne $rv) { $shouldClose = [bool]$rv }
        }
    } catch {
        Write-HubError $_
        try { Write-JsonResponse -Context $ctx -Status 500 -Body @{ error = 'internal' } } catch { }
    } finally {
        if ($shouldClose) {
            try { $ctx.Response.OutputStream.Close() } catch { }
            try { $ctx.Response.Close() } catch { }
        }
    }
}

function Save-PortHint {
    param([int]$Port)
    try {
        Set-Content -LiteralPath (Join-Path $env:TEMP 'hub.port') -Value "$Port" -Encoding utf8 -NoNewline
    } catch { Write-HubError $_ }
}

function New-HubTray {
    [OutputType([System.Windows.Forms.NotifyIcon])]
    param([string]$Url)
    # Store URL in script scope so click-handler scriptblocks can read it
    # without relying on PS closure semantics for local function params.
    $Script:DashboardUrl = $Url
    $tray = New-Object System.Windows.Forms.NotifyIcon

    # Prefer Hub.ico (procedurally generated by build-icon.ps1) — fall back to
    # the system icon if missing (e.g., before first build).
    $iconPath = Join-Path $Script:ScriptRoot 'Hub.ico'
    if (Test-Path -LiteralPath $iconPath) {
        try {
            $tray.Icon = New-Object System.Drawing.Icon $iconPath
        } catch {
            Write-HubError $_
            $tray.Icon = [System.Drawing.SystemIcons]::Application
        }
    } else {
        $tray.Icon = [System.Drawing.SystemIcons]::Application
    }
    $tray.Visible = $true
    $tray.Text    = "Hub :$Script:Port"
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $openItem = $menu.Items.Add('Open dashboard')
    $openItem.Add_Click({ try { Start-Process $Script:DashboardUrl } catch { Write-HubError $_ } })
    [void]$menu.Items.Add('-')
    $quitItem = $menu.Items.Add('Quit')
    $quitItem.Add_Click({
        $Script:Running = $false
        try { if ($Script:Listener -and $Script:Listener.IsListening) { $Script:Listener.Stop() } } catch { Write-HubError $_ }
    })
    $tray.ContextMenuStrip = $menu
    return $tray
}

# === MAIN ENTRY ===

trap {
    Write-HubError $_
    try {
        [System.Windows.Forms.MessageBox]::Show(
            "Hub failed to start.`n`n$($_.Exception.Message)`n`nSee %TEMP%\hub-error.log for details.",
            'Hub - Fatal', 'OK', 'Error') | Out-Null
    } catch { }
    exit 1
}

if (-not (Test-SingleInstance)) {
    # Existing instance focused, exit cleanly.
    exit 0
}

# Load config (K12) — sets $Script:NeedsSetup if missing/malformed.
$Script:Config = Get-HubConfigOrDefault
# Auto-create the two DEFAULT scan roots only — never user-typed paths (ADV-C1).
if ($Script:NeedsSetup) {
    foreach ($defaultRoot in (Get-DefaultScanRoots)) {
        try {
            if (-not [System.IO.Directory]::Exists($defaultRoot)) {
                [System.IO.Directory]::CreateDirectory($defaultRoot) | Out-Null
            }
        } catch { Write-HubError $_ }
    }
}

# Load persisted workflows from disk.
Initialize-Workflows
Initialize-WorkflowRuns
Initialize-TriggerStates
Initialize-GitRoots
Initialize-History

try {
    $hubPort = Initialize-HubPort -Preferred $Script:Port
    $Script:Listener = $hubPort.listener
    $Script:Port     = $hubPort.port
} catch [System.Net.HttpListenerException] {
    Write-HubError $_
    $msg = "Cannot bind to http://127.0.0.1:$Script:Port/`n`n$($_.Exception.Message)"
    if ($_.Exception.ErrorCode -eq 5) {
        $cmd = Get-UrlAclRegisterCommand -Port $Script:Port
        $msg += "`n`nOne-time setup required. Open an ADMIN PowerShell window and run:`n`n  $cmd`n`nThen relaunch Hub."
    } else {
        $msg += "`n`nAll candidate ports ($Script:Port..$($Script:Port + 10)) are in use."
    }
    [System.Windows.Forms.MessageBox]::Show($msg, 'Hub - Listener error', 'OK', 'Error') | Out-Null
    exit 1
}

Save-PortHint -Port $Script:Port

$Script:Url            = "http://127.0.0.1:$Script:Port/"
$Script:PendingContext = $null
$Script:Tray           = New-HubTray -Url $Script:Url

try { Start-Process $Script:Url } catch { Write-HubError $_ }

# Main loop: poll listener AND pump WinForms messages on the same STA thread.
# Reason: BeginGetContext async callbacks run on ThreadPool threads that have
# no PS runspace, so we drive routing from this STA main thread where the
# runspace IS available.
while ($Script:Running -and $Script:Listener.IsListening) {
    Invoke-RouterPump
    [System.Windows.Forms.Application]::DoEvents()
}

# Cleanup
try { if ($Script:Listener.IsListening) { $Script:Listener.Stop() } } catch { }
try { $Script:Listener.Close() } catch { }
try { $Script:Tray.Visible = $false; $Script:Tray.Dispose() } catch { }
