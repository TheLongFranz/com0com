<#
.SYNOPSIS
    Full ARM64 test run for an installed com0com driver package. Run from an elevated PowerShell 7.

.DESCRIPTION
    Uses the installed driver (see install-arm64.ps1) and the tools built by build-arm64.ps1.
    Creates its own temporary port pairs (COM61..COM66) and removes them again - the pair(s) that
    were installed before the run are left alone.

      1. setupc.exe   install / list / change / remove, named and automatic (COM#) ports
      2. c0ctest      native Win32 API tests over the driver, as ARM64, emulated x64 and emulated x86 clients
      3. baud-rate emulation timing
      4. hub4com      serial bridge and TCP client/server
      5. setupg.exe   the GUI, driven end to end

.PARAMETER SkipGui / SkipHub4com   Leave a suite out.
.PARAMETER KeepPairs               Do not remove the temporary pairs at the end.
.PARAMETER Quick                   Only the setupc suite and the ARM64 c0ctest runs (a couple of minutes).
#>
#Requires -RunAsAdministrator
#Requires -Version 7
[CmdletBinding()]
param([switch]$SkipGui, [switch]$SkipHub4com, [switch]$KeepPairs, [switch]$Quick)

$ErrorActionPreference = 'Stop'
$root  = $PSScriptRoot
$pkg   = Join-Path $root 'arm64\package'
$tests = Join-Path $root 'arm64\tests'
$logs  = Join-Path $tests 'logs'
New-Item -ItemType Directory -Force $logs | Out-Null
foreach ($f in "$pkg\setupc.exe", "$tests\c0ctest-arm64.exe", "$tests\c0ctest-x64.exe", "$tests\c0ctest-x86.exe") {
    if (-not (Test-Path $f)) { throw "$f missing - run build-arm64.ps1 first." }
}

$suites = New-Object System.Collections.Generic.List[object]
$script:cp = 0; $script:cf = 0          # counters for checks made by this script itself

function Check($name, $ok, $detail = '') {
    if ($ok) { $script:cp++ } else { $script:cf++ }
    '  [{0}] {1,-58} {2}' -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $detail
}
# A suite that prints its own "N passed, M failed" line is judged by it; a suite that crashed before
# printing one (no summary) counts as failed.
function Add-Suite($name, $pass, $fail) { $suites.Add([pscustomobject]@{ Suite = $name; Passed = $pass; Failed = $fail; Result = $(if ($fail -eq 0) { 'PASS' } else { 'FAIL' }) }) }

function Invoke-Setupc([string[]]$SetupcArgs) {
    Push-Location $pkg
    try { $out = & .\setupc.exe @SetupcArgs 2>&1 | ForEach-Object { "$_".TrimEnd() }; $code = $LASTEXITCODE }
    finally { Pop-Location }
    [pscustomobject]@{ Output = @($out); Code = $code; Text = ($out -join "`n") }
}
function Get-Ports { @(Get-CimInstance Win32_SerialPort | ForEach-Object DeviceID) }
function Wait-Ports([string[]]$names, [bool]$present, [int]$sec = 30) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    do {
        $now = Get-Ports
        $ok = $true
        foreach ($n in $names) { if (($now -contains $n) -ne $present) { $ok = $false } }
        if ($ok) { return $true }
        Start-Sleep -Milliseconds 300
    } while ($sw.Elapsed.TotalSeconds -lt $sec)
    return $false
}
function Run-Suite($name, [scriptblock]$body) {
    Write-Host ''
    Write-Host "=== $name" -ForegroundColor Cyan
    $log = Join-Path $logs (($name -replace '[^A-Za-z0-9]+', '-').Trim('-') + '.log')
    $text = & $body *>&1 | Tee-Object -FilePath $log | ForEach-Object { Write-Host $_; $_ }
    $m = [regex]::Matches(($text -join "`n"), '(\d+) passed, (\d+) failed') | Select-Object -Last 1
    if ($m) { Add-Suite $name ([int]$m.Groups[1].Value) ([int]$m.Groups[2].Value) }
    else    { Add-Suite $name 0 1 }
}

$baseline = Get-Ports
Write-Host "Windows: $([Environment]::OSVersion.VersionString)   ports before: $($baseline -join ', ')"

