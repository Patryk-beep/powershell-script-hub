# Should NOT hang under Hub because Hub passes -NonInteractive + closes stdin.
# Read-Host under -NonInteractive throws PSInvalidOperationException → process exits with error.
param()
try {
    $name = Read-Host 'name'
    Write-Host "hi $name"
} catch {
    Write-Host "read-host blocked: $($_.Exception.GetType().Name)"
    exit 2
}
