<#
.SYNOPSIS
UTF-8 without BOM regression — contains non-ASCII glyphs that PS5 mis-decodes if not read as UTF-8.
.PARAMETER UPN
User principal name to lookup.
#>
param(
    [Parameter(Mandatory)]
    [string]$UPN,
    [switch]$Verbose
)

# Decorative status markers below — these are the chars that break PS5 default-codepage parsing:
# ✓ check mark (U+2713)  ✗ cross mark (U+2717)
$ok  = "✓ OK"
$bad = "✗ FAIL"

Write-Output ("UPN: " + $UPN)
Write-Output $ok
Write-Output $bad