# ---------------------------------------------------------------------------- 1. setupc
Run-Suite 'setupc: install / change / list / remove' {
    $script:cp = 0; $script:cf = 0
    $r = Invoke-Setupc 'list'
    Check 'setupc list works' ($r.Code -eq 0) "exit $($r.Code)"
    $pairsBefore = @($r.Output | Where-Object { $_ -match '^\s*CNCA\d+' })

    $store = (pnputil /enum-drivers) -join "`n"
    Check 'driver store holds com0com.inf, cncport.inf and comport.inf' (($store -match 'com0com\.inf') -and ($store -match 'cncport\.inf') -and ($store -match 'comport\.inf')) 'run install-arm64.ps1 if this fails'

    # com0com keeps per-port settings in the registry even after "remove", so a new pair that reuses a number
    # inherits the old pair's options. Always spell out the options the tests rely on.
    $made = @{}
    foreach ($spec in @(
            @{ Tag = 'P1'; A = 'PortName=COM61,EmuBR=no,EmuOverrun=no'; B = 'PortName=COM62,EmuBR=no,EmuOverrun=no' },
            @{ Tag = 'P2'; A = 'PortName=COM63,EmuBR=no,EmuOverrun=no'; B = 'PortName=COM64,EmuBR=no,EmuOverrun=no' },
            @{ Tag = 'P3'; A = 'PortName=COM65,EmuBR=yes,EmuOverrun=no'; B = 'PortName=COM66,EmuBR=yes,EmuOverrun=no' })) {
        $r = Invoke-Setupc @('install', $spec.A, $spec.B)
        $n = if ($r.Text -match 'CNCA(\d+)') { $Matches[1] } else { $null }
        $names = @(($spec.A -replace '^PortName=([^,]+).*', '$1'), ($spec.B -replace '^PortName=([^,]+).*', '$1'))
        $up = Wait-Ports $names $true
        Check "install $($spec.Tag): $($names -join ' + ')" ($r.Code -eq 0 -and $n -and $up) "pair $n, ports up: $up"
        $made[$spec.Tag] = $n
    }
    $script:made = $made
    Set-Content (Join-Path $logs 'pairs.json') ($made | ConvertTo-Json)

    $r = Invoke-Setupc 'list'
    Check 'list shows the new pairs and their options' (($r.Text -match 'COM61') -and ($r.Text -match 'COM66,EmuBR=yes' -or $r.Text -match 'EmuBR=yes')) ''

    # "change" addresses a port by its identifier (CNCA<n> / CNCB<n>), not by its COM name.
    $idA = "CNCA$($made.P1)"
    $r = Invoke-Setupc @('change', $idA, 'EmuOverrun=yes')
    $l = Invoke-Setupc 'list'
    Check "change $idA EmuOverrun=yes is applied" ($r.Code -eq 0 -and $l.Text -match "$idA PortName=COM61.*EmuOverrun=yes") ''
    $r = Invoke-Setupc @('change', $idA, 'EmuOverrun=no')
    $l = Invoke-Setupc 'list'
    Check "change $idA EmuOverrun=no restores it" ($r.Code -eq 0 -and $l.Text -notmatch "$idA PortName=COM61.*EmuOverrun=yes") ''

    # automatic port numbers through the Ports class installer (COM#), see comport.inf
    $before = Get-Ports
    $r = Invoke-Setupc @('install', 'PortName=COM#,EmuBR=no,EmuOverrun=no', 'PortName=COM#,EmuBR=no,EmuOverrun=no')
    $n = if ($r.Text -match 'CNCA(\d+)') { $Matches[1] } else { $null }
    # Windows installs the two port devices asynchronously and the Ports class installer picks the numbers.
    $new = @()
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt 60) {
        $new = @(Get-Ports | Where-Object { $_ -notin $before })
        if ($new.Count -ge 2) { break }
        Start-Sleep -Milliseconds 500
    }
    Check 'install PortName=COM# hands out two real COM numbers' ($r.Code -eq 0 -and $n -and $new.Count -eq 2 -and ($new -match '^COM\d+$').Count -eq 2) "pair $n -> $($new -join ' / ')"
    $pnpBad = @()
    $sw.Restart()
    do {
        $pnp = @(Get-PnpDevice | Where-Object { $_.InstanceId -match "COM0COM\\PORT\\CNC[AB]$n$" })
        $pnpBad = @($pnp | Where-Object { $_.Status -ne 'OK' })
        if ($pnp.Count -eq 2 -and $pnpBad.Count -eq 0) { break }
        Start-Sleep -Milliseconds 500
    } while ($sw.Elapsed.TotalSeconds -lt 30)
    Check 'both COM# devices start without a problem code' ($pnp.Count -eq 2 -and $pnpBad.Count -eq 0) (($pnpBad | ForEach-Object { "$($_.InstanceId): $($_.Problem)" }) -join '; ')
    if ($new.Count -eq 2) {
        $ct = & "$tests\c0ctest-arm64.exe" $new[0] $new[1] noemubr 2>&1 | Select-Object -Last 1
        Check "data flows over the COM# pair ($($new -join ' <-> '))" ($LASTEXITCODE -eq 0) $ct
    }
    if ($n) {
        $r = Invoke-Setupc @('remove', $n)
        Check 'remove that automatic pair' ($r.Code -eq 0 -and (Wait-Ports $new $false)) ''
    }

    $r = Invoke-Setupc @('remove', '9999')
    Check 'remove of a non-existent pair does not crash' ($r.Code -ne $null) "exit $($r.Code)"
    "setupc: $($script:cp) passed, $($script:cf) failed"
}
$made = Get-Content (Join-Path $logs 'pairs.json') | ConvertFrom-Json

