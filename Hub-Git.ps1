# Hub-Git.ps1 — Git scan root clone/pull operations and gitRoots config (Phase 5).
# Dot-sourced by Hub.ps1 after all $Script: globals are set.
#
# gitRoots is stored separately from scanRoots in config (ADV2-005).
# Only https:// URLs accepted (ADV-004). Shallow clone (--depth 1).
# Clone dirs are added to $Script:GitScanRoots which Get-EffectiveScanRoots includes.

$Script:GitScanRoots = New-Object 'System.Collections.Generic.List[string]'
$Script:GitStatus    = [hashtable]::Synchronized(@{})  # urlHash → @{ url; synced; error; lastSync }

function Get-GitReposDir {
    [OutputType([string])]
    param()
    $d = Join-Path $Script:ConfigDir 'repos'
    if (-not [System.IO.Directory]::Exists($d)) {
        try { [System.IO.Directory]::CreateDirectory($d) | Out-Null } catch { Write-HubError $_ }
    }
    return $d
}

function Get-GitRootHash {
    [OutputType([string])]
    param([string]$Url)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Url.ToLowerInvariant())
    $hash  = [System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
    return ([System.BitConverter]::ToString($hash) -replace '-', '').Substring(0, 16).ToLowerInvariant()
}

function Get-GitRootLocalPath {
    [OutputType([string])]
    param([string]$Url)
    return Join-Path (Get-GitReposDir) (Get-GitRootHash -Url $Url)
}

