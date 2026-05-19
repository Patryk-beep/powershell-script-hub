# Echoes raw $args verbatim — used by Phase 4 to verify there's no shell
# interpretation of metacharacters like `;`, `|`, `&`.
param()
if ($args.Count -eq 0) {
    Write-Host '(no args)'
} else {
    foreach ($a in $args) { Write-Host "arg: $a" }
}
