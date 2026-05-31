# Phase 3 fixture: like secret-consumer but sleeps so the no-argv-leak test has a window
# to enumerate Win32_Process.CommandLine while the child is alive. Never echoes plaintext.
param(
    [securestring]$Password,
    [int]$SleepSeconds = 3
)
Start-Sleep -Seconds $SleepSeconds
$plain = ConvertFrom-SecureString -SecureString $Password -AsPlainText
$sha   = [System.Security.Cryptography.SHA256]::Create()
$hex   = [System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($plain))).Replace('-', '')
$sha.Dispose()
Write-Host "hash=$hex"
