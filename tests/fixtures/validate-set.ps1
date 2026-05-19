param(
    [ValidateSet('alpha', 'beta', 'gamma')]
    [string]$Choice = 'alpha'
)
Write-Host "choice: $Choice"
