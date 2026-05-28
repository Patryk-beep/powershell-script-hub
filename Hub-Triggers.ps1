# Hub-Triggers.ps1 — Cron scheduler and file-watch triggers (Phase 4).
# Dot-sourced by Hub.ps1 after all $Script: globals are set.
#
# Cron semantics: dom AND dow must both match (AND, not OR). Simpler and
# correct for typical expressions that use only one of the two fields.
# File-watch uses mtime polling (no Register-ObjectEvent) — safe in STA host.

$Script:TriggerStates       = [hashtable]::Synchronized(@{})
$Script:LastTriggerCheckAt  = (Get-Date).AddSeconds(-70)  # force first check soon

function Get-TriggerStateDir {
    [OutputType([string])]
    param()
    $d = Join-Path $Script:ConfigDir 'trigger-states'
    if (-not [System.IO.Directory]::Exists($d)) {
        try { [System.IO.Directory]::CreateDirectory($d) | Out-Null } catch { Write-HubError $_ }
    }
    return $d
}

function Save-TriggerState {
    param([string]$WorkflowId, [hashtable]$State)
    $dir  = Get-TriggerStateDir
    $path = Join-Path $dir "$WorkflowId.state.json"
    $tmp  = $path + '.tmp'
    try {
        $json = $State | ConvertTo-Json -Depth 3 -Compress
        [System.IO.File]::WriteAllText($tmp, $json, [System.Text.UTF8Encoding]::new($false))
        if ([System.IO.File]::Exists($path)) { [System.IO.File]::Delete($path) }
        [System.IO.File]::Move($tmp, $path)
        $Script:TriggerStates[$WorkflowId] = $State
    } catch {
        Write-HubError $_
        try { if ([System.IO.File]::Exists($tmp)) { [System.IO.File]::Delete($tmp) } } catch { }
    }
}

function Initialize-TriggerStates {
    $dir = Get-TriggerStateDir
    foreach ($file in [System.IO.Directory]::EnumerateFiles($dir, '*.state.json')) {
        try {
            $raw = [System.IO.File]::ReadAllText($file, [System.Text.Encoding]::UTF8)
            $state = ConvertFrom-JsonHashtable ($raw | ConvertFrom-Json)
            $wfId  = [System.IO.Path]::GetFileNameWithoutExtension($file) -replace '\.state$', ''
            if ($state -and $wfId) { $Script:TriggerStates[$wfId] = $state }
        } catch { Write-HubError $_ }
    }
}

function Test-TriggerSpec {
    # Returns error string or $null if valid. Called from Test-WorkflowSchema.
    [OutputType([string])]
    param([hashtable]$Trigger)
    $type = [string]$Trigger['type']
    if (-not $type -or $type -eq 'manual') { return $null }
    if ($type -eq 'cron') {
        $expr = [string]$Trigger['expression']
        if ([string]::IsNullOrWhiteSpace($expr)) { return "trigger: cron expression is required" }
        $parts = $expr.Trim() -split '\s+'
        if ($parts.Count -ne 5) { return "trigger: cron expression must have 5 fields (got $($parts.Count))" }
        return $null
    }
    if ($type -eq 'file-watch') {
        $path = [string]$Trigger['path']
        if ([string]::IsNullOrWhiteSpace($path)) { return "trigger: file-watch path is required" }
        if ($path.StartsWith('\\')) { return "trigger: file-watch path must not be a UNC path" }
        return $null
    }
    return "trigger: unknown type '$type' (allowed: manual, cron, file-watch)"
}

function Test-CronField {
    [OutputType([bool])]
    param([int]$Value, [string]$Spec, [int]$Min)
    if ($Spec -eq '*') { return $true }
    foreach ($part in ($Spec -split ',')) {
        $p = $part.Trim()
        if ($p -match '^\*/(\d+)$') {
            if ([int]$Matches[1] -gt 0 -and ($Value - $Min) % [int]$Matches[1] -eq 0) { return $true }
        } elseif ($p -match '^(\d+)-(\d+)$') {
            if ($Value -ge [int]$Matches[1] -and $Value -le [int]$Matches[2]) { return $true }
        } elseif ($p -match '^\d+$') {
            if ($Value -eq [int]$p) { return $true }
        }
    }
    return $false
}