# ---------------------------------------------------------------------------- 2. c0ctest
foreach ($arch in 'arm64', 'x64', 'x86') {
    if ($Quick -and $arch -ne 'arm64') { continue }
    Run-Suite "c0ctest ($arch client) on COM61 <-> COM62" { & "$tests\c0ctest-$arch.exe" COM61 COM62 noemubr }
}
Run-Suite 'c0ctest (arm64 client) on the original CNCA0 <-> CNCB0' { & "$tests\c0ctest-arm64.exe" CNCA0 CNCB0 noemubr }
if (-not $Quick) {
    Run-Suite 'c0ctest (arm64 client) with EmuBR on COM65 <-> COM66' { & "$tests\c0ctest-arm64.exe" COM65 COM66 emubr }
    Run-Suite 'c0ctest (x86 client) with EmuBR on COM65 <-> COM66' { & "$tests\c0ctest-x86.exe" COM65 COM66 emubr }
}

# ---------------------------------------------------------------------------- 3. hub4com
if (-not $SkipHub4com -and -not $Quick -and (Test-Path "$root\arm64\hub4com.exe")) {
    Run-Suite 'hub4com: serial bridge + TCP' { & "$root\tests\test-hub4com.ps1" -A COM61 -H1 COM62 -H2 COM63 -B COM64 }
}

# ---------------------------------------------------------------------------- 4. GUI
if (-not $SkipGui -and -not $Quick -and (Test-Path "$pkg\setupg.exe")) {
    Run-Suite 'setupg.exe: GUI end to end' {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$root\tests\test-gui.ps1"
        $global:LASTEXITCODE = $LASTEXITCODE
    }
}

# ---------------------------------------------------------------------------- cleanup
Run-Suite 'cleanup: remove the temporary pairs' {
    $script:cp = 0; $script:cf = 0
    if ($KeepPairs) { Write-Host 'kept (-KeepPairs)' }
    else {
        foreach ($tag in 'P1', 'P2', 'P3') {
            $n = $made.$tag
            $r = Invoke-Setupc @('remove', "$n")
            Check "remove pair $n ($tag)" ($r.Code -eq 0)
        }
        Check 'temporary COM ports are gone' (Wait-Ports @('COM61', 'COM62', 'COM63', 'COM64', 'COM65', 'COM66') $false)
    }
    $after = Get-Ports
    Check 'pre-existing ports are untouched' (@($baseline | Where-Object { $_ -notin $after }).Count -eq 0) "ports now: $($after -join ', ')"
    "cleanup: $($script:cp) passed, $($script:cf) failed"
}

# ---------------------------------------------------------------------------- summary
Write-Host ''
Write-Host '================ SUMMARY ================' -ForegroundColor Cyan
$suites | Format-Table Suite, Passed, Failed, Result -AutoSize | Out-String -Width 200 | Write-Host
$totP = ($suites | Measure-Object Passed -Sum).Sum; $totF = ($suites | Measure-Object Failed -Sum).Sum
Write-Host ("TOTAL: {0} checks passed, {1} failed  ->  {2}" -f $totP, $totF, $(if ($totF -eq 0 -and -not ($suites | Where-Object Result -eq 'FAIL')) { 'ALL GOOD' } else { 'FAILURES' })) `
    -ForegroundColor $(if ($totF -eq 0) { 'Green' } else { 'Red' })
exit $(if ($suites | Where-Object Result -eq 'FAIL') { 1 } else { 0 })
