# Hub-Secrets.ps1 — DPAPI-encrypted secrets vault (Phase 3, v1.7).
# Dot-sourced by Hub.ps1 AFTER Hub-Presets.ps1 (uses ConvertFrom-JsonHashtable,
# Write-JsonResponse, $Script:ConfigDir — all defined before dispatch).
#
# PS5.1-SAFE — NON-NEGOTIABLE: this module is dot-sourced into the PS 5.1 / .NET
# Framework host (Hub.exe). NO '??' / ternary / '?.' / 'ConvertFrom-Json -AsHashtable'
# / 'clean {}' anywhere. Parse JSON with ConvertFrom-JsonHashtable; guard nulls with
# 'if ($null -eq $x)'; serialise list responses with ConvertTo-Json -InputObject +
# '[]' fallback (an empty @() becomes JSON null in a pipeline).
#
# Threat model (see docs/plans/phase-3-secrets-vault.md):
#   - Values are encrypted at rest with DPAPI CurrentUser scope.
#   - Values are WRITE-ONLY over the API: no GET ever returns a value.
#   - The only decrypt path is Resolve-SecretValue, called exclusively from the run path,
#     and the plaintext is injected via the child's STDIN, never argv (Start-HubJob).
#   - On-disk filename is SHA256(lowercased name), never the raw name (traversal defense).

# Metadata cache (name -> record WITHOUT ciphertext/value). Never holds plaintext.
$Script:Secrets = [hashtable]::Synchronized(@{})

# Load System.Security for [ProtectedData] on the 5.1 host. On PS7 the type is in-box and
# this assembly name is invalid — guarded so the throw is swallowed (type still resolves).
try { Add-Type -AssemblyName System.Security -ErrorAction Stop } catch { }

# Constant bootstrap shim for secret-bearing runs. Runs in the child pwsh (7.x — 7.x
# syntax is fine here; this is a STRING to the 5.1 host). Reads the secret payload from
# stdin, rebuilds [securestring]/[pscredential], splats into the target, propagates exit.
# NO user input is interpolated into this text (ADV: shim is constant).
$Script:SecretRunShim = @'
$ErrorActionPreference = 'Stop'
$raw = [Console]::In.ReadToEnd()
$payload = $raw | ConvertFrom-Json
$sp = @{}
if ($payload.secrets) {
  foreach ($pr in $payload.secrets.PSObject.Properties) {
    $kind = [string]$pr.Value.kind
    $sec  = ConvertTo-SecureString -String ([string]$pr.Value.value) -AsPlainText -Force
    if ($kind -eq 'credential') {
      if ([string]::IsNullOrEmpty([string]$pr.Value.username)) { throw 'secret-credential-missing-username' }
      $sp[$pr.Name] = [System.Management.Automation.PSCredential]::new([string]$pr.Value.username, $sec)
    } elseif ($kind -eq 'password') {
      $sp[$pr.Name] = $sec
    } else {
      throw "secret-unknown-kind:$kind"
    }
  }
}
$na = @()
if ($payload.argv) { $na = @($payload.argv) }
& ([string]$payload.target) @na @sp
exit $LASTEXITCODE
'@

$Script:SecretValueMaxBytes = 64KB   # ADV-304: bounds DPAPI blob + stdin payload.

function Get-SecretsDir {
    [OutputType([string])]
    param()
    $d = Join-Path $Script:ConfigDir 'secrets'
    if (-not [System.IO.Directory]::Exists($d)) {
        try { [System.IO.Directory]::CreateDirectory($d) | Out-Null } catch { Write-HubError $_ }
    }
    return $d
}

function Test-SecretName {
    # Strict charset: 2-64 chars, no leading/trailing space, no '..', no path separators.
    [OutputType([bool])]
    param([string]$Name)
    if ([string]::IsNullOrEmpty($Name)) { return $false }
    return ($Name -match '^[A-Za-z0-9][A-Za-z0-9 ._-]{0,62}[A-Za-z0-9]$')
}

function Get-SecretFileName {
    # On-disk name = SHA256(lowercased name) hex (16 chars) + '.secret.json'. Hashing the
    # lowercased name makes 'Foo' and 'foo' collide (one secret), defeating case-tricks.
    [OutputType([string])]
    param([string]$Name)
    $norm  = $Name.ToLowerInvariant()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($norm)
    $sha   = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($bytes)
    } finally {
        $sha.Dispose()
    }
    $hex = [System.BitConverter]::ToString($hash).Replace('-', '').ToLowerInvariant()
    return $hex.Substring(0, 16) + '.secret.json'
}

