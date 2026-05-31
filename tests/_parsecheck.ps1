param([string[]]$Files)
$bad = $false
foreach ($f in $Files) {
    $errs = $null
    $tokens = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$tokens, [ref]$errs)
    if ($errs -and $errs.Count -gt 0) {
        $bad = $true
        Write-Host "PARSE-FAIL: $f"
        foreach ($e in $errs) { Write-Host ("  L{0}: {1}" -f $e.Extent.StartLineNumber, $e.Message) }
    } else {
        Write-Host "PARSE-OK: $f"
    }
}
if ($bad) { exit 1 } else { exit 0 }
