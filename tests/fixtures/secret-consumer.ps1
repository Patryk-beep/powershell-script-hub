# Phase 3 fixture: proves a [securestring] param was bound to the REAL secret value
# WITHOUT ever echoing the plaintext. Emits SHA256(value) + $PSCommandPath (ADV-305 parity).
param(
    [securestring]$Password
)
$plain = ConvertFrom-SecureString -SecureString $Password -AsPlainText
$sha   = [System.Security.Cryptography.SHA256]::Create()
$hex   = [System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($plain))).Replace('-', '')
$sha.Dispose()
# Write the binding PROOF (a one-way hash, never the plaintext) to a file as well as stdout.
# As a secret-bearing step, this script's captured stdout is redacted in the persisted run
# record, so the test reads the file to confirm the child received the real value.
$proof = Join-Path $env:LOCALAPPDATA 'Hub\secret-proof.txt'
try { Add-Content -Path $proof -Value "consumer hash=$hex" -Encoding UTF8 } catch { }
Write-Host "hash=$hex"
Write-Host "pscommandpath=$PSCommandPath"
