# Hub-WorkflowEngine.ps1 — Workflow execution engine and run routes (Phase 2).
# Dot-sourced by Hub.ps1 after Hub-Workflows.ps1.

function New-WorkflowRunId {
    [OutputType([string])]
    param()
    return 'run-' + [guid]::NewGuid().Guid
}

function Save-WorkflowRun {
    param([hashtable]$Run)
    $dir  = Get-WorkflowRunsDir
    $path = Join-Path $dir "$($Run.runId).json"
    $tmp  = $path + '.tmp'
    try {
        $copy = @{}
        foreach ($k in @($Run.Keys)) {
            if ($k -notin @('subscribers', 'pathMap')) { $copy[$k] = $Run[$k] }
        }
        $json = $copy | ConvertTo-Json -Depth 10 -Compress
        [System.IO.File]::WriteAllText($tmp, $json, [System.Text.UTF8Encoding]::new($false))
        if ([System.IO.File]::Exists($path)) { [System.IO.File]::Delete($path) }
        [System.IO.File]::Move($tmp, $path)
    } catch {
        Write-HubError $_
        try { if ([System.IO.File]::Exists($tmp)) { [System.IO.File]::Delete($tmp) } } catch { }
    }
}

function Initialize-WorkflowRuns {
    $dir = Get-WorkflowRunsDir
    foreach ($file in [System.IO.Directory]::EnumerateFiles($dir, '*.json')) {
        if ($file -match '\.tmp$') { continue }
        try {
            $raw = [System.IO.File]::ReadAllText($file, [System.Text.Encoding]::UTF8)
            $run = ConvertFrom-JsonHashtable ($raw | ConvertFrom-Json)
            if ($run -and $run['runId'] -and -not $run['endedAt']) {
                $run['status']      = 'interrupted'
                $run['endedAt']     = (Get-Date).ToString('o')
                $run['subscribers'] = New-Object 'System.Collections.Generic.List[hashtable]'
                $run['pathMap']     = @{}
                $Script:WorkflowRuns[$run.runId] = $run
                Save-WorkflowRun -Run $run
            }
        } catch { Write-HubError $_ }
    }
}

function Send-RunSseFrame {
    param([hashtable]$Run, [string]$EventName, $Data)
    if ($Run.subscribers.Count -eq 0) { return }
    $bytes = ConvertTo-SsePayload -EventName $EventName -Data $Data
    $dead  = New-Object 'System.Collections.Generic.List[hashtable]'
    foreach ($sub in @($Run.subscribers)) {
        try { $sub.stream.Write($bytes, 0, $bytes.Length); $sub.stream.Flush() }
        catch { [void]$dead.Add($sub) }
    }
    foreach ($d in $dead) {
        [void]$Run.subscribers.Remove($d)
        try { $d.context.Response.OutputStream.Close() } catch { }
        try { $d.context.Response.Close() } catch { }
    }
}

function Close-RunSseSubscribers {
    param([hashtable]$Run)
    $bytes = ConvertTo-SsePayload -EventName 'end' -Data @{ status = $Run.status; endedAt = $Run.endedAt }
    foreach ($sub in @($Run.subscribers)) {
        try { $sub.stream.Write($bytes, 0, $bytes.Length); $sub.stream.Flush() } catch { }
        try { $sub.context.Response.OutputStream.Close() } catch { }
        try { $sub.context.Response.Close() } catch { }
    }
    $Run.subscribers.Clear()
    # Log workflow run completion to history (Hub-History.ps1 must be loaded).
    try { Write-WorkflowRunHistory -Run $Run } catch { }
}

function Resolve-StepParams {
    # Substitutes {{step-N.stdout.all}}, {{step-N.stdout}}, {{step-N.exitCode}} in param values.
    # Keys that resolve to empty string are dropped; Build-Argv enforces required-param presence.
    #
    # ADV-301 (CRITICAL): a "secret-bearing" step (one that resolved >=1 @secret: value) may
    # echo its secret to stdout. Substituting {{step-N.stdout(.all)}} for such a step would
    # land the secret on the DOWNSTREAM step's argv (visible via Win32_Process.CommandLine),
    # defeating stdin injection. So for any sid present in $SecretSteps, stdout/.stdout.all
    # refs are dropped to '' (the .exitCode ref stays — it is not sensitive).
    param([hashtable]$Params, [hashtable]$StepOutputs, [hashtable]$SecretSteps = @{})
    if ($null -eq $Params) { return @{} }
    $out = @{}
    foreach ($key in @($Params.Keys)) {
        $val = [string]$Params[$key]
        foreach ($sid in @($StepOutputs.Keys)) {
            $o = $StepOutputs[$sid]
            $isSecretStep = ($SecretSteps -and $SecretSteps.ContainsKey([string]$sid))
            if ($isSecretStep) {
                $soAll = ''
                $so    = ''
            } else {
                $soAll = $o.stdoutAll
                $so    = $o.stdout
            }
            # Replace .stdout.all before .stdout to avoid prefix-match clobbering.
            $val = $val -replace [regex]::Escape("{{step-$sid.stdout.all}}"), $soAll
            $val = $val -replace [regex]::Escape("{{step-$sid.stdout}}"),     $so
            $val = $val -replace [regex]::Escape("{{step-$sid.exitCode}}"),   [string]$o.exitCode
        }
        if ($val -ne '') { $out[$key] = $val }
    }
    return $out
}

