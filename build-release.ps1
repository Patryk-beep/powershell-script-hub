#Requires -Version 5.1
<#
.SYNOPSIS
    Build the release zip and (optionally) cut the GitHub release.

.DESCRIPTION
    Pipeline:
      1. Run build-hub.ps1 -Version $Version (rebuilds Hub.exe)
      2. Stage Hub.exe + Hub.ico + README.md + wwwroot\ into build\release\Hub\
      3. Zip staging dir -> build\Hub.zip   (deterministic asset bundle)
      4. SHA256 the zip + patch the hex into install-hub.ps1's
         $Script:ExpectedZipHash placeholder
      5. (With -Publish) git commit + tag + push + gh release create

    Plan deviation (recorded against .rune\plan-hub-installer-phase3.md):
      Plan called for a two-zip design — an "asset-only" zip used to compute the
      embedded hash, and a "final" inclusive zip (assets + installer) shipped as
      the release asset. That design is internally inconsistent: the installer
      downloads the release asset and verifies it against $Script:ExpectedZipHash,
      so the hash must be of THAT zip. We ship a single asset-only zip and host
      install-hub.ps1 via the tag-pinned raw URL (K24 — same one-liner the README
      documents). Offline users grab install-hub.ps1 from raw + Hub.zip from the
      release page; the hash check still holds.

.PARAMETER Version
    Four-part version (e.g. '1.1.0.0'). Forwarded to build-hub.ps1.

.PARAMETER Tag
    Release tag (e.g. 'v1.1.0'). Defaults to $Version with the trailing '.0'
    stripped, prefixed with 'v'.

.PARAMETER Publish
    Without this switch the script stops after patching install-hub.ps1 and
    printing the hash — a dry run safe for self-test. With -Publish the script
    commits + tags + pushes to origin and creates the GitHub release.

.EXAMPLE
    .\build-release.ps1 -Version 1.1.0.0
    # Dry run. Produces build\Hub.zip and patches install-hub.ps1 in place.

.EXAMPLE
    .\build-release.ps1 -Version 1.1.0.0 -Publish
    # Cuts the v1.1.0 release. Requires gh CLI authenticated.
#>
[CmdletBinding()]
param(
    [string]$Version = '1.1.0.0',
    [string]$Tag,
    [switch]$Publish
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $Tag) {
    $Tag = 'v' + ($Version -replace '\.0$', '')
}

$RepoRoot      = $PSScriptRoot
$BuildDir      = Join-Path $RepoRoot 'build'
$StagingDir    = Join-Path $BuildDir 'release\Hub'
$ZipPath       = Join-Path $BuildDir 'Hub.zip'
$InstallerPath = Join-Path $RepoRoot 'install-hub.ps1'
$ChangelogPath = Join-Path $RepoRoot 'CHANGELOG.md'

function Write-Step  { param([string]$Msg) Write-Host "[release] $Msg" -ForegroundColor Cyan }
function Write-Done  { param([string]$Msg) Write-Host "[release] $Msg" -ForegroundColor Green }
function Write-Warn3 { param([string]$Msg) Write-Host "[release] $Msg" -ForegroundColor Yellow }

# --- 1. Rebuild Hub.exe -------------------------------------------------------

Write-Step "Building Hub.exe v$Version"
& (Join-Path $RepoRoot 'build-hub.ps1') -Version $Version
if ($LASTEXITCODE -ne 0) {
    throw "build-hub.ps1 failed (exit $LASTEXITCODE)."
}
$exePath = Join-Path $RepoRoot 'Hub.exe'
if (-not (Test-Path $exePath)) { throw "Hub.exe not found at $exePath after build." }
$exeInfo = Get-Item $exePath
Write-Done "Hub.exe built ($($exeInfo.Length) bytes)"

# --- 2. Stage assets ----------------------------------------------------------

Write-Step 'Staging release contents...'
if (Test-Path $StagingDir) { Remove-Item $StagingDir -Recurse -Force }
New-Item -ItemType Directory -Path $StagingDir -Force | Out-Null

Copy-Item -Path $exePath                          -Destination $StagingDir -Force
Copy-Item -Path (Join-Path $RepoRoot 'Hub.ico')   -Destination $StagingDir -Force
Copy-Item -Path (Join-Path $RepoRoot 'README.md') -Destination $StagingDir -Force
Copy-Item -Path (Join-Path $RepoRoot 'wwwroot')   -Destination $StagingDir -Recurse -Force

