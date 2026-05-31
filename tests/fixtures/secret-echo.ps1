# Phase 3 fixture (ADV-301 step 1): a user script that ECHOES its secret to stdout. This
# models the accepted echo-back limitation. ADV-301 must ensure this echoed value can never
# reach a DOWNSTREAM workflow step's argv (Resolve-StepParams drops secret-bearing stdout refs).
param(
    [securestring]$Password
)
$plain = ConvertFrom-SecureString -SecureString $Password -AsPlainText
Write-Host $plain
