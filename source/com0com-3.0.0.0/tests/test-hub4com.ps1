<#
.SYNOPSIS
    Tests the ARM64 hub4com.exe against two com0com pairs:

        [A] <-pair X-> [H1]--hub4com--[H2] <-pair Y-> [B]

    1. serial bridge      : bytes written to A come out of B (and back)
    2. TCP server mode    : hub4com listens, this script connects; H1 <-> TCP
    3. TCP client mode    : this script listens, hub4com connects; H1 <-> TCP

    A, H1, H2, B must be COM<n> names (System.IO.Ports.SerialPort does not accept CNCxx names).
#>
param(
    [Parameter(Mandatory)][string]$A,
    [Parameter(Mandatory)][string]$H1,
    [Parameter(Mandatory)][string]$H2,
    [Parameter(Mandatory)][string]$B,
    [string]$Hub4com = (Join-Path (Split-Path -Parent $PSScriptRoot) 'arm64\hub4com.exe')
)
$ErrorActionPreference = 'Stop'
$script:pass = 0; $script:fail = 0
function Check($name, $ok, $detail = '') {
    if ($ok) { $script:pass++ } else { $script:fail++ }
    '  [{0}] {1,-52} {2}' -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $detail
}
if (-not (Test-Path $Hub4com)) { throw "hub4com.exe not found at $Hub4com" }

function New-Port($name) {
    $p = New-Object System.IO.Ports.SerialPort $name, 115200, 'None', 8, 'One'
    $p.ReadTimeout = 5000; $p.WriteTimeout = 5000
    $p.Open(); $p
}
function Read-Exactly($stream, [int]$count, [int]$timeoutMs = 8000) {
    $buf = New-Object byte[] $count; $got = 0
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($got -lt $count -and $sw.ElapsedMilliseconds -lt $timeoutMs) {
        try { $n = $stream.Read($buf, $got, $count - $got); if ($n -le 0) { break }; $got += $n } catch [TimeoutException] { break } catch [System.IO.IOException] { break }
    }
    if ($got -eq 0) { return , (New-Object byte[] 0) }
    return , ($buf[0..($got - 1)])
}
function New-Payload([int]$n, [int]$seed) { $b = New-Object byte[] $n; (New-Object Random $seed).NextBytes($b); , $b }
function Same($x, $y) { ($x.Count -eq $y.Count) -and -not (Compare-Object $x $y -SyncWindow 0) }
function Start-Hub([string[]]$HubArgs, [string]$tag) {
    $log = Join-Path $env:TEMP "hub4com-$tag.log"
    $p = Start-Process $Hub4com -ArgumentList $HubArgs -PassThru -WindowStyle Hidden -RedirectStandardError $log -RedirectStandardOutput "$log.out"
    Start-Sleep -Milliseconds 1500
    $p | Add-Member -NotePropertyName LogFile -NotePropertyValue $log -PassThru
}
function Stop-Hub($p) { if ($p -and -not $p.HasExited) { $p.Kill(); $p.WaitForExit(3000) | Out-Null } }

$ver = & $Hub4com --help 2>&1 | Select-Object -First 1
Write-Host "hub4com: $Hub4com"

