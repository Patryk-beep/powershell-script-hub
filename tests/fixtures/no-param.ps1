# Fixture for raw-mode fallback test — uses $args, no param() block.
# Schema endpoint should return mode='raw'.

if ($args.Count -gt 0) {
    Write-Host "args: $($args -join ', ')"
} else {
    Write-Host "no args"
}
