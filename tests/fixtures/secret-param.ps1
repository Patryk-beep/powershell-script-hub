# Fixture for Phase 2 secret-redaction tests (ADV-201).
# Three params: a typed SecureString (widget=password), a plain [string] whose NAME
# matches the secret heuristic (ApiKey), and a benign [string] that MUST survive.
param(
    [securestring]$Password,
    [string]$ApiKey,
    [string]$Path = 'C:\data'
)
Write-Host "path=$Path apikey-len=$($ApiKey.Length)"
