<#
.SYNOPSIS
    Tests the ARM64 NSIS installer end to end (silent install, verification, silent uninstall).
    Run from an elevated PowerShell 7 with test signing on. It REMOVES any existing com0com install first
    (including its port pairs) and leaves com0com uninstalled when it is done - run install-arm64.ps1 afterwards
    if you want the script-based install back.
#>
#Requires -RunAsAdministrator
#Requires -Version 7
$ErrorActionPreference = 'Stop'
$root  = Split-Path -Parent $PSScriptRoot
$setup = Get-ChildItem (Join-Path $root 'arm64') -Filter 'com0com-*-arm64-*setup.exe' | Select-Object -First 1 -ExpandProperty FullName
$ctest = Join-Path $root 'arm64\tests\c0ctest-arm64.exe'
if (-not $setup) { throw 'installer not found - run build-arm64.ps1 first.' }
$dir = Join-Path $env:ProgramFiles 'com0com'
$uninstKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\com0com'

$script:pass = 0; $script:fail = 0
function Check($name, $ok, $detail = '') {
    if ($ok) { $script:pass++ } else { $script:fail++ }
    '  [{0}] {1,-60} {2}' -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $detail
}
function Get-Ports { @(Get-CimInstance Win32_SerialPort | ForEach-Object DeviceID) }
function Wait-For([scriptblock]$cond, [int]$sec = 60) { $sw = [Diagnostics.Stopwatch]::StartNew(); while ($sw.Elapsed.TotalSeconds -lt $sec) { if (& $cond) { return $true }; Start-Sleep -Milliseconds 500 }; $false }

Write-Host "installer: $setup"
Write-Host "`n--- start from a clean machine state"
if (Test-Path "$dir\uninstall.exe") { Start-Process "$dir\uninstall.exe" -ArgumentList '/S', "_?=$dir" -Wait }
& (Join-Path $root 'install-arm64.ps1') -Uninstall *> $null
Check 'no com0com ports before the test' ((Get-Ports | Where-Object { $_ -match '^CNC|^COM6' }).Count -eq 0) ((Get-Ports) -join ',')

Write-Host "`n--- silent install"
$env:CNC_INSTALL_CNCA0_CNCB0_PORTS = 'YES'
$env:CNC_INSTALL_COMX_COMX_PORTS = 'YES'
$env:CNC_INSTALL_START_MENU_SHORTCUTS = 'YES'
$p = Start-Process $setup -ArgumentList '/S' -Wait -PassThru
Check 'installer exit code 0' ($p.ExitCode -eq 0) "exit $($p.ExitCode)"

Write-Host "`n--- installed files (64-bit Program Files)"
foreach ($f in 'setupc.exe', 'setupg.exe', 'setup.dll', 'com0com.sys', 'com0com.cat', 'com0com.inf', 'cncport.inf', 'comport.inf', 'ReadMe.txt', 'uninstall.exe') {
    Check "$dir\$f" (Test-Path "$dir\$f")
}
$key = Get-ItemProperty $uninstKey -ErrorAction SilentlyContinue
Check 'uninstall entry in the 64-bit registry' ($key -and $key.DisplayName -like '*com0com*') "$($key.DisplayName) $($key.DisplayVersion)"
# upstream's script creates them in the installing user's Start menu (no SetShellVarContext all)
$menus = @("$env:APPDATA\Microsoft\Windows\Start Menu\Programs\com0com", "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\com0com")
$menu = $menus | Where-Object { Test-Path "$_\Setup.lnk" } | Select-Object -First 1
Check 'Start menu shortcuts created' ($null -ne $menu) $menu

Write-Host "`n--- driver and ports"
$sys = 'C:\Windows\System32\drivers\com0com.sys'
$sig = Get-AuthenticodeSignature $sys
Check 'com0com.sys installed and signature valid' ((Test-Path $sys) -and $sig.Status -eq 'Valid') "$($sig.Status), signer $($sig.SignerCertificate.Subject)"
$hasCnc = Wait-For { (Get-Ports) -contains 'CNCA0' -and (Get-Ports) -contains 'CNCB0' }
Check 'installer created CNCA0 <-> CNCB0' $hasCnc ((Get-Ports) -join ', ')
# Windows installs the port devices of a pair asynchronously after "setupc install" returns, so wait for them.
$null = Wait-For { @(Get-Ports | Where-Object { $_ -match '^COM\d+$' }).Count -ge 2 } 90
$comPorts = @(Get-Ports | Where-Object { $_ -match '^COM\d+$' })
Check 'installer created a COM# <-> COM# pair' ($comPorts.Count -ge 2) ($comPorts -join ', ')
$bad = @()
$null = Wait-For {
    $script:bad = @(Get-PnpDevice | Where-Object { $_.InstanceId -match '^(COM0COM|ROOT\\COM0COM)' -and $_.Status -ne 'OK' })
    $script:bad.Count -eq 0
} 60
Check 'every com0com device is started' ($bad.Count -eq 0) (($bad | ForEach-Object { "$($_.InstanceId): $($_.Problem)" }) -join '; ')
$list = & "$dir\setupc.exe" list 2>&1
Check 'installed setupc.exe runs and lists both pairs' (($list -join ' ') -match 'CNCA0' -and ($list -join ' ') -match 'COM#') ''

if (Test-Path $ctest) {
    $r = & $ctest CNCA0 CNCB0 noemubr 2>&1 | Select-Object -Last 1
    Check 'data flows over CNCA0 <-> CNCB0' ($LASTEXITCODE -eq 0) $r
    if ($comPorts.Count -ge 2) {
        $r = & $ctest $comPorts[0] $comPorts[1] noemubr 2>&1 | Select-Object -Last 1
        Check "data flows over $($comPorts[0]) <-> $($comPorts[1])" ($LASTEXITCODE -eq 0) $r
    }
}

Write-Host "`n--- silent uninstall"
$p = Start-Process "$dir\uninstall.exe" -ArgumentList '/S', "_?=$dir" -Wait -PassThru
Check 'uninstaller exit code 0' ($p.ExitCode -eq 0) "exit $($p.ExitCode)"
Check 'com0com ports removed' (Wait-For { (Get-Ports | Where-Object { $_ -match '^CNC' -or $_ -in $comPorts }).Count -eq 0 }) ((Get-Ports) -join ',')
Check 'no com0com device left' (@(Get-PnpDevice | Where-Object { $_.InstanceId -match '^(COM0COM|ROOT\\COM0COM)' }).Count -eq 0)
Check 'uninstall registry entry removed' (-not (Test-Path $uninstKey))
Check 'HKLM\SOFTWARE\com0com removed' (-not (Test-Path 'HKLM:\SOFTWARE\com0com'))
Check 'Start menu shortcuts removed' (-not ($menus | Where-Object { Test-Path "$_\Setup.lnk" }))
Check 'com0com.sys removed from System32\drivers' (-not (Test-Path $sys))
foreach ($f in 'setupc.exe', 'setupg.exe', 'setup.dll', 'com0com.sys', 'com0com.inf', 'comport.inf') { if (Test-Path "$dir\$f") { Check "$f removed" $false } }
Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue      # uninstall.exe itself stays when run with _?=

"`ninstaller test: $script:pass passed, $script:fail failed"
exit $(if ($script:fail) { 1 } else { 0 })
