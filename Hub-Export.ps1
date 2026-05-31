# Hub-Export.ps1 — Workflow export/import as .hubflow envelopes (Phase 3, v1.7).
# Dot-sourced by Hub.ps1 AFTER Hub-Workflows.ps1 (reuses Test-WorkflowSchema, New-WorkflowId,
# Save-Workflow, $Script:Workflows) and AFTER the run helpers (Get-HubItems, Get-ParamSchema).
#
# PS5.1-SAFE — NON-NEGOTIABLE: no '??' / ternary / '?.' / 'ConvertFrom-Json -AsHashtable'.
# Parse JSON with ConvertFrom-JsonHashtable; serialise lists with ConvertTo-Json -InputObject
# + '[]' fallback.
#
# Security invariants:
#   - A .hubflow carries ONLY '@secret:<name>' reference tokens in params, never values.
#     An explicit scrub pass rejects export if a literal somehow reached a password param.
#   - Import forces a fresh id (never trusts an incoming id -> no overwrite of an existing
#     workflow), resets version to 1, and runs the full Test-WorkflowSchema (templates in
#     scriptId, cycles, forward refs, step cap). Imported scripts are NEVER auto-run.

$Script:HubflowVersion       = 1
$Script:HubflowImportMaxBytes = 256KB

function Get-StepSecretRefs {
    # Returns the distinct '@secret:<name>' names referenced across all steps' params.
    [OutputType([string[]])]
    param([hashtable]$Workflow)
    $names = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $steps = $Workflow['steps']
    if ($steps -and ($steps -is [System.Array])) {
        foreach ($step in $steps) {
            if ($null -eq $step -or $step -isnot [hashtable]) { continue }
            $params = $step['params']
            if ($null -eq $params -or $params -isnot [hashtable]) { continue }
            foreach ($k in @($params.Keys)) {
                $v = [string]$params[$k]
                if ($v -match '^@secret:(.+)$') { [void]$names.Add($Matches[1]) }
            }
        }
    }
    return ,@($names)
}

