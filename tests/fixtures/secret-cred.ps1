# Phase 3 fixture: proves a [pscredential] param was bound (kind=credential). Emits the
# username (not secret) + SHA256 of the password. Never echoes the password plaintext.
param(
    [pscredential]$Cred
)
$plain = $Cred.GetNetworkCredential().Password
$sha   = [System.Security.Cryptography.SHA256]::Create()
$hex   = [System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($plain))).Replace('-', '')
$sha.Dispose()
# Proof to file (hash only) — captured stdout is redacted for this secret-bearing step.
$proof = Join-Path $env:LOCALAPPDATA 'Hub\secret-proof.txt'
try { Add-Content -Path $proof -Value "cred user=$($Cred.UserName) hash=$hex" -Encoding UTF8 } catch { }
Write-Host "user=$($Cred.UserName) hash=$hex"