$expectedFiles = @('Hub.exe', 'Hub.ico', 'README.md', 'wwwroot\index.html', 'wwwroot\app.js', 'wwwroot\style.css')
foreach ($f in $expectedFiles) {
    $p = Join-Path $StagingDir $f
    if (-not (Test-Path $p)) { throw "Staging missing required file: $f" }
}
Write-Done "Staged $($expectedFiles.Count)+ files to $StagingDir"

# --- 3. Zip the staging dir ---------------------------------------------------

Write-Step "Creating $ZipPath"
if (Test-Path $ZipPath) { Remove-Item $ZipPath -Force }
Compress-Archive -Path (Join-Path $StagingDir '*') -DestinationPath $ZipPath -Force
$zipInfo = Get-Item $ZipPath
$zipHash = (Get-FileHash -Path $ZipPath -Algorithm SHA256).Hash
Write-Done "Hub.zip $($zipInfo.Length) bytes, SHA256 = $zipHash"

# --- 4. Patch install-hub.ps1 with the new hash -------------------------------

Write-Step 'Patching install-hub.ps1 with embedded hash...'
$installerSrc = Get-Content -Path $InstallerPath -Raw

# Match the literal-quoted value following: $Script:ExpectedZipHash = '
$marker  = "`$Script:ExpectedZipHash = '"
$pattern = '(?<=' + [regex]::Escape($marker) + ")[^']*"

if ($installerSrc -notmatch $pattern) {
    throw "Could not locate `$Script:ExpectedZipHash assignment in $InstallerPath. Refusing to patch."
}
$patched = [regex]::Replace($installerSrc, $pattern, $zipHash, 1)

# UTF-8 WITH BOM — PS5's `powershell.exe -File` reader needs the BOM to detect
# UTF-8 when the script contains non-ASCII (em-dashes etc. in comments).
$utf8WithBom = New-Object System.Text.UTF8Encoding($true)
[System.IO.File]::WriteAllText($InstallerPath, $patched, $utf8WithBom)
Write-Done "install-hub.ps1 now embeds SHA256 $zipHash"

# --- 5. Publish (gated) --------------------------------------------------------

if (-not $Publish) {
    Write-Warn3 ''
    Write-Warn3 "DRY RUN complete. To publish:"
    Write-Warn3 "    .\build-release.ps1 -Version $Version -Tag $Tag -Publish"
    Write-Warn3 "Before -Publish: verify Hub.zip integrity (see tests\smoke-installer-phase3.ps1)."
    return
}

if (-not (Test-Path $ChangelogPath)) {
    throw "CHANGELOG.md not found at $ChangelogPath. Create it before publishing."
}

$ghCmd = Get-Command gh -ErrorAction SilentlyContinue
if (-not $ghCmd) {
    throw "gh CLI not found on PATH. Install GitHub CLI (winget install GitHub.cli) and re-run."
}

# Block clobbering an existing tag/release without explicit re-tag
$existingTag = & git -C $RepoRoot tag --list $Tag
if ($existingTag) {
    throw "Tag $Tag already exists. Delete it first (git tag -d $Tag; git push origin :refs/tags/$Tag) or pick a new tag."
}

# Verify clean working tree before committing the patched installer
$dirty = & git -C $RepoRoot status --porcelain
if ($dirty) {
    $other = $dirty -split "`n" | Where-Object { $_ -and $_ -notmatch ' install-hub\.ps1\s*$' }
    if ($other) {
        throw "Working tree has uncommitted changes besides install-hub.ps1:`n$($other -join "`n")"
    }
}

Write-Step 'Committing patched install-hub.ps1...'
& git -C $RepoRoot add install-hub.ps1
& git -C $RepoRoot commit -m "Release $Tag — embed Hub.zip SHA256 $zipHash"
if ($LASTEXITCODE -ne 0) { throw "git commit failed (exit $LASTEXITCODE)." }

Write-Step "Tagging $Tag..."
& git -C $RepoRoot tag $Tag
if ($LASTEXITCODE -ne 0) { throw "git tag failed (exit $LASTEXITCODE)." }

Write-Step 'Pushing main + tags...'
& git -C $RepoRoot push origin main --tags
if ($LASTEXITCODE -ne 0) { throw "git push failed (exit $LASTEXITCODE)." }

Write-Step "Creating GitHub release $Tag..."
& gh release create $Tag $ZipPath --title "Hub $Tag" --notes-file $ChangelogPath
if ($LASTEXITCODE -ne 0) { throw "gh release create failed (exit $LASTEXITCODE)." }

Write-Done ''
Write-Done "Release $Tag published."
Write-Done "Install one-liner:"
Write-Done "  irm https://raw.githubusercontent.com/Patryk-beep/powershell-script-hub/$Tag/install-hub.ps1 | iex"
