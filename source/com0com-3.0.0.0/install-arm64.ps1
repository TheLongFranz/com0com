<#
.SYNOPSIS
    Installs (or removes) the test-signed ARM64 com0com driver package built by build-arm64.ps1.

.DESCRIPTION
    Run from an elevated PowerShell, either from the source root or from inside the package folder.
      1. Trusts the test-signing certificate (LocalMachine Root + TrustedPublisher).
      2. Makes sure Windows test-signing mode is on (a reboot is needed the first time).
      3. Installs the driver and one port pair with automatic names (CNCA<n> <-> CNCB<n>).

    A test-signed driver only loads while test-signing is on. For a machine that has to run with
    plain Secure Boot / Memory Integrity, the driver must be signed through the Microsoft
    Hardware Dev Center (attestation signing) instead - see ARM64.md.

.PARAMETER NoPair     Install/update the driver but do not create a port pair.
.PARAMETER Uninstall  Remove all port pairs and the driver.
#>
#Requires -RunAsAdministrator
[CmdletBinding()]
param([switch]$NoPair, [switch]$Uninstall)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
# Inside a built package (com0com.sys next to this script) or in the source root (package is .\arm64\package).
$pkg  = if (Test-Path (Join-Path $here 'com0com.sys')) { $here } else { Join-Path $here 'arm64\package' }
if (-not (Test-Path (Join-Path $pkg 'com0com.sys'))) { throw "Driver package not found in '$pkg'. Run build-arm64.ps1 first." }

if ($env:PROCESSOR_ARCHITECTURE -ne 'ARM64' -and $env:PROCESSOR_ARCHITEW6432 -ne 'ARM64') {
    throw 'This package is for ARM64 Windows only.'
}

Push-Location $pkg
try {
    if ($Uninstall) {
        .\setupc.exe uninstall
        Write-Host "`nUninstalled. (The test certificate was left in the certificate stores.)" -ForegroundColor Green
        return
    }

    $cer = Join-Path $pkg 'com0com-test.cer'
    if (-not (Test-Path $cer)) { throw "Test certificate '$cer' not found." }
    foreach ($store in 'Root', 'TrustedPublisher') {
        Import-Certificate -FilePath $cer -CertStoreLocation "Cert:\LocalMachine\$store" | Out-Null
    }
    Write-Host 'Test certificate trusted (LocalMachine Root + TrustedPublisher).'

    $bcd = (bcdedit /enum '{current}') -join "`n"
    if ($bcd -notmatch 'testsigning\s+Yes') {
        bcdedit /set testsigning on | Out-Host
        if ($LASTEXITCODE -ne 0) { throw 'bcdedit failed. If it reported a Secure Boot error, turn Secure Boot off first.' }
        Write-Host "`nTest signing enabled. REBOOT, then run this script again." -ForegroundColor Yellow
        return
    }

    # Same sequence as the official installer: put every INF (bus, CNC ports, COM# ports) into the driver
    # store, refresh already-installed devices, drop obsolete INFs. Without "preinstall", pairs created with
    # PortName=COM# have no driver to bind to (comport.inf) and stay in CM_PROB_FAILED_INSTALL.
    foreach ($step in 'preinstall', 'update', 'infclean') {
        .\setupc.exe $step
        if ($LASTEXITCODE -ne 0) { throw "setupc $step failed with exit code $LASTEXITCODE" }
    }
    if (-not $NoPair) {
        .\setupc.exe install - -
        if ($LASTEXITCODE -ne 0) { throw "setupc install failed with exit code $LASTEXITCODE" }
    }
    .\setupc.exe list
    Write-Host "`nDone. To remove: .\install-arm64.ps1 -Uninstall" -ForegroundColor Green
}
finally { Pop-Location }
