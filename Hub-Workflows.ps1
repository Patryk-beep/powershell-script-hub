# Hub-Workflows.ps1 — Workflow CRUD, state machine, and execution engine (Phases 1–2).
# Dot-sourced by Hub.ps1 after all $Script: globals are set.

$Script:Workflows    = [hashtable]::Synchronized(@{})
$Script:WorkflowRuns = [hashtable]::Synchronized(@{})

function Get-WorkflowsDir {
    [OutputType([string])]
    param()
    $d = Join-Path $Script:ConfigDir 'workflows'
    if (-not [System.IO.Directory]::Exists($d)) {
        try { [System.IO.Directory]::CreateDirectory($d) | Out-Null } catch { Write-HubError $_ }
    }
    return $d
}

function Get-WorkflowRunsDir {
    [OutputType([string])]
    param()
    $d = Join-Path $Script:ConfigDir 'workflow-runs'
    if (-not [System.IO.Directory]::Exists($d)) {
        try { [System.IO.Directory]::CreateDirectory($d) | Out-Null } catch { Write-HubError $_ }
    }
    return $d
}

function New-WorkflowId {
    [OutputType([string])]
    param()
    return 'wf-' + [guid]::NewGuid().Guid
}

function ConvertFrom-JsonHashtable {
    # Recursively converts PSCustomObject (ConvertFrom-Json output) to hashtable.
    # Required for PS5 compatibility — ConvertFrom-Json -AsHashtable is PS6+ only.
    param($Obj)
    if ($null -eq $Obj) { return $null }
    if ($Obj -is [System.Management.Automation.PSCustomObject]) {
        $ht = @{}
        foreach ($prop in $Obj.PSObject.Properties) {
            $ht[$prop.Name] = ConvertFrom-JsonHashtable $prop.Value
        }
        return $ht
    }
    if ($Obj -is [System.Array]) {
        # Prefix , prevents PowerShell from unrolling single-element arrays at the function-return boundary.
        return ,@($Obj | ForEach-Object { ConvertFrom-JsonHashtable $_ })
    }
    return $Obj
}

function Save-Workflow {
    param([hashtable]$Workflow)
    if (-not $Workflow -or -not $Workflow['id']) { throw 'Save-Workflow: id required' }
    $dir  = Get-WorkflowsDir
    $path = Join-Path $dir "$($Workflow.id).json"
    $tmp  = $path + '.tmp'
    try {
        $json = $Workflow | ConvertTo-Json -Depth 10 -Compress
        [System.IO.File]::WriteAllText($tmp, $json, [System.Text.UTF8Encoding]::new($false))
        if ([System.IO.File]::Exists($path)) { [System.IO.File]::Delete($path) }
        [System.IO.File]::Move($tmp, $path)
        $Script:Workflows[$Workflow.id] = $Workflow
    } catch {
        Write-HubError $_
        try { if ([System.IO.File]::Exists($tmp)) { [System.IO.File]::Delete($tmp) } } catch { }
        throw
    }
}

function Remove-WorkflowFile {
    param([string]$Id)
    $dir  = Get-WorkflowsDir
    $path = Join-Path $dir "$Id.json"
    try { if ([System.IO.File]::Exists($path)) { [System.IO.File]::Delete($path) } } catch { Write-HubError $_ }
    $Script:Workflows.Remove($Id)
}

function Initialize-Workflows {
    $dir = Get-WorkflowsDir
    [void](Get-WorkflowRunsDir)
    foreach ($file in [System.IO.Directory]::EnumerateFiles($dir, '*.json')) {
        if ($file -match '\.tmp$') { continue }
        try {
            $raw = [System.IO.File]::ReadAllText($file, [System.Text.Encoding]::UTF8)
            $obj = $raw | ConvertFrom-Json
            $wf  = ConvertFrom-JsonHashtable $obj
            if ($wf -and $wf['id']) {
                $Script:Workflows[$wf.id] = $wf
            }
        } catch { Write-HubError $_ }
    }
}

