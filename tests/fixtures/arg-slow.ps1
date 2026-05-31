# Phase 3 fixture (ADV-301 step 2): a downstream step that takes a plain [string] (typically
# bound to {{step-1.stdout}}) and sleeps so the test can enumerate its command line. If
# ADV-301 works, $Text is empty (the secret-bearing step's stdout ref was dropped).
param(
    [string]$Text = '',
    [int]$SleepSeconds = 3
)
Start-Sleep -Seconds $SleepSeconds
Write-Host "got=$Text"
