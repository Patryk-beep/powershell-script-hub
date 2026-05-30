# Hub-Presets.ps1 — Parameter presets / saved runs (Phase 2).
# Dot-sourced by Hub.ps1 AFTER Hub-Workflows.ps1 (uses ConvertFrom-JsonHashtable)
# and AFTER the run helpers (uses Resolve-ItemContext / Remove-SecretValues, both
# defined in Hub.ps1). Mirrors the Hub-Workflows.ps1 module shape.
#
# PS5.1-safe: no '??' / ternary / '?.' / 'ConvertFrom-Json -AsHashtable'.
#
# A preset record: { id, itemId, name, values (SECRETS REDACTED), createdAt }.
# Redaction is keyed off the LIVE schema at save time (Remove-SecretValues), so a
# password-typed OR conventionally-named secret field never reaches presets\*.json.

$Script:Presets = [hashtable]::Synchronized(@{})

function Get-PresetsDir {
    [OutputType([string])]
    param()
    $d = Join-Path $Script:ConfigDir 'presets'
    if (-not [System.IO.Directory]::Exists($d)) {
        try { [System.IO.Directory]::CreateDirectory($d) | Out-Null } catch { Write-HubError $_ }
    }
    return $d
}

function New-PresetId {
    [OutputType([string])]
    param()
    return 'ps-' + [guid]::NewGuid().Guid
}

function Save-Preset {
    param([hashtable]$Preset)
    if (-not $Preset -or -not $Preset['id']) { throw 'Save-Preset: id required' }
    $dir  = Get-PresetsDir
    $path = Join-Path $dir "$($Preset.id).json"
    $tmp  = $path + '.tmp'
    try {
        $json = $Preset | ConvertTo-Json -Depth 10 -Compress
        [System.IO.File]::WriteAllText($tmp, $json, [System.Text.UTF8Encoding]::new($false))
        if ([System.IO.File]::Exists($path)) { [System.IO.File]::Delete($path) }
        [System.IO.File]::Move($tmp, $path)
        $Script:Presets[$Preset.id] = $Preset
    } catch {
        Write-HubError $_
        try { if ([System.IO.File]::Exists($tmp)) { [System.IO.File]::Delete($tmp) } } catch { }
        throw
    }
}

function Remove-PresetFile {
    param([string]$Id)
    $dir  = Get-PresetsDir
    $path = Join-Path $dir "$Id.json"
    try { if ([System.IO.File]::Exists($path)) { [System.IO.File]::Delete($path) } } catch { Write-HubError $_ }
    $Script:Presets.Remove($Id)
}

function Initialize-Presets {
    $dir = Get-PresetsDir
    foreach ($file in [System.IO.Directory]::EnumerateFiles($dir, '*.json')) {
        if ($file -match '\.tmp$') { continue }
        try {
            $raw = [System.IO.File]::ReadAllText($file, [System.Text.Encoding]::UTF8)
            $obj = $raw | ConvertFrom-Json
            $p   = ConvertFrom-JsonHashtable $obj
            if ($p -and $p['id']) {
                $Script:Presets[$p.id] = $p
            }
        } catch { Write-HubError $_ }
    }
}

function Invoke-PresetsRoute {
    # Collection: GET /api/presets?itemId=<id>  |  POST /api/presets
    param([System.Net.HttpListenerContext]$Context)
    $method = $Context.Request.HttpMethod

    if ($method -eq 'GET') {
        $itemId = [string]$Context.Request.QueryString['itemId']
        $all = @($Script:Presets.Values)
        if ($itemId) {
            $list = @($all | Where-Object { [string]$_['itemId'] -eq $itemId } | Sort-Object { [string]$_['name'] })
        } else {
            $list = @($all | Sort-Object { [string]$_['name'] })
        }
        # Array endpoint: serialize via -InputObject + '[]' fallback (NOT Write-JsonResponse,
        # whose pipeline form turns an empty @() into JSON null — the /api/history bug).
        $json = ConvertTo-Json -InputObject $list -Depth 10 -Compress
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
        $itemId = [string]$body['itemId']
        $name   = [string]$body['name']
        if (-not $itemId)                                  { Write-JsonResponse -Context $Context -Status 400 -Body @{ error = 'itemId-required' }; return }
        if ([string]::IsNullOrWhiteSpace($name))           { Write-JsonResponse -Context $Context -Status 400 -Body @{ error = 'name-required' };   return }

        # Resolve item + re-validate scan root + load live schema (shared helper).
        $ctx = Resolve-ItemContext -ItemId $itemId
        if (-not $ctx.ok) {
            Write-JsonResponse -Context $Context -Status $ctx.status -Body @{ error = $ctx.error }
            return
        }
        # Presets are typed-mode only — raw args are never offered as a saved value.
        if ($ctx.schema -and $ctx.schema.mode -eq 'raw') {
            Write-JsonResponse -Context $Context -Status 422 -Body @{ error = 'presets-typed-mode-only' }
            return
        }

        $values = @{}
        $vIn = $body['values']
        if ($vIn -and $vIn -is [hashtable]) { $values = $vIn }
        # Drop secrets (password-widget OR secret-named) BEFORE persisting (ADV-201).
        $safeValues = Remove-SecretValues -Schema $ctx.schema -Values $values

        $record = @{
            id        = New-PresetId
            itemId    = $itemId
            name      = $name
            values    = $safeValues
            createdAt = (Get-Date).ToString('o')
        }
        try {
            Save-Preset -Preset $record
        } catch {
            Write-HubError $_
            Write-JsonResponse -Context $Context -Status 500 -Body @{ error = 'save-failed' }
            return
        }
        Write-JsonResponse -Context $Context -Status 200 -Body $record
        return
    }

    Write-JsonResponse -Context $Context -Status 405 -Body @{ error = 'method-not-allowed' }
}

function Invoke-PresetByIdRoute {
    # DELETE /api/presets/<id>   (no PUT — edit = delete + re-save, matching workflows)
    param([System.Net.HttpListenerContext]$Context, [string]$PresetId)
    $method = $Context.Request.HttpMethod

    if ($method -eq 'DELETE') {
        if (-not $Script:Presets.ContainsKey($PresetId)) {
            Write-JsonResponse -Context $Context -Status 404 -Body @{ error = 'not-found' }
            return
        }
        try { Remove-PresetFile -Id $PresetId } catch { Write-HubError $_ }
        Write-JsonResponse -Context $Context -Status 200 -Body @{ ok = $true }
        return
    }

    Write-JsonResponse -Context $Context -Status 405 -Body @{ error = 'method-not-allowed' }
}
