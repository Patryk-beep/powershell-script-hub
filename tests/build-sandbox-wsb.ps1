#Requires -Version 5.1
<#
.SYNOPSIS
    Generate a Windows Sandbox config file (.wsb) that maps this repo's
    tests\ folder read-only into the sandbox and auto-runs sandbox-driver.ps1
    on logon.

.DESCRIPTION
    The host path embedded in a .wsb file is absolute and would leak the dev
    machine's username if committed. So the .wsb is generated locally (and
    gitignored). Only the driver script is tracked.

.EXAMPLE
    .\tests\build-sandbox-wsb.ps1
    # Generates tests\sandbox-install-test.wsb pointing at this repo.

.EXAMPLE
    .\tests\build-sandbox-wsb.ps1 -Tag v1.1.0
    # Same, with explicit tag passed to the driver.
#>
[CmdletBinding()]
param(
    [string]$Tag = 'v1.1.0',
    [string]$OutPath = (Join-Path $PSScriptRoot 'sandbox-install-test.wsb')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$testsDir = $PSScriptRoot
if (-not (Test-Path $testsDir)) {
    throw "tests dir not found: $testsDir"
}
$driver = Join-Path $testsDir 'sandbox-driver.ps1'
if (-not (Test-Path $driver)) {
    throw "sandbox-driver.ps1 missing in $testsDir"
}

$wsb = @"
<Configuration>
  <Networking>Enabled</Networking>
  <MappedFolders>
    <MappedFolder>
      <HostFolder>$testsDir</HostFolder>
      <SandboxFolder>C:\Test</SandboxFolder>
      <ReadOnly>true</ReadOnly>
    </MappedFolder>
  </MappedFolders>
  <LogonCommand>
    <Command>powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Test\sandbox-driver.ps1 -Tag $Tag</Command>
  </LogonCommand>
</Configuration>
"@

Set-Content -Path $OutPath -Value $wsb -Encoding UTF8
Write-Host "Wrote $OutPath"
Write-Host "Mapped host folder: $testsDir -> C:\Test (read-only)"
Write-Host "Tag forwarded to driver: $Tag"
Write-Host ''
Write-Host 'To run: double-click the .wsb file. Windows Sandbox feature must be enabled.'
Write-Host '        ("Turn Windows features on or off" -> "Windows Sandbox")'