function Protect-SecretValue {
    # Plaintext -> base64 DPAPI CurrentUser blob.
    [OutputType([string])]
    param([string]$Plain)
    $utf8 = [System.Text.Encoding]::UTF8.GetBytes($Plain)
    $blob = [System.Security.Cryptography.ProtectedData]::Protect(
        $utf8, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    return [System.Convert]::ToBase64String($blob)
}

function Unprotect-SecretValue {
    # Base64 DPAPI blob -> plaintext. On failure logs a GENERIC message (never the bytes).
    [OutputType([string])]
    param([string]$B64, [string]$Name)
    try {
        $blob  = [System.Convert]::FromBase64String($B64)
        $plain = [System.Security.Cryptography.ProtectedData]::Unprotect(
            $blob, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
        return [System.Text.Encoding]::UTF8.GetString($plain)
    } catch {
        Write-HubError "secret decrypt failed for $Name"
        throw "secret-decrypt-failed"
    }
}

function Find-SecretByName {
    # Case-insensitive lookup against the metadata cache. Returns the record or $null.
    [OutputType([hashtable])]
    param([string]$Name)
    foreach ($rec in @($Script:Secrets.Values)) {
        if ([string]$rec['name'] -ieq $Name) { return $rec }
    }
    return $null
}

function Save-SecretRecord {
    # Atomic write of a full record (incl. ciphertext) to its hash-named file; cache the
    # metadata-only view (no ciphertext) keyed by original name.
    param([hashtable]$Record)
    if (-not $Record -or -not $Record['name']) { throw 'Save-SecretRecord: name required' }
    $dir  = Get-SecretsDir
    $path = Join-Path $dir (Get-SecretFileName -Name ([string]$Record['name']))
    $tmp  = $path + '.tmp'
    try {
        $json = $Record | ConvertTo-Json -Depth 6 -Compress
        [System.IO.File]::WriteAllText($tmp, $json, [System.Text.UTF8Encoding]::new($false))
        if ([System.IO.File]::Exists($path)) { [System.IO.File]::Delete($path) }
        [System.IO.File]::Move($tmp, $path)
        $Script:Secrets[[string]$Record['name']] = @{
            name      = [string]$Record['name']
            kind      = [string]$Record['kind']
            username  = $Record['username']
            createdAt = [string]$Record['createdAt']
            updatedAt = [string]$Record['updatedAt']
        }
    } catch {
        Write-HubError $_
        try { if ([System.IO.File]::Exists($tmp)) { [System.IO.File]::Delete($tmp) } } catch { }
        throw
    }
}

function Remove-SecretRecord {
    param([string]$Name)
    $dir  = Get-SecretsDir
    $path = Join-Path $dir (Get-SecretFileName -Name $Name)
    try { if ([System.IO.File]::Exists($path)) { [System.IO.File]::Delete($path) } } catch { Write-HubError $_ }
    $rec = Find-SecretByName -Name $Name
    if ($rec) { $Script:Secrets.Remove([string]$rec['name']) }
}

function Read-SecretFile {
    # Load the full on-disk record (incl. ciphertext) for a given name. $null if absent.
    [OutputType([hashtable])]
    param([string]$Name)
    $dir  = Get-SecretsDir
    $path = Join-Path $dir (Get-SecretFileName -Name $Name)
    if (-not [System.IO.File]::Exists($path)) { return $null }
    try {
        $raw = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
        $obj = $raw | ConvertFrom-Json
        return (ConvertFrom-JsonHashtable $obj)
    } catch {
        Write-HubError $_
        return $null
    }
}

function Initialize-Secrets {
    $dir = Get-SecretsDir
    foreach ($file in [System.IO.Directory]::EnumerateFiles($dir, '*.secret.json')) {
        if ($file -match '\.tmp$') { continue }
        try {
            $raw = [System.IO.File]::ReadAllText($file, [System.Text.Encoding]::UTF8)
            $obj = $raw | ConvertFrom-Json
            $r   = ConvertFrom-JsonHashtable $obj
            if ($r -and $r['name']) {
                $Script:Secrets[[string]$r['name']] = @{
                    name      = [string]$r['name']
                    kind      = [string]$r['kind']
                    username  = $r['username']
                    createdAt = [string]$r['createdAt']
                    updatedAt = [string]$r['updatedAt']
                }
            }
        } catch { Write-HubError $_ }
    }
}

function Resolve-SecretValue {
    # The ONLY decrypt entry point. Returns @{ kind; value; username } or throws generic.
    # Called exclusively from the run path (Resolve-RunSecrets), never from a GET handler.
    [OutputType([hashtable])]
    param([string]$Name)
    $rec = Read-SecretFile -Name $Name
    if ($null -eq $rec) { throw "secret-not-found" }
    $plain = Unprotect-SecretValue -B64 ([string]$rec['ciphertext']) -Name $Name
    $uname = $null
    if ($rec.ContainsKey('username')) { $uname = $rec['username'] }
    return @{ kind = [string]$rec['kind']; value = $plain; username = $uname }
}

function Resolve-RunSecrets {
    # Scan submitted values for '@secret:<name>' tokens on password-widget fields, decrypt
    # each, and return a param-name -> { kind; value; username } map for stdin injection.
    # A '@secret:' token on a NON-password field is rejected (defense in depth; Build-Argv
    # also guards). Returns @{ ok=$true; secrets } or @{ ok=$false; status; error }.
    [OutputType([hashtable])]
    param([hashtable]$Schema, [hashtable]$Values)
    $secrets = @{}
    if (-not $Values) { return @{ ok = $true; secrets = $secrets } }

    $pwFields = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    if ($Schema -and $Schema.fields) {
        foreach ($f in @($Schema.fields)) {
            if ($f.widget -eq 'password') { [void]$pwFields.Add([string]$f.name) }
        }
    }

    foreach ($k in @($Values.Keys)) {
        $key = [string]$k
        $val = [string]$Values[$k]
        if ($val -notmatch '^@secret:(.+)$') { continue }
        $name = $Matches[1]
        if (-not $pwFields.Contains($key)) {
            return @{ ok = $false; status = 400; error = 'secret-not-allowed-here' }
        }
        try {
            $resolved = Resolve-SecretValue -Name $name
        } catch {
            return @{ ok = $false; status = 400; error = 'unknown-secret' }
        }
        $secrets[$key] = $resolved
    }
    return @{ ok = $true; secrets = $secrets }
}

function Invoke-SecretsRoute {
    # GET /api/secrets  -> metadata list (NO value).   POST /api/secrets -> create.
    param([System.Net.HttpListenerContext]$Context)
    $method = $Context.Request.HttpMethod

    if ($method -eq 'GET') {
        $list = @($Script:Secrets.Values | Sort-Object { [string]$_['name'] } | ForEach-Object {
            @{ name = [string]$_['name']; kind = [string]$_['kind']; username = $_['username']
               createdAt = [string]$_['createdAt']; updatedAt = [string]$_['updatedAt'] }
        })
        # Empty-array pitfall (PS5.1): a piped empty @() serialises to JSON null.
        $json = ConvertTo-Json -InputObject $list -Depth 5 -Compress
        if ($null -eq $json) { $json = '[]' }
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        $Context.Response.StatusCode      = 200
        $Context.Response.ContentType     = 'application/json; charset=utf-8'
        $Context.Response.ContentLength64 = $bytes.LongLength
        $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
        return
    }

    if ($method -eq 'POST') {
        $body = $null
        try {
            $reader = New-Object System.IO.StreamReader($Context.Request.InputStream, [System.Text.Encoding]::UTF8)
            $raw = $reader.ReadToEnd()
            $reader.Dispose()
            $parsed = $raw | ConvertFrom-Json
            $body = ConvertFrom-JsonHashtable $parsed
        } catch {
            Write-JsonResponse -Context $Context -Status 400 -Body @{ error = 'invalid-json' }
            return
        }
        if ($null -eq $body -or $body -isnot [hashtable]) {
            Write-JsonResponse -Context $Context -Status 400 -Body @{ error = 'empty-body' }
            return
        }
        $name = [string]$body['name']
        $kind = [string]$body['kind']
        if (-not (Test-SecretName -Name $name)) { Write-JsonResponse -Context $Context -Status 422 -Body @{ error = 'invalid-name' }; return }
        if ($kind -ne 'password' -and $kind -ne 'credential') { Write-JsonResponse -Context $Context -Status 422 -Body @{ error = 'invalid-kind' }; return }
        if (-not $body.ContainsKey('value') -or $null -eq $body['value']) { Write-JsonResponse -Context $Context -Status 422 -Body @{ error = 'value-required' }; return }
        $value = [string]$body['value']
        if ([System.Text.Encoding]::UTF8.GetByteCount($value) -gt $Script:SecretValueMaxBytes) {
            Write-JsonResponse -Context $Context -Status 413 -Body @{ error = 'value-too-large' }; return
        }
        if (Find-SecretByName -Name $name) { Write-JsonResponse -Context $Context -Status 409 -Body @{ error = 'duplicate-name' }; return }

        $username = $null
        if ($kind -eq 'credential') {
            $username = [string]$body['username']
            if ([string]::IsNullOrWhiteSpace($username)) { Write-JsonResponse -Context $Context -Status 422 -Body @{ error = 'username-required' }; return }
        }

        $now = (Get-Date).ToString('o')
        $record = @{
            v          = 1
            name       = $name
            kind       = $kind
            username   = $username
            ciphertext = (Protect-SecretValue -Plain $value)
            createdAt  = $now
            updatedAt  = $now
        }
        try {
            Save-SecretRecord -Record $record
        } catch {
            Write-HubError $_
            Write-JsonResponse -Context $Context -Status 500 -Body @{ error = 'save-failed' }
            return
        }
        Write-JsonResponse -Context $Context -Status 200 -Body @{ name = $name; kind = $kind; username = $username; createdAt = $now; updatedAt = $now }
        return
    }

    Write-JsonResponse -Context $Context -Status 405 -Body @{ error = 'method-not-allowed' }
}

function Invoke-SecretByNameRoute {
    # PUT /api/secrets/<name>  -> rename and/or rotate value.   DELETE -> remove.
    param([System.Net.HttpListenerContext]$Context, [string]$Name)
    $method = $Context.Request.HttpMethod
    $decoded = [uri]::UnescapeDataString($Name)

    if ($method -eq 'DELETE') {
        $rec = Find-SecretByName -Name $decoded
        if ($null -eq $rec) { Write-JsonResponse -Context $Context -Status 404 -Body @{ error = 'not-found' }; return }
        try { Remove-SecretRecord -Name $decoded } catch { Write-HubError $_ }
        Write-JsonResponse -Context $Context -Status 200 -Body @{ ok = $true }
        return
    }

    if ($method -eq 'PUT') {
        $existing = Read-SecretFile -Name $decoded
        if ($null -eq $existing) { Write-JsonResponse -Context $Context -Status 404 -Body @{ error = 'not-found' }; return }

        $body = $null
        try {
            $reader = New-Object System.IO.StreamReader($Context.Request.InputStream, [System.Text.Encoding]::UTF8)
            $raw = $reader.ReadToEnd()
            $reader.Dispose()
            $parsed = $raw | ConvertFrom-Json
            $body = ConvertFrom-JsonHashtable $parsed
        } catch {
            Write-JsonResponse -Context $Context -Status 400 -Body @{ error = 'invalid-json' }
            return
        }
        if ($null -eq $body -or $body -isnot [hashtable]) {
            Write-JsonResponse -Context $Context -Status 400 -Body @{ error = 'empty-body' }
            return
        }

        $newName = $decoded
        if ($body.ContainsKey('name') -and -not [string]::IsNullOrEmpty([string]$body['name'])) {
            $newName = [string]$body['name']
            if (-not (Test-SecretName -Name $newName)) { Write-JsonResponse -Context $Context -Status 422 -Body @{ error = 'invalid-name' }; return }
            if (-not ($newName -ieq $decoded)) {
                if (Find-SecretByName -Name $newName) { Write-JsonResponse -Context $Context -Status 409 -Body @{ error = 'duplicate-name' }; return }
            }
        }

        # Rotate value if provided; otherwise keep the existing ciphertext.
        $ciphertext = [string]$existing['ciphertext']
        if ($body.ContainsKey('value') -and $null -ne $body['value']) {
            $value = [string]$body['value']
            if ([System.Text.Encoding]::UTF8.GetByteCount($value) -gt $Script:SecretValueMaxBytes) {
                Write-JsonResponse -Context $Context -Status 413 -Body @{ error = 'value-too-large' }; return
            }
            $ciphertext = Protect-SecretValue -Plain $value
        }

        $username = $existing['username']
        if ($body.ContainsKey('username')) { $username = $body['username'] }
        $kind = [string]$existing['kind']
        if ($kind -eq 'credential' -and [string]::IsNullOrWhiteSpace([string]$username)) {
            Write-JsonResponse -Context $Context -Status 422 -Body @{ error = 'username-required' }; return
        }

        $now = (Get-Date).ToString('o')
        $record = @{
            v          = 1
            name       = $newName
            kind       = $kind
            username   = $username
            ciphertext = $ciphertext
            createdAt  = [string]$existing['createdAt']
            updatedAt  = $now
        }
        try {
            # Rename = write under new hash filename + delete the old file.
            if (-not ($newName -ieq $decoded)) { Remove-SecretRecord -Name $decoded }
            Save-SecretRecord -Record $record
        } catch {
            Write-HubError $_
            Write-JsonResponse -Context $Context -Status 500 -Body @{ error = 'save-failed' }
            return
        }
        Write-JsonResponse -Context $Context -Status 200 -Body @{ name = $newName; kind = $kind; username = $username; createdAt = [string]$existing['createdAt']; updatedAt = $now }
        return
    }

    Write-JsonResponse -Context $Context -Status 405 -Body @{ error = 'method-not-allowed' }
}