function Start-HubWorkflow {
    [OutputType([string])]
    param([hashtable]$Workflow)
    $runId = New-WorkflowRunId
    $steps = @($Workflow.steps)

    # ADV-011: validate all step scriptIds at run start and cache resolved items in pathMap.
    $catalog = (Get-HubItems).items
    $pathMap = @{}
    foreach ($step in $steps) {
        $sid     = [string]$step['scriptId']
        $sidNorm = $sid -replace '/', '\'
        $item    = $catalog | Where-Object { ([string]$_.path -replace '/', '\') -ieq $sidNorm } | Select-Object -First 1
        if (-not $item) { throw "Step '$($step['id'])' scriptId '$sid' not found in catalog" }
        $pathMap[$step['id']] = $item
    }

    $firstStep   = $steps[0]
    $firstItem   = $pathMap[$firstStep['id']]
    $schema      = Get-ParamSchema -ScriptPath $firstItem.path
    $secretSteps = @{}
    $vals1       = Resolve-StepParams -Params $firstStep['params'] -StepOutputs @{} -SecretSteps $secretSteps
    # Phase 3: resolve @secret: refs for this step (stdin injection); track secret-bearing.
    $sec1        = Resolve-RunSecrets -Schema $schema -Values $vals1
    if (-not $sec1.ok) { throw "Step '$($firstStep['id'])' secret error: $($sec1.error)" }
    if ($sec1.secrets.Count -gt 0) { $secretSteps[[string]$firstStep['id']] = $true }
    $argv        = Build-Argv -Schema $schema -Values $vals1
    $jobId       = Start-HubJob -ItemPath $firstItem.path -Kind $firstItem.kind -Argv $argv -ItemId $firstItem.id -WorkflowRunId $runId -Secrets $sec1.secrets

    $run = @{
        runId         = $runId
        workflowId    = $Workflow.id
        status        = 'running'
        currentStepId = $firstStep['id']
        stepOutputs   = @{}
        secretSteps   = $secretSteps
        childJobIds   = New-Object 'System.Collections.Generic.List[string]'
        currentJobId  = $jobId
        pathMap       = $pathMap
        startedAt     = (Get-Date).ToString('o')
        endedAt       = $null
        subscribers   = New-Object 'System.Collections.Generic.List[hashtable]'
    }
    [void]$run.childJobIds.Add($jobId)
    $Script:WorkflowRuns[$runId] = $run
    Save-WorkflowRun -Run $run
    return $runId
}

function Advance-WorkflowRuns {
    if (-not $Script:WorkflowRuns -or $Script:WorkflowRuns.Count -eq 0) { return }
    foreach ($runId in @($Script:WorkflowRuns.Keys)) {
        $run = $Script:WorkflowRuns[$runId]
        if ($null -eq $run -or $run.status -ne 'running') { continue }
        try {
            $job = $Script:Jobs[$run.currentJobId]
            if (-not $job -or $job.status -notin @('done','failed','killed')) { continue }

            # Capture current step outputs.
            $sid         = $run.currentStepId
            $stdoutLines = @($job.buffer | Where-Object { $_.stream -eq 'out' } | ForEach-Object { $_.line })
            $lastNE      = ($stdoutLines | Where-Object { $_.Trim() -ne '' } | Select-Object -Last 1)
            # Hardening (rune:adversary PROCEED, 2026-05-30): a secret-bearing step may echo its
            # own secret to stdout. This capture site is the ONLY place step stdout is written to
            # the run object, which Save-WorkflowRun persists to workflow-runs/*.json. So for a
            # secret-bearing step, store NO captured stdout (exitCode retained — routing needs it,
            # ADV-H2). The echoed secret can still appear LIVE in the in-memory child job buffer
            # (transient, swept after TTL), but never AT REST (ADV-H1). Full-stdout redaction, not
            # substring matching (substring matching is bypassable via encoding/splitting).
            $isSecretStep = ($run.ContainsKey('secretSteps') -and $run.secretSteps -and $run.secretSteps.ContainsKey([string]$sid))
            if ($isSecretStep) {
                $run.stepOutputs[$sid] = @{ stdout = ''; stdoutAll = ''; stdoutRedacted = $true; exitCode = $job.exitCode }
            } else {
                $run.stepOutputs[$sid] = @{
                    stdout    = if ($lastNE) { $lastNE } else { '' }
                    stdoutAll = ($stdoutLines -join "`n")
                    exitCode  = $job.exitCode
                }
            }
            Send-RunSseFrame -Run $run -EventName 'step-end' -Data @{
                stepId = $sid; exitCode = $job.exitCode; status = $job.status
            }

            # Resolve next step via onSuccess / onFailure.
            $wf = $Script:Workflows[$run.workflowId]
            if (-not $wf) {
                $run.status = 'failed'; $run.endedAt = (Get-Date).ToString('o')
                Save-WorkflowRun -Run $run; Close-RunSseSubscribers -Run $run; continue
            }
            $steps  = @($wf.steps)
            $curIdx = -1
            for ($i = 0; $i -lt $steps.Count; $i++) { if ($steps[$i]['id'] -eq $sid) { $curIdx = $i; break } }

            $rf     = if ($job.status -eq 'done') { 'onSuccess' } else { 'onFailure' }
            $step   = $steps[$curIdx]
            $target = if ($step.ContainsKey($rf)) { [string]$step[$rf] } else { 'next' }
            if ($target -eq 'stop') { $target = $null }
            if ($target -eq 'next') {
                $target = if ($curIdx + 1 -lt $steps.Count) { [string]$steps[$curIdx + 1]['id'] } else { $null }
            }

            if (-not $target) {
                $run.status  = if ($job.status -eq 'done') { 'done' } else { 'failed' }
                $run.endedAt = (Get-Date).ToString('o')
                Save-WorkflowRun -Run $run; Close-RunSseSubscribers -Run $run; continue
            }

            $nextStep = $steps | Where-Object { $_['id'] -eq $target } | Select-Object -First 1
            $nextItem = $run.pathMap[$target]
            if (-not $nextStep -or -not $nextItem) {
                $run.status = 'failed'; $run.endedAt = (Get-Date).ToString('o')
                Save-WorkflowRun -Run $run; Close-RunSseSubscribers -Run $run; continue
            }

            $schema2 = Get-ParamSchema -ScriptPath $nextItem.path
            if (-not $run.ContainsKey('secretSteps') -or $null -eq $run.secretSteps) { $run.secretSteps = @{} }
            # ADV-301: pass secret-bearing set so an upstream secret-bearing step's stdout
            # refs are dropped before they can reach this step's argv.
            $vals2   = Resolve-StepParams -Params $nextStep['params'] -StepOutputs $run.stepOutputs -SecretSteps $run.secretSteps
            $sec2    = Resolve-RunSecrets -Schema $schema2 -Values $vals2
            if (-not $sec2.ok) {
                $run.status = 'failed'; $run.endedAt = (Get-Date).ToString('o')
                Save-WorkflowRun -Run $run; Close-RunSseSubscribers -Run $run; continue
            }
            if ($sec2.secrets.Count -gt 0) { $run.secretSteps[[string]$target] = $true }
            $argv2   = Build-Argv -Schema $schema2 -Values $vals2
            $jobId2  = Start-HubJob -ItemPath $nextItem.path -Kind $nextItem.kind -Argv $argv2 -ItemId $nextItem.id -WorkflowRunId $runId -Secrets $sec2.secrets
            $run.currentStepId = $target
            $run.currentJobId  = $jobId2
            [void]$run.childJobIds.Add($jobId2)
            Save-WorkflowRun -Run $run

            $nextIdx = -1
            for ($i = 0; $i -lt $steps.Count; $i++) { if ($steps[$i]['id'] -eq $target) { $nextIdx = $i; break } }
            Send-RunSseFrame -Run $run -EventName 'step-start' -Data @{
                stepId = $target; stepIndex = $nextIdx; totalSteps = $steps.Count
            }
        } catch {
            Write-HubError $_
            $run.status  = 'failed'
            $run.endedAt = (Get-Date).ToString('o')
            try { Save-WorkflowRun -Run $run } catch { }
            try { Close-RunSseSubscribers -Run $run } catch { }
        }
    }
}

function Invoke-WorkflowRunTriggerRoute {
    param([System.Net.HttpListenerContext]$Context, [string]$WorkflowId)
    if ($Context.Request.HttpMethod -ne 'POST') {
        Write-JsonResponse -Context $Context -Status 405 -Body @{ error = 'method-not-allowed' }; return
    }
    if (-not $Script:Workflows.ContainsKey($WorkflowId)) {
        Write-JsonResponse -Context $Context -Status 404 -Body @{ error = 'not-found' }; return
    }
    $runId = $null
    try { $runId = Start-HubWorkflow -Workflow $Script:Workflows[$WorkflowId] }
    catch {
        Write-HubError $_
        Write-JsonResponse -Context $Context -Status 500 -Body @{ error = 'spawn-failed'; detail = $_.Exception.Message }
        return
    }
    Write-JsonResponse -Context $Context -Status 202 -Body @{ runId = $runId }
}

function Invoke-WorkflowRunRoute {
    [OutputType([bool])]
    param([System.Net.HttpListenerContext]$Context, [string]$RunId)
    if ($Context.Request.HttpMethod -ne 'GET') {
        Write-JsonResponse -Context $Context -Status 405 -Body @{ error = 'method-not-allowed' }; return $true
    }
    if (-not $Script:WorkflowRuns.ContainsKey($RunId)) {
        Write-JsonResponse -Context $Context -Status 404 -Body @{ error = 'not-found' }; return $true
    }
    $run  = $Script:WorkflowRuns[$RunId]
    $safe = @{}
    foreach ($k in @($run.Keys)) {
        if ($k -notin @('subscribers', 'pathMap')) { $safe[$k] = $run[$k] }
    }
    Write-JsonResponse -Context $Context -Status 200 -Body $safe
    return $true
}

function Invoke-WorkflowRunStreamRoute {
    [OutputType([bool])]
    param([System.Net.HttpListenerContext]$Context, [string]$RunId)
    if ($Context.Request.HttpMethod -ne 'GET') {
        Write-JsonResponse -Context $Context -Status 405 -Body @{ error = 'method-not-allowed' }; return $true
    }
    if (-not $Script:WorkflowRuns.ContainsKey($RunId)) {
        Write-JsonResponse -Context $Context -Status 404 -Body @{ error = 'not-found' }; return $true
    }
    $run  = $Script:WorkflowRuns[$RunId]
    $resp = $Context.Response
    $resp.StatusCode                   = 200
    $resp.ContentType                  = 'text/event-stream; charset=utf-8'
    $resp.Headers['Cache-Control']     = 'no-cache'
    $resp.Headers['X-Accel-Buffering'] = 'no'
    $resp.SendChunked = $true
    $stream = $resp.OutputStream
    # Completed run: send terminal 'end' event immediately and close.
    if ($run.status -notin @('running')) {
        try {
            $bytes = ConvertTo-SsePayload -EventName 'end' -Data @{ status = $run.status; endedAt = $run.endedAt }
            $stream.Write($bytes, 0, $bytes.Length); $stream.Flush()
        } catch { }
        return $true
    }
    [void]$run.subscribers.Add(@{ context = $Context; stream = $stream })
    return $false
}

function Invoke-WorkflowRunKillRoute {
    param([System.Net.HttpListenerContext]$Context, [string]$RunId)
    if ($Context.Request.HttpMethod -ne 'POST') {
        Write-JsonResponse -Context $Context -Status 405 -Body @{ error = 'method-not-allowed' }; return
    }
    if (-not $Script:WorkflowRuns.ContainsKey($RunId)) {
        Write-JsonResponse -Context $Context -Status 404 -Body @{ error = 'not-found' }; return
    }
    $run = $Script:WorkflowRuns[$RunId]
    if ($run.status -ne 'running') {
        Write-JsonResponse -Context $Context -Status 200 -Body @{ ok = $true; status = $run.status }; return
    }
    $run.status  = 'killed'
    $run.endedAt = (Get-Date).ToString('o')
    if ($run.currentJobId) {
        $job = $Script:Jobs[$run.currentJobId]
        if ($job -and $job.status -eq 'running' -and $job.pid) {
            $job.status = 'killed'
            try { Stop-JobTree -ProcessId $job.pid } catch { }
        }
    }
    Save-WorkflowRun -Run $run
    Close-RunSseSubscribers -Run $run
    Write-JsonResponse -Context $Context -Status 200 -Body @{ ok = $true }
}
