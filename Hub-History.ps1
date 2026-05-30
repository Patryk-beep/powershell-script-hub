# Hub-History.ps1 — Run history logger and rotation (Phase 6).
# Dot-sourced by Hub.ps1 after all $Script: globals are set.
#
# History scope: workflow steps are logged individually (workflowRunId set) plus
# a workflow-level summary entry. Single script runs get one entry.
# Max 500 entries retained (configurable via $Script:HistoryMaxEntries).
# JSON-lines format, one entry per line, rotation is atomic (temp-file swap).

$Script:HistoryMaxEntries = 500

function Get-HistoryDir {
    [OutputType([string])]
    param()
    $d = Join-Path $Script:ConfigDir 'history'
    if (-not [System.IO.Directory]::Exists($d)) {
        try { [System.IO.Directory]::CreateDirectory($d) | Out-Null } catch { Write-HubError $_ }
    }
    return $d
}

function Get-HistoryFilePath {
    [OutputType([string])]
    param()
    return Join-Path (Get-HistoryDir) 'runs.jsonl'
}

function Initialize-History {
    [void](Get-HistoryDir)
}

function Write-HubHistory {
    param([hashtable]$Job, [string]$WorkflowRunId = $null, [string]$WorkflowId = $null)
    if (-not $Job) { return }
    $entry = @{
        ts            = if ($Job.endedAt) { $Job.endedAt.ToString('o') } else { (Get-Date).ToString('o') }
        itemId        = [string]$Job.itemId
        exitCode      = $Job.exitCode
        status        = [string]$Job.status
        durationMs    = if ($Job.endedAt -and $Job.startedAt) { [int]($Job.endedAt - $Job.startedAt).TotalMilliseconds } else { 0 }
        workflowRunId = $WorkflowRunId
        workflowId    = $WorkflowId
    }
    try {
        $line  = $entry | ConvertTo-Json -Depth 3 -Compress
        $path  = Get-HistoryFilePath
        [System.IO.File]::AppendAllText($path, $line + "`n", [System.Text.UTF8Encoding]::new($false))
        Invoke-HistoryRotation -Path $path
    } catch { Write-HubError $_ }
}

function Write-WorkflowRunHistory {
    param([hashtable]$Run)
    if (-not $Run) { return }
    $entry = @{
        ts            = if ($Run.endedAt) { $Run.endedAt } else { (Get-Date).ToString('o') }
        workflowId    = [string]$Run.workflowId
        workflowRunId = [string]$Run.runId
        status        = [string]$Run.status
        durationMs    = 0
        itemId        = $null
        exitCode      = $null
    }
    if ($Run.startedAt -and $Run.endedAt) {
        try {
            $st = [datetime]::Parse($Run.startedAt, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
            $en = [datetime]::Parse($Run.endedAt,   $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
            $entry['durationMs'] = [int]($en - $st).TotalMilliseconds
        } catch { }
    }
    try {
        $line = $entry | ConvertTo-Json -Depth 3 -Compress
        $path = Get-HistoryFilePath
        [System.IO.File]::AppendAllText($path, $line + "`n", [System.Text.UTF8Encoding]::new($false))
        Invoke-HistoryRotation -Path $path
    } catch { Write-HubError $_ }
}

function Invoke-HistoryRotation {
    param([string]$Path)
    if (-not [System.IO.File]::Exists($Path)) { return }
    $lines = [System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8)
    if ($lines.Count -le $Script:HistoryMaxEntries) { return }
    # Keep last N entries, write atomically.
    $kept = $lines[($lines.Count - $Script:HistoryMaxEntries)..($lines.Count - 1)]
    $tmp  = $Path + '.tmp'
    try {
        [System.IO.File]::WriteAllLines($tmp, $kept, [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::Delete($Path)
        [System.IO.File]::Move($tmp, $Path)
    } catch {
        Write-HubError $_
        try { if ([System.IO.File]::Exists($tmp)) { [System.IO.File]::Delete($tmp) } } catch { }
    }
}

function Read-HubHistory {
    [OutputType([object[]])]
    param(
        [int]$Limit  = 50,
        [int]$Offset = 0,
        [string]$Status    = '',
        [string]$WorkflowId = ''
    )
    $path = Get-HistoryFilePath
    # Fresh install / no history yet: return the SAME shape as the populated path so
    # clients (and the History tab) always get {entries,total,...} — never a bare null.
    # (A bare @() here serializes to JSON `null` via Write-JsonResponse's pipeline.)
    if (-not [System.IO.File]::Exists($path)) {
        return @{ entries = @(); total = 0; limit = $Limit; offset = $Offset }
    }
    $lines = [System.IO.File]::ReadAllLines($path, [System.Text.Encoding]::UTF8)
    # Reverse (newest first).
    [System.Array]::Reverse($lines)
    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $e = $line | ConvertFrom-Json
            if ($Status     -and $e.status     -ne $Status)     { continue }
            if ($WorkflowId -and $e.workflowId -ne $WorkflowId) { continue }
            $results.Add($e)
        } catch { continue }
    }
    $total  = $results.Count
    $paged  = if ($Offset -lt $total) { $results[$Offset..([Math]::Min($Offset + $Limit - 1, $total - 1))] } else { @() }
    return @{ entries = @($paged); total = $total; limit = $Limit; offset = $Offset }
}

function Get-HistoryCsv {
    [OutputType([string])]
    param([object[]]$Entries)
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('ts,itemId,workflowRunId,workflowId,status,exitCode,durationMs')
    foreach ($e in $Entries) {
        $row = @(
            [string]$e.ts, [string]$e.itemId, [string]$e.workflowRunId,
            [string]$e.workflowId, [string]$e.status, [string]$e.exitCode, [string]$e.durationMs
        ) | ForEach-Object { '"' + ($_ -replace '"', '""') + '"' }
        [void]$sb.AppendLine($row -join ',')
    }
    return $sb.ToString()
}

function Invoke-HistoryRoute {
    param([System.Net.HttpListenerContext]$Context)
    if ($Context.Request.HttpMethod -ne 'GET') {
        Write-JsonResponse -Context $Context -Status 405 -Body @{ error = 'method-not-allowed' }
        return
    }
    $qs         = $Context.Request.QueryString
    # PS5.1-compatible: '??' (null-coalescing) is PS7-only and a PARSE error under the
    # PS2EXE/PS5.1 runtime — which silently breaks dot-sourcing this whole module.
    $rawLimit   = $qs['limit']
    $limit      = if ($rawLimit)  { [int]$rawLimit }  else { 50 }; if ($limit -le 0 -or $limit -gt 500) { $limit = 50 }
    $rawOffset  = $qs['offset']
    $offset     = if ($rawOffset) { [int]$rawOffset } else { 0 };  if ($offset -lt 0) { $offset = 0 }
    $status     = [string]$qs['status']
    $wfId       = [string]$qs['workflowId']
    $csv        = $qs['format'] -eq 'csv'

    $result = Read-HubHistory -Limit $limit -Offset $offset -Status $status -WorkflowId $wfId

    if ($csv) {
        $csvData = Get-HistoryCsv -Entries $result.entries
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($csvData)
        $Context.Response.StatusCode      = 200
        $Context.Response.ContentType     = 'text/csv; charset=utf-8'
        $Context.Response.ContentLength64 = $bytes.LongLength
        $Context.Response.Headers['Content-Disposition'] = 'attachment; filename="hub-history.csv"'
        $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
        return
    }
    Write-JsonResponse -Context $Context -Status 200 -Body $result
}