function Test-WorkflowGraph {
    # Returns $true if the step graph is acyclic; $false if a cycle is found.
    [OutputType([bool])]
    param([object[]]$Steps)
    if (-not $Steps -or $Steps.Count -eq 0) { return $true }

    # Build adjacency map: stepId -> list of successor stepIds (excluding 'stop').
    # 'next' resolves to the next step by index; absent field = implicit 'next'.
    $stepIds = @($Steps | ForEach-Object { [string]$_['id'] })
    $adj = @{}
    for ($i = 0; $i -lt $Steps.Count; $i++) {
        $s   = $Steps[$i]
        $sid = [string]$s['id']
        $adj[$sid] = [System.Collections.Generic.List[string]]::new()

        foreach ($field in @('onSuccess', 'onFailure')) {
            $target = if ($s.ContainsKey($field)) { [string]$s[$field] } else { 'next' }
            if ($target -eq 'stop') { continue }
            if ($target -eq 'next') {
                if ($i + 1 -lt $Steps.Count) { [void]$adj[$sid].Add($stepIds[$i + 1]) }
                continue
            }
            if ($stepIds -contains $target) { [void]$adj[$sid].Add($target) }
        }
    }

    # DFS cycle detection.
    $visited = @{}
    $inStack = @{}

    function Visit-Step ([string]$Id) {
        if ($inStack[$Id]) { return $false }
        if ($visited[$Id])  { return $true }
        $visited[$Id] = $true
        $inStack[$Id] = $true
        foreach ($next in $adj[$Id]) {
            if (-not (Visit-Step $next)) { $inStack[$Id] = $false; return $false }
        }
        $inStack[$Id] = $false
        return $true
    }

    foreach ($sid in $stepIds) {
        if (-not (Visit-Step $sid)) { return $false }
    }
    return $true
}

function Test-WorkflowSchema {
    # Returns @{ ok=$true } on success, @{ ok=$false; errors=[string[]] } on failure.
    [OutputType([hashtable])]
    param([hashtable]$Wf)
    $errors = [System.Collections.Generic.List[string]]::new()

    if (-not $Wf['name'] -or [string]::IsNullOrWhiteSpace([string]$Wf['name'])) {
        [void]$errors.Add('name is required')
    }

    $steps = $Wf['steps']
    if (-not $steps -or ($steps -is [System.Array] -and $steps.Count -eq 0)) {
        [void]$errors.Add('steps must be a non-empty array')
        return @{ ok = $false; errors = $errors.ToArray() }
    }
    if ($steps -isnot [System.Array]) {
        [void]$errors.Add('steps must be an array')
        return @{ ok = $false; errors = $errors.ToArray() }
    }
    if ($steps.Count -gt 50) {
        [void]$errors.Add('workflow exceeds maximum step count (50)')
        return @{ ok = $false; errors = $errors.ToArray() }
    }

    $stepIds = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $steps.Count; $i++) {
        $step = $steps[$i]
        if ($null -eq $step -or $step -isnot [hashtable]) {
            [void]$errors.Add("step[$i] is not an object"); continue
        }
        $sid = if ($step.ContainsKey('id')) { [string]$step['id'] } else { '' }
        if ([string]::IsNullOrWhiteSpace($sid)) {
            [void]$errors.Add("step[$i] missing id"); continue
        }
        if ($stepIds.Contains($sid)) {
            [void]$errors.Add("duplicate step id '$sid'")
        } else {
            [void]$stepIds.Add($sid)
        }

        # scriptId must not contain templates.
        $scriptId = if ($step.ContainsKey('scriptId')) { [string]$step['scriptId'] } else { '' }
        if ([string]::IsNullOrWhiteSpace($scriptId)) {
            [void]$errors.Add("step '$sid' missing scriptId")
        } elseif ($scriptId.Contains('{{')) {
            [void]$errors.Add("step '$sid' scriptId must not contain templates (ADV-002)")
        }

        # Template keys in params are forbidden; validate forward references in values.
        $params = $step['params']
        if ($null -ne $params -and $params -is [hashtable]) {
            foreach ($key in @($params.Keys)) {
                if ([string]$key -match '\{\{') {
                    [void]$errors.Add("step '$sid' params key '$key' must not contain templates")
                }
                $val = [string]$params[$key]
                $refsInVal = [regex]::Matches($val, '\{\{step-([^.}]+)')
                foreach ($m in $refsInVal) {
                    $refId = $m.Groups[1].Value
                    # Forward reference: refId must appear before this step in stepIds.
                    if (-not $stepIds.Contains($refId)) {
                        [void]$errors.Add("step '$sid' param '$key' references '{{step-$refId' which is not a prior step (forward reference forbidden)")
                    }
                }
            }
        }
    }

    # Validate onSuccess/onFailure targets.
    $validTargets = @('stop', 'next') + $stepIds.ToArray()
    for ($i = 0; $i -lt $steps.Count; $i++) {
        $step = $steps[$i]
        if ($null -eq $step -or $step -isnot [hashtable]) { continue }
        $sid = if ($step.ContainsKey('id')) { [string]$step['id'] } else { "[$i]" }
        foreach ($field in @('onSuccess', 'onFailure')) {
            if (-not $step.ContainsKey($field)) { continue }
            $target = [string]$step[$field]
            if ($validTargets -notcontains $target) {
                [void]$errors.Add("step '$sid' $field '$target' is not a valid step id or 'stop'/'next'")
            }
        }
    }

    # Cycle detection.
    if ($errors.Count -eq 0 -and -not (Test-WorkflowGraph -Steps $steps)) {
        [void]$errors.Add('workflow step graph contains a cycle (ADV-009)')
    }

    # Trigger validation (delegates to Hub-Triggers.ps1 if loaded).
    $trigger = $Wf['trigger']
    if ($trigger -and $trigger -is [hashtable]) {
        $testFn = Get-Command 'Test-TriggerSpec' -ErrorAction SilentlyContinue
        if ($testFn) {
            $trigErr = & $testFn -Trigger $trigger
            if ($trigErr) { [void]$errors.Add($trigErr) }
        }
    }

    if ($errors.Count -gt 0) { return @{ ok = $false; errors = $errors.ToArray() } }
    return @{ ok = $true; errors = @() }
}