function Resolve-CatalogItemByScriptId {
    # Mirror the engine's path-normalised catalog match. $null if the scriptId is not under
    # any current scan root (i.e. not in the catalog).
    [OutputType([hashtable])]
    param([string]$ScriptId)
    $sidNorm = ([string]$ScriptId) -replace '/', '\'
    $catalog = (Get-HubItems).items
    foreach ($it in $catalog) {
        if ((([string]$it.path) -replace '/', '\') -ieq $sidNorm) { return $it }
    }
    return $null
}

function Test-WorkflowExportClean {
    # Defense-in-depth scrub: for every resolvable step, load its live schema and assert
    # that each PASSWORD-widget param value (if present) is a '@secret:' token, never a
    # literal. Steps whose scriptId is not resolvable are skipped (cannot determine schema).
    # Returns @{ ok=$true } or @{ ok=$false; field }.
    [OutputType([hashtable])]
    param([hashtable]$Workflow)
    $steps = $Workflow['steps']
    if (-not $steps -or ($steps -isnot [System.Array])) { return @{ ok = $true } }
    foreach ($step in $steps) {
        if ($null -eq $step -or $step -isnot [hashtable]) { continue }
        $params = $step['params']
        if ($null -eq $params -or $params -isnot [hashtable]) { continue }
        $item = Resolve-CatalogItemByScriptId -ScriptId ([string]$step['scriptId'])
        if ($null -eq $item) { continue }
        $schema = Get-ParamSchema -ScriptPath $item.path
        if (-not $schema -or -not $schema.fields) { continue }
        foreach ($f in @($schema.fields)) {
            if ($f.widget -ne 'password') { continue }
            $fn = [string]$f.name
            if (-not $params.ContainsKey($fn)) { continue }
            $val = [string]$params[$fn]
            if ($val -ne '' -and ($val -notmatch '^@secret:')) {
                return @{ ok = $false; field = $fn }
            }
        }
    }
    return @{ ok = $true }
}

function Invoke-WorkflowExportRoute {
    # GET /api/workflows/<id>/export — download a .hubflow envelope (read-only).
    param([System.Net.HttpListenerContext]$Context, [string]$WorkflowId)
    if ($Context.Request.HttpMethod -ne 'GET') {
        Write-JsonResponse -Context $Context -Status 405 -Body @{ error = 'method-not-allowed' }
        return
    }
    if (-not $Script:Workflows.ContainsKey($WorkflowId)) {
        Write-JsonResponse -Context $Context -Status 404 -Body @{ error = 'not-found' }
        return
    }
    $wf = $Script:Workflows[$WorkflowId]

    # Scrub: never export a literal secret in a password param (defense in depth).
    $clean = Test-WorkflowExportClean -Workflow $wf
    if (-not $clean.ok) {
        Write-JsonResponse -Context $Context -Status 422 -Body @{ error = 'secret-literal-in-workflow'; field = $clean.field }
        return
    }

    $envelope = @{
        hubflow    = $Script:HubflowVersion
        exportedAt = (Get-Date).ToString('o')
        hubVersion = $Script:Version
        workflow   = $wf
    }
    $json  = $envelope | ConvertTo-Json -Depth 12 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)

    # Safe download filename from the workflow name (charset-restricted; '.hubflow').
    $safe = ([string]$wf['name']) -replace '[^A-Za-z0-9 ._-]', '_'
    if ([string]::IsNullOrWhiteSpace($safe)) { $safe = 'workflow' }
    if ($safe.Length -gt 64) { $safe = $safe.Substring(0, 64) }

    $Context.Response.StatusCode      = 200
    $Context.Response.ContentType     = 'application/json; charset=utf-8'
    $Context.Response.Headers.Add('Content-Disposition', "attachment; filename=`"$safe.hubflow`"")
    $Context.Response.ContentLength64 = $bytes.LongLength
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
}

function Invoke-WorkflowImportRoute {
    # POST /api/workflows/import — validate + save an imported .hubflow. State route (CSRF).
    param([System.Net.HttpListenerContext]$Context)
    if ($Context.Request.HttpMethod -ne 'POST') {
        Write-JsonResponse -Context $Context -Status 405 -Body @{ error = 'method-not-allowed' }
        return
    }
    # Bound parse cost (ADV): reject oversized bodies before reading.
    if ($Context.Request.ContentLength64 -gt $Script:HubflowImportMaxBytes) {
        Write-JsonResponse -Context $Context -Status 413 -Body @{ error = 'import-too-large' }
        return
    }

    $envelope = $null
    try {
        $reader = New-Object System.IO.StreamReader($Context.Request.InputStream, [System.Text.Encoding]::UTF8)
        $raw = $reader.ReadToEnd()
        $reader.Dispose()
        if ($raw.Length -gt $Script:HubflowImportMaxBytes) {
            Write-JsonResponse -Context $Context -Status 413 -Body @{ error = 'import-too-large' }
            return
        }
        $parsed = $raw | ConvertFrom-Json
        $envelope = ConvertFrom-JsonHashtable $parsed
    } catch {
        Write-JsonResponse -Context $Context -Status 400 -Body @{ error = 'invalid-json' }
        return
    }
    if ($null -eq $envelope -or $envelope -isnot [hashtable]) {
        Write-JsonResponse -Context $Context -Status 400 -Body @{ error = 'empty-body' }
        return
    }
    if (-not $envelope.ContainsKey('hubflow') -or [int]$envelope['hubflow'] -ne $Script:HubflowVersion) {
        Write-JsonResponse -Context $Context -Status 422 -Body @{ error = 'unsupported-hubflow-version' }
        return
    }
    $wf = $envelope['workflow']
    if ($null -eq $wf -or $wf -isnot [hashtable]) {
        Write-JsonResponse -Context $Context -Status 422 -Body @{ error = 'missing-workflow' }
        return
    }

    # NEVER trust the incoming id/version — force a fresh id (no overwrite) and reset version.
    $wf['id']      = New-WorkflowId
    $wf['version'] = 1
    # Execution-control fields must NOT transfer with a shared workflow: a cron/file-watch
    # trigger in an imported file would otherwise be picked up by Advance-TriggerSchedules and
    # auto-run the workflow with no explicit enable. Reset to manual (the import "never
    # auto-runs" guarantee). The importer can re-add a trigger deliberately afterward.
    $wf['trigger'] = @{ type = 'manual' }

    $validation = Test-WorkflowSchema -Wf $wf
    if (-not $validation.ok) {
        Write-JsonResponse -Context $Context -Status 422 -Body @{ error = 'validation-failed'; details = $validation.errors }
        return
    }

    # Imported scripts are NEVER auto-run. Report scriptIds not under a current scan root
    # and the secret names the importer must create locally, for the UI trust warning.
    $unresolved = New-Object 'System.Collections.Generic.List[string]'
    $steps = $wf['steps']
    if ($steps -and ($steps -is [System.Array])) {
        foreach ($step in $steps) {
            if ($null -eq $step -or $step -isnot [hashtable]) { continue }
            $sid = [string]$step['scriptId']
            if ([string]::IsNullOrWhiteSpace($sid)) { continue }
            if ($null -eq (Resolve-CatalogItemByScriptId -ScriptId $sid)) { [void]$unresolved.Add($sid) }
        }
    }
    $referencedSecrets = Get-StepSecretRefs -Workflow $wf

    try {
        Save-Workflow -Workflow $wf
    } catch {
        Write-HubError $_
        Write-JsonResponse -Context $Context -Status 500 -Body @{ error = 'save-failed' }
        return
    }

    Write-JsonResponse -Context $Context -Status 200 -Body @{
        id                = [string]$wf['id']
        name              = [string]$wf['name']
        unresolvedScripts = @($unresolved.ToArray())
        referencedSecrets = @($referencedSecrets)
    }
}
