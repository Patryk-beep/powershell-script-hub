# Fixture for Phase 3 schema introspection.
# Mixed param types — every supported widget mapping plus Mandatory + ValidateSet.

param(
    [Parameter(Mandatory, HelpMessage='UPN of the user to look up')]
    [string]$UserPrincipalName,

    [Parameter()]
    [string]$Name = 'default-name',

    [int]$Count = 5,

    [switch]$Force,

    [bool]$Quiet = $false,

    [ValidateSet('A', 'B', 'C')]
    [string]$Mode = 'A'
)

# Side-effect sentinel — if this file is ever EXECUTED (not just parsed),
# the sentinel file appears. The Phase 3 test verifies it does NOT appear
# after schema fetch, proving introspection is AST-only.
$sentinel = Join-Path $env:TEMP 'hub-fixture-executed.flag'
"executed $(Get-Date -Format o) UPN=$UserPrincipalName" | Out-File -FilePath $sentinel -Encoding utf8

Write-Host "EXECUTED: UPN=$UserPrincipalName Name=$Name Count=$Count Force=$Force Mode=$Mode"
