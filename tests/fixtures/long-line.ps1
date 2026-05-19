param([int]$Length = 100000)
# Emit a single very long line — Hub's per-line cap should truncate at 4 KB
# with a `[...truncated]` marker.
$big = 'x' * $Length
Write-Host $big