function Invoke-WorkflowsRoute {
    param([System.Net.HttpListenerContext]$Context)
    $method = $Context.Request.HttpMethod

    if ($method -eq 'GET') {
        $list = @($Script:Workflows.Values | Sort-Object { [string]$_['name'] })
        # Serialize array explicitly via -InputObject to prevent pipeline enumeration yielding $null for empty arrays.
        $json  = ConvertTo-Json -InputObject $list -Depth 10 -Compress
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
        if ($null -eq $body) {
            Write-JsonResponse -Context $Context -Status 400 -Body @{ error = 'empty-body' }
            return
        }

        # Assign or preserve ID.
        if (-not $body.ContainsKey('id') -or [string]::IsNullOrWhiteSpace([string]$body['id'])) {
            $body['id'] = New-WorkflowId
        }
        $body['version'] = if ($body.ContainsKey('version')) { [int]$body['version'] + 1 } else { 1 }

        $validation = Test-WorkflowSchema -Wf $body
        if (-not $validation.ok) {
            Write-JsonResponse -Context $Context -Status 422 -Body @{ error = 'validation-failed'; details = $validation.errors }
            return
        }

        try {
            Save-Workflow -Workflow $body
        } catch {
            Write-HubError $_
            Write-JsonResponse -Context $Context -Status 500 -Body @{ error = 'save-failed' }
            return
        }
        Write-JsonResponse -Context $Context -Status 200 -Body $body
        return
    }

    Write-JsonResponse -Context $Context -Status 405 -Body @{ error = 'method-not-allowed' }
}

function Invoke-WorkflowByIdRoute {
    param([System.Net.HttpListenerContext]$Context, [string]$WorkflowId)
    $method = $Context.Request.HttpMethod

    if ($method -eq 'GET') {
        if (-not $Script:Workflows.ContainsKey($WorkflowId)) {
            Write-JsonResponse -Context $Context -Status 404 -Body @{ error = 'not-found' }
            return
        }
        Write-JsonResponse -Context $Context -Status 200 -Body $Script:Workflows[$WorkflowId]
        return
    }

    if ($method -eq 'DELETE') {
        if (-not $Script:Workflows.ContainsKey($WorkflowId)) {
            Write-JsonResponse -Context $Context -Status 404 -Body @{ error = 'not-found' }
            return
        }
        try { Remove-WorkflowFile -Id $WorkflowId } catch { Write-HubError $_ }
        Write-JsonResponse -Context $Context -Status 200 -Body @{ ok = $true }
        return
    }

    Write-JsonResponse -Context $Context -Status 405 -Body @{ error = 'method-not-allowed' }
}