function Test-ValidGitUrl {
    [OutputType([bool])]
    param([string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url)) { return $false }
    # Only https:// allowed (ADV-004).
    if (-not $Url.StartsWith('https://', [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
    try {
        $uri = [System.Uri]::new($Url)
        return ($uri.IsAbsoluteUri -and $uri.Host.Length -gt 0)
    } catch { return $false }
}

function Get-GitExePath {
    [OutputType([string])]
    param()
    try { return (Get-Command git -ErrorAction Stop).Source } catch { return $null }
}

function Invoke-GitSync {
    param([string]$Url, [string]$Branch = 'main')
    $localPath = Get-GitRootLocalPath -Url $Url
    $hash      = Get-GitRootHash -Url $Url
    $gitExe    = Get-GitExePath
    if (-not $gitExe) {
        $Script:GitStatus[$hash] = @{ url = $Url; synced = $false; error = 'git not found on PATH'; lastSync = (Get-Date).ToString('o') }
        return
    }
    try {
        if ([System.IO.Directory]::Exists($localPath)) {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $gitExe; $psi.Arguments = 'pull --ff-only'
            $psi.WorkingDirectory = $localPath; $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
            $p = [System.Diagnostics.Process]::Start($psi)
            [void]$p.WaitForExit(30000)
            if ($p.ExitCode -ne 0) { throw "git pull exited $($p.ExitCode): $($p.StandardError.ReadToEnd())" }
        } else {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $gitExe
            $psi.Arguments = "clone --depth 1 --branch $Branch --single-branch `"$Url`" `"$localPath`""
            $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
            $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
            $p = [System.Diagnostics.Process]::Start($psi)
            [void]$p.WaitForExit(120000)
            if ($p.ExitCode -ne 0) { throw "git clone exited $($p.ExitCode): $($p.StandardError.ReadToEnd())" }
        }
        $Script:GitStatus[$hash] = @{ url = $Url; synced = $true; error = $null; lastSync = (Get-Date).ToString('o') }
        if (-not $Script:GitScanRoots.Contains($localPath)) { [void]$Script:GitScanRoots.Add($localPath) }
    } catch {
        Write-HubError $_
        $Script:GitStatus[$hash] = @{ url = $Url; synced = $false; error = $_.Exception.Message; lastSync = (Get-Date).ToString('o') }
    }
}

function Get-GitRootsFromConfig {
    [OutputType([object[]])]
    param()
    if ($Script:Config -and $Script:Config.ContainsKey('gitRoots')) {
        $gr = $Script:Config['gitRoots']
        if ($gr -is [System.Array]) { return @($gr) }
    }
    return @()
}

function Initialize-GitRoots {
    $gitExe = Get-GitExePath
    foreach ($entry in (Get-GitRootsFromConfig)) {
        if (-not $entry) { continue }
        $url    = [string]$(if ($entry -is [hashtable]) { $entry['url'] } else { $entry.url })
        $branch = [string]$(if ($entry -is [hashtable]) { $entry['branch'] } else { $entry.branch })
        if (-not $branch) { $branch = 'main' }
        if (-not (Test-ValidGitUrl -Url $url)) { continue }
        $localPath = Get-GitRootLocalPath -Url $url
        if ([System.IO.Directory]::Exists($localPath)) {
            if (-not $Script:GitScanRoots.Contains($localPath)) { [void]$Script:GitScanRoots.Add($localPath) }
            if ($gitExe) {
                # Best-effort pull in background — don't block startup.
                $Script:GitStatus[(Get-GitRootHash -Url $url)] = @{ url = $url; synced = $true; error = $null; lastSync = $null }
            }
        }
    }
}

function Invoke-GitRootsRoute {
    param([System.Net.HttpListenerContext]$Context)
    $method = $Context.Request.HttpMethod

    if ($method -eq 'GET') {
        $roots = Get-GitRootsFromConfig
        $statusList = @($roots | ForEach-Object {
            $url  = if ($_ -is [hashtable]) { $_['url'] } else { $_.url }
            $hash = Get-GitRootHash -Url ([string]$url)
            $st   = if ($Script:GitStatus.ContainsKey($hash)) { $Script:GitStatus[$hash] } else { @{} }
            @{ url = $url; branch = (if ($_ -is [hashtable]) { $_['branch'] } else { $_.branch }); synced = $st['synced']; error = $st['error']; lastSync = $st['lastSync'] }
        })
        Write-JsonResponse -Context $Context -Status 200 -Body @{ gitRoots = $statusList }
        return
    }

    if ($method -eq 'POST') {
        $body = $null
        try {
            $reader = New-Object System.IO.StreamReader($Context.Request.InputStream, [System.Text.Encoding]::UTF8)
            $raw = $reader.ReadToEnd(); $reader.Dispose()
            $body = ConvertFrom-JsonHashtable ($raw | ConvertFrom-Json)
        } catch {
            Write-JsonResponse -Context $Context -Status 400 -Body @{ error = 'invalid-json' }; return
        }
        if (-not $body) { Write-JsonResponse -Context $Context -Status 400 -Body @{ error = 'empty-body' }; return }

        $url    = [string]$body['url']
        $branch = if ($body.ContainsKey('branch') -and $body['branch']) { [string]$body['branch'] } else { 'main' }

        if (-not (Test-ValidGitUrl -Url $url)) {
            Write-JsonResponse -Context $Context -Status 400 -Body @{ error = 'invalid-url'; detail = 'Only https:// URLs are accepted' }
            return
        }

        # Show trust warning in response (ADV-004 — UI must display this).
        $newEntry = @{ url = $url; branch = $branch }
        $roots = [System.Collections.Generic.List[hashtable]]::new()
        foreach ($r in (Get-GitRootsFromConfig)) {
            $rUrl = if ($r -is [hashtable]) { $r['url'] } else { $r.url }
            if ($rUrl -ne $url) { $roots.Add($r) }
        }
        [void]$roots.Add($newEntry)

        # Persist to config.
        $newConfig = @{}
        if ($Script:Config) { foreach ($k in @($Script:Config.Keys)) { $newConfig[$k] = $Script:Config[$k] } }
        $newConfig['gitRoots'] = $roots.ToArray()
        try {
            Write-HubConfig -Config $newConfig
            $Script:Config = $newConfig
        } catch {
            Write-HubError $_
            Write-JsonResponse -Context $Context -Status 500 -Body @{ error = 'config-write-failed' }; return
        }

        # Kick off async sync (in background — don't block the response).
        $Script:GitStatus[(Get-GitRootHash -Url $url)] = @{ url = $url; synced = $false; error = $null; lastSync = $null }
        Start-Job -ScriptBlock {
            param($Url, $Branch, $LocalPath, $GitExe)
            if (-not $GitExe) { return }
            if ([System.IO.Directory]::Exists($LocalPath)) {
                & $GitExe -C $LocalPath pull --ff-only 2>&1 | Out-Null
            } else {
                & $GitExe clone --depth 1 --branch $Branch --single-branch $Url $LocalPath 2>&1 | Out-Null
            }
        } -ArgumentList $url, $branch, (Get-GitRootLocalPath -Url $url), (Get-GitExePath) | Out-Null

        Write-JsonResponse -Context $Context -Status 202 -Body @{
            ok = $true; url = $url; branch = $branch
            trustWarning = 'Scripts in this repository will appear in your Hub catalog. Only add repositories you trust.'
        }
        return
    }

    Write-JsonResponse -Context $Context -Status 405 -Body @{ error = 'method-not-allowed' }
}