# ---------------------------------------------------------------- 1. serial bridge
Write-Host "`nserial bridge ($A <-> $H1 ~ hub4com ~ $H2 <-> $B)"
$hub = Start-Hub @('--octs=off', "\\.\$H1", "\\.\$H2") 'serial'
try {
    Check 'hub4com stays running after opening both ports' (-not $hub.HasExited) $(if ($hub.HasExited) { "exit code $($hub.ExitCode): " + (Get-Content $hub.LogFile -Raw) })
    $pa = New-Port $A; $pb = New-Port $B
    try {
        # Write asynchronously while reading, like a real application: the pipeline (com0com buffers +
        # hub4com) holds only ~8 KB, so a synchronous write of more than that would block until its timeout.
        $d = New-Payload 262144 11
        $w = $pa.BaseStream.WriteAsync($d, 0, $d.Length)
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $r = Read-Exactly $pb.BaseStream $d.Length
        $ms = $sw.ElapsedMilliseconds
        Check "256 KiB  $A -> $B through the hub" ((Same $d $r) -and $w.Wait(5000)) "$($r.Count) bytes in $ms ms"

        $d = New-Payload 262144 12
        $w = $pb.BaseStream.WriteAsync($d, 0, $d.Length)
        $sw.Restart()
        $r = Read-Exactly $pa.BaseStream $d.Length
        $ms = $sw.ElapsedMilliseconds
        Check "256 KiB  $B -> $A through the hub" ((Same $d $r) -and $w.Wait(5000)) "$($r.Count) bytes in $ms ms"

        $d = [byte[]](0..255)
        $pa.Write($d, 0, 256)
        $r = Read-Exactly $pb.BaseStream 256
        Check 'all 256 byte values survive the hub' (Same $d $r) "$($r.Count) bytes"
    }
    finally { $pa.Close(); $pb.Close() }
}
finally { Stop-Hub $hub }

# ---------------------------------------------------------------- 2. TCP, hub4com listens
$port1 = 47231
Write-Host "`nTCP server mode (hub4com listens on $port1)"
$hub = Start-Hub @('--octs=off', "\\.\$H1", '--use-driver=tcp', "$port1") 'tcp-server'
try {
    Check 'hub4com stays running' (-not $hub.HasExited) $(if ($hub.HasExited) { "exit code $($hub.ExitCode): " + (Get-Content $hub.LogFile -Raw) })
    $pa = New-Port $A
    $tcp = New-Object Net.Sockets.TcpClient
    try {
        $tcp.Connect('127.0.0.1', $port1)
        $tcp.ReceiveTimeout = 5000
        $ns = $tcp.GetStream()
        Start-Sleep -Milliseconds 500
        $d = New-Payload 8192 21
        $ns.Write($d, 0, $d.Length)
        $r = Read-Exactly $pa.BaseStream $d.Length
        Check "8 KiB  TCP -> $A" (Same $d $r) "$($r.Count) bytes"

        $d = New-Payload 8192 22
        $pa.Write($d, 0, $d.Length)
        $r = Read-Exactly $ns $d.Length
        Check "8 KiB  $A -> TCP" (Same $d $r) "$($r.Count) bytes"
    }
    catch { Check 'TCP client connects to hub4com' $false $_.Exception.Message }
    finally { $tcp.Close(); $pa.Close() }
}
finally { Stop-Hub $hub }

# ---------------------------------------------------------------- 3. TCP, hub4com connects
$port2 = 47232
Write-Host "`nTCP client mode (hub4com connects to 127.0.0.1:$port2)"
$listener = New-Object Net.Sockets.TcpListener ([Net.IPAddress]::Loopback), $port2
$listener.Start()
$hub = $null
try {
    $hub = Start-Hub @('--octs=off', "\\.\$H1", '--use-driver=tcp', "127.0.0.1:$port2") 'tcp-client'
    $pa = New-Port $A
    try {
        $accept = $listener.AcceptTcpClientAsync()
        $ok = $accept.Wait(8000)
        Check 'hub4com connects to the listener' $ok
        if ($ok) {
            $tcp = $accept.Result; $tcp.ReceiveTimeout = 5000
            $ns = $tcp.GetStream()
            $d = New-Payload 8192 31
            $pa.Write($d, 0, $d.Length)
            $r = Read-Exactly $ns $d.Length
            Check "8 KiB  $A -> TCP" (Same $d $r) "$($r.Count) bytes"
            $d = New-Payload 8192 32
            $ns.Write($d, 0, $d.Length)
            $r = Read-Exactly $pa.BaseStream $d.Length
            Check "8 KiB  TCP -> $A" (Same $d $r) "$($r.Count) bytes"
            $tcp.Close()
        }
    }
    finally { $pa.Close() }
}
finally { Stop-Hub $hub; $listener.Stop() }

"`nhub4com test: $script:pass passed, $script:fail failed"
exit $(if ($script:fail) { 1 } else { 0 })