function Test-CronMatch {
    [OutputType([bool])]
    param([datetime]$Dt, [string[]]$Fields)
    # Fields: [minute, hour, dom, month, dow]  (0-indexed)
    if (-not (Test-CronField -Value $Dt.Minute -Spec $Fields[0] -Min 0)) { return $false }
    if (-not (Test-CronField -Value $Dt.Hour   -Spec $Fields[1] -Min 0)) { return $false }
    if (-not (Test-CronField -Value $Dt.Day    -Spec $Fields[2] -Min 1)) { return $false }
    if (-not (Test-CronField -Value $Dt.Month  -Spec $Fields[3] -Min 1)) { return $false }
    # DayOfWeek: 0=Sunday. Support both 0 and 7 as Sunday.
    $dow = [int]$Dt.DayOfWeek
    $dowMatch = (Test-CronField -Value $dow -Spec $Fields[4] -Min 0) -or
                ($dow -eq 0 -and (Test-CronField -Value 7 -Spec $Fields[4] -Min 0))
    return $dowMatch
}

function Get-NextCronTime {
    [OutputType([nullable[datetime]])]
    param([datetime]$From, [string[]]$Fields)
    # Start 1 minute after From, floor to the minute.
    $t = $From.AddMinutes(1)
    $t = $t.AddSeconds(-$t.Second).AddMilliseconds(-$t.Millisecond)
    $limit = $From.AddYears(1)
    while ($t -lt $limit) {
        if (Test-CronMatch -Dt $t -Fields $Fields) { return $t }
        $t = $t.AddMinutes(1)
    }
    return $null
}

function Advance-TriggerSchedules {
    # Called from Step-Jobs every ~60s to fire due cron/file-watch triggers.
    $now = Get-Date
    if (($now - $Script:LastTriggerCheckAt).TotalSeconds -lt 55) { return }
    $Script:LastTriggerCheckAt = $now

    foreach ($wfId in @($Script:Workflows.Keys)) {
        $wf = $Script:Workflows[$wfId]
        if (-not $wf) { continue }
        $trigger = $wf['trigger']
        if (-not $trigger) { continue }
        $type = [string]$trigger['type']

        try {
            if ($type -eq 'cron') {
                $expr   = [string]$trigger['expression']
                $parts  = $expr.Trim() -split '\s+'
                if ($parts.Count -ne 5) { continue }
                $state  = if ($Script:TriggerStates.ContainsKey($wfId)) { $Script:TriggerStates[$wfId] } else { @{} }
                $nextAt = if ($state.ContainsKey('nextRunAt') -and $state['nextRunAt']) {
                    [datetime]::Parse($state['nextRunAt'], $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
                } else {
                    # First run: compute next from now.
                    $next = Get-NextCronTime -From $now -Fields $parts
                    if (-not $next) { continue }
                    $newState = @{ lastRunAt = $null; nextRunAt = $next.ToString('o') }
                    Save-TriggerState -WorkflowId $wfId -State $newState
                    continue
                }
                if ($now -lt $nextAt) { continue }
                # Due — fire and advance.
                Start-HubWorkflow -Workflow $wf | Out-Null
                $next2 = Get-NextCronTime -From $now -Fields $parts
                Save-TriggerState -WorkflowId $wfId -State @{
                    lastRunAt = $now.ToString('o')
                    nextRunAt = if ($next2) { $next2.ToString('o') } else { $null }
                }

            } elseif ($type -eq 'file-watch') {
                $watchPath = [string]$trigger['path']
                if ([string]::IsNullOrWhiteSpace($watchPath) -or -not [System.IO.Directory]::Exists($watchPath)) { continue }
                $state    = if ($Script:TriggerStates.ContainsKey($wfId)) { $Script:TriggerStates[$wfId] } else { @{} }
                $lastMt   = if ($state.ContainsKey('lastMtime') -and $state['lastMtime']) {
                    [datetime]::Parse($state['lastMtime'], $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
                } else {
                    # Seed with current mtime so first poll doesn't immediately fire.
                    $mt = [System.IO.Directory]::GetLastWriteTimeUtc($watchPath)
                    Save-TriggerState -WorkflowId $wfId -State @{ lastMtime = $mt.ToString('o') }
                    continue
                }
                $curMt = [System.IO.Directory]::GetLastWriteTimeUtc($watchPath)
                if ($curMt -le $lastMt) { continue }
                # Directory changed — apply 5s debounce by checking if the mtime is older than 5s.
                if (($now.ToUniversalTime() - $curMt).TotalSeconds -lt 5) { continue }
                Start-HubWorkflow -Workflow $wf | Out-Null
                Save-TriggerState -WorkflowId $wfId -State @{ lastMtime = $curMt.ToString('o') }
            }
        } catch { Write-HubError $_ }
    }
}
