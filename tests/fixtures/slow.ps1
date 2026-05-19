param([int]$Count = 30, [int]$DelayMs = 500)
1..$Count | ForEach-Object {
    Start-Sleep -Milliseconds $DelayMs
    Write-Host "tick $_"
}
