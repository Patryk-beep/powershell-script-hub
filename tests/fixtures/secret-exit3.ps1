# Phase 3 fixture (ADV-302): a secret run that exits non-zero. Proves the stdin shim's
# 'exit $LASTEXITCODE' propagates the target's exit code (else secret runs always report 0).
param(
    [securestring]$Password
)
Write-Host 'about-to-exit-3'
exit 3
