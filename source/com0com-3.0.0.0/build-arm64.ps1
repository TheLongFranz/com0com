<#
.SYNOPSIS
    Builds com0com for Windows on ARM (ARM64) without the legacy DDK "build" tool.

.DESCRIPTION
    Produces, under .\arm64\ :
        com0com.sys   kernel driver               (cl /kernel + WDK headers/libs)
        setup.dll     setup engine
        setupc.exe    command-line setup utility  (requireAdministrator manifest embedded)
        setupg.exe    GUI setup utility           (C++/CLI, architecture-neutral MSIL)
        package\      INFs + test-signed .sys + .cat, ready for install-arm64.ps1

    Prerequisites (no admin rights needed to build):
        * Visual Studio 2022/2026 with "MSVC ... ARM64 build tools" (Microsoft.VisualStudio.Component.VC.Tools.ARM64)
        * Windows 10/11 SDK
        * A WDK. If none is installed, the Microsoft.Windows.WDK.ARM64 NuGet package is downloaded
          into .\arm64\_deps (the download is hash-checked).
        * Windows PowerShell 5.1 or PowerShell 7 (used to compile Form1.resx)

.PARAMETER Clean      Delete previous build output (the download cache is kept) first.
.PARAMETER SkipGui    Do not build setupg.exe.
.PARAMETER SkipSign   Do not create a test certificate / sign / create the catalog.
.PARAMETER SkipTests  Do not build the native test tool tests\c0ctest.c (arm64, x64 and x86 flavours).
.PARAMETER SkipHub4com Do not build ..\hub4com-2.0.0.0 (hub4com.exe with statically linked plugins).
.PARAMETER SkipInstaller Do not build the NSIS installer (needs a signed package, so it is skipped with -SkipSign too).
.PARAMETER WdkVersion Version of the Microsoft.Windows.WDK.ARM64 NuGet package used when no WDK is installed.
.PARAMETER GuiClr     'safe' (default): /clr:safe, no native runtime needed on the target machine.
                      'mixed'         : plain /clr, for the day MSVC drops the deprecated /clr:safe.
                                        UNTESTED end to end: it needs the Visual Studio "C++/CLI support" component
                                        (for mscoree.lib, not installed on the machine this was developed on) and the
                                        VC++ ARM64 redistributable on the target machine.
.PARAMETER CertSubject Subject of the self-signed code-signing certificate used for test signing.
#>
[CmdletBinding()]
param(
    [switch]$Clean,
    [switch]$SkipGui,
    [switch]$SkipSign,
    [switch]$SkipTests,
    [switch]$SkipHub4com,
    [switch]$SkipInstaller,
    [string]$WdkVersion = '10.0.26100.6584',
    [ValidateSet('safe', 'mixed')][string]$GuiClr = 'safe',
    [string]$CertSubject = 'CN=com0com (test)'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Root = $PSScriptRoot
$Out  = Join-Path $Root 'arm64'
$Obj  = Join-Path $Out 'obj'
$Deps = Join-Path $Out '_deps'
$Pkg  = Join-Path $Out 'package'

# SHA-256 of the WDK NuGet package we validated this build against.
$KnownWdkHash = @{ '10.0.26100.6584' = 'e705b2a63eab891def8f98087666f93e8f21da8e3b5def81a624b83fef5bdae9' }

function Write-Step($text) { Write-Host ''; Write-Host "=== $text" -ForegroundColor Cyan }

function Invoke-Tool {
    param([Parameter(Mandatory)][string]$Exe, [string[]]$ToolArgs = @())
    & $Exe @ToolArgs
    if ($LASTEXITCODE -ne 0) { throw "$([IO.Path]::GetFileName($Exe)) failed with exit code $LASTEXITCODE" }
}

function New-CleanDir($path) {
    if (Test-Path $path) { Remove-Item $path -Recurse -Force }
    New-Item -ItemType Directory -Force $path | Out-Null
}

# ---------------------------------------------------------------------------------------------
# Toolchain discovery
# ---------------------------------------------------------------------------------------------
function Import-VcEnvironment {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path $vswhere)) { throw 'Visual Studio is not installed (vswhere.exe not found).' }
    $vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.ARM64 -property installationPath
    if (-not $vs) { throw 'No Visual Studio with the "MSVC ARM64 build tools" component was found.' }

    $hostIsArm = ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') -or ($env:PROCESSOR_ARCHITEW6432 -eq 'ARM64')
    $vcArch = if ($hostIsArm) { 'arm64' } else { 'x64_arm64' }
    $bat = Join-Path $vs 'VC\Auxiliary\Build\vcvarsall.bat'
    Write-Host "Visual Studio : $vs  (vcvarsall $vcArch)"

    $vars = cmd /c "`"$bat`" $vcArch >nul 2>&1 && set"
    if ($LASTEXITCODE -ne 0) { throw "vcvarsall.bat $vcArch failed." }
    foreach ($line in $vars) {
        if ($line -match '^([^=]+)=(.*)$') { Set-Item -Path "Env:$($Matches[1])" -Value $Matches[2] }
    }
    if ($env:VSCMD_ARG_TGT_ARCH -ne 'arm64') { throw "vcvarsall did not select an ARM64 target (got '$env:VSCMD_ARG_TGT_ARCH')." }
    $script:VsRoot = $vs
}

function Find-SdkTool([string]$name) {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $kits = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
    $hit = Get-ChildItem $kits -Recurse -Filter $name -ErrorAction SilentlyContinue |
           Where-Object { $_.FullName -match '\\(x64|arm64|x86)\\' } | Sort-Object FullName -Descending | Select-Object -First 1
    if (-not $hit) { throw "$name not found." }
    return $hit.FullName
}

# Sets $script:Wdk{Include,Lib,Bin} - either an installed WDK or the NuGet package.
function Resolve-Wdk {
    $sdkVer = $env:WindowsSDKVersion.TrimEnd('\')
    $kits = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10'
    $installed = Join-Path $kits "Include\$sdkVer\km\ntddk.h"
    if (Test-Path $installed) {
        $script:WdkRoot = $kits
        Write-Host "WDK           : installed ($kits, $sdkVer)"
    }
    else {
        $dir = Join-Path $Deps "wdk-$WdkVersion"
        if (-not (Test-Path (Join-Path $dir 'c\Include'))) {
            New-Item -ItemType Directory -Force $Deps | Out-Null
            $nupkg = Join-Path $Deps "wdk-$WdkVersion.nupkg"
            $url = "https://api.nuget.org/v3-flatcontainer/microsoft.windows.wdk.arm64/$WdkVersion/microsoft.windows.wdk.arm64.$WdkVersion.nupkg"
            Write-Host "Downloading WDK package $WdkVersion (about 45 MB) ..."
            Invoke-WebRequest -Uri $url -OutFile $nupkg -UseBasicParsing
            $hash = (Get-FileHash $nupkg -Algorithm SHA256).Hash.ToLower()
            if ($KnownWdkHash.ContainsKey($WdkVersion) -and $KnownWdkHash[$WdkVersion] -ne $hash) {
                Remove-Item $nupkg -Force
                throw "WDK package hash mismatch for $WdkVersion (got $hash)."
            }
            New-CleanDir $dir
            Invoke-Tool tar @('-xf', $nupkg, '-C', $dir)
        }
        $script:WdkRoot = Join-Path $dir 'c'
        Write-Host "WDK           : NuGet Microsoft.Windows.WDK.ARM64 $WdkVersion"
    }
    $script:SdkVer = $sdkVer
    $script:KmInclude = @("$WdkRoot\Include\$sdkVer\km", "$WdkRoot\Include\$sdkVer\km\crt", "$WdkRoot\Include\$sdkVer\shared")
    $script:KmLib = "$WdkRoot\Lib\$sdkVer\km\ARM64"
    foreach ($p in @($KmInclude[0], $KmLib)) { if (-not (Test-Path $p)) { throw "WDK path missing: $p" } }
    $script:Inf2Cat = Get-ChildItem "$WdkRoot\bin" -Recurse -Filter Inf2Cat.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
}

# ---------------------------------------------------------------------------------------------
# Build steps
# ---------------------------------------------------------------------------------------------
function Build-Driver {
    Write-Step 'com0com.sys (kernel driver)'
    $o = Join-Path $Obj 'sys'
    New-CleanDir $o
    $src = Join-Path $Root 'sys'

    # Same source list as the DDK "sources" file.
    $c = (Get-Content (Join-Path $src 'sources') -Raw) -split '\s+' | Where-Object { $_ -like '*.c' }
    if (-not $c) { throw 'Could not read the source list from sys\sources.' }

    $mc = Find-SdkTool 'mc.exe'
    Push-Location $src
    try {
        Invoke-Tool $mc @('-h', $o, '-r', $o, 'c0clog.mc')

        $sdkInc = Join-Path $env:WindowsSdkDir "Include\$SdkVer"
        $inc = @("/I$o") + ($KmInclude | ForEach-Object { "/I$_" }) + @("/I$sdkInc\shared", "/I$sdkInc\um")
        $defs = '/D_ARM64_', '/DARM64', '/D_WIN64', '/DWIN64', '/DNDEBUG', '/DDBG=0', '/DWINNT=1', '/DNT_UP=1',
                '/DNTDDI_VERSION=0x0A000000', '/D_WIN32_WINNT=0x0A00', '/DWINVER=0x0A00', '/DDEPRECATE_DDK_FUNCTIONS=1',
                # ARM64 Windows is always >= Windows 10, so make NonPagedPool allocations non-executable (NX)
                # at compile time. The driver keeps only data in pool; this is required for HVCI/Memory Integrity.
                '/DPOOL_NX_OPTIN_AUTO=1'

        Invoke-Tool rc (@('/nologo', '/fo', "$o\com0com.res") + $defs + $inc + @('com0com.rc'))

        # /forceInterlockedFunctions- : without it, ARM64 /kernel code calls _InterlockedXxx as external
        #                               functions that ntoskrnl does not export; inline the atomics instead.
        # /wd4996                     : upstream uses ExAllocatePoolWithTag (deprecated, still supported).
        $cl = @('/nologo', '/c', '/kernel', '/W4', '/O2', '/Zi', '/Zp8', '/GS-', '/Gy', '/Oi', '/wd4996',
                '/forceInterlockedFunctions-', '/FIwarning.h', "/Fd$o\vc.pdb", "/Fo$o\") + $defs + $inc + $c
        Invoke-Tool cl $cl
    }
    finally { Pop-Location }

    $objs = Get-ChildItem $o -Filter *.obj | ForEach-Object FullName
    Invoke-Tool link (@('/nologo', '/DRIVER', '/SUBSYSTEM:NATIVE', '/KERNEL', '/MACHINE:ARM64', '/RELEASE', '/NODEFAULTLIB',
                        '/ENTRY:DriverEntry', '/INTEGRITYCHECK', '/DEBUG', "/PDB:$Out\com0com.pdb", "/OUT:$Out\com0com.sys",
                        "/LIBPATH:$KmLib") + $objs + @("$o\com0com.res", 'ntoskrnl.lib', 'hal.lib', 'wmilib.lib'))
}

function Build-Setup {
    Write-Step 'setup.dll + setupc.exe'
    $inc = "/I$Root\include"

    $o = Join-Path $Obj 'setup'; New-CleanDir $o
    Push-Location (Join-Path $Root 'setup')
    try {
        Invoke-Tool rc @('/nologo', "/fo$o\setup.res", 'setup.rc')
        # /MT: no dependency on the VC++ redistributable (only two strings cross the dll/exe boundary).
        Invoke-Tool cl @('/nologo', '/LD', '/MT', '/W4', '/O2', '/EHsc', '/DWIN32_LEAN_AND_MEAN', $inc, "/Fo$o\",
                         'setup.cpp', 'inffile.cpp', 'params.cpp', 'devutils.cpp', 'portnum.cpp', 'comdb.cpp', 'msg.cpp', 'utils.cpp',
                         "$o\setup.res", "/Fe$Out\setup.dll",
                         '/link', '/DEF:setup.def', "/IMPLIB:$Out\setup.lib",
                         'kernel32.lib', 'advapi32.lib', 'setupapi.lib', 'newdev.lib', 'user32.lib', 'msports.lib', 'shlwapi.lib')
    }
    finally { Pop-Location }

    $o = Join-Path $Obj 'setupc'; New-CleanDir $o
    Push-Location (Join-Path $Root 'setupc')
    try {
        Invoke-Tool cl @('/nologo', '/MT', '/W4', '/O2', '/EHsc', $inc, "/Fo$o\", 'setup.cpp', "/Fe$Out\setupc.exe",
                         '/link', '/SUBSYSTEM:CONSOLE', "$Out\setup.lib",
                         '/MANIFEST:EMBED', '/MANIFESTUAC:NO', "/MANIFESTINPUT:$Root\requireAdministrator.manifest")
    }
    finally { Pop-Location }
}

function Build-Gui {
    Write-Step "setupg.exe (GUI, /clr:$GuiClr)"
    $o = Join-Path $Obj 'setupg'; New-CleanDir $o
    $src = Join-Path $Root 'setupg'
    $fw = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319'
    if (-not (Test-Path "$fw\System.Windows.Forms.dll")) { throw '.NET Framework 4.x not found.' }

    # Form1.resx -> SetupApp.Form1.resources (there is no resgen.exe without the .NET SDK / Windows SDK NETFX tools)
    $ps = (Get-Command powershell.exe).Source
    Invoke-Tool $ps @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Root 'build\resx2resources.ps1'),
                      '-Resx', "$src\Form1.resx", '-Out', "$o\SetupApp.Form1.resources")

    Invoke-Tool rc @('/nologo', "/fo$o\app.res", "$src\app.rc")

    $refs = 'System.dll', 'System.Drawing.dll', 'System.Windows.Forms.dll', 'System.Data.dll', 'System.Xml.dll' | ForEach-Object { "/FU$fw\$_" }
    $clr = if ($GuiClr -eq 'safe') { @('/clr:safe') } else { @('/clr', '/EHa', '/MD') }
    # C4947: upstream assembly-level declarative security attribute is obsolete (harmless).
    $cpp = 'AssemblyInfo.cpp', 'exec.cpp', 'pinmap.cpp', 'portprms.cpp', 'setup.cpp' | ForEach-Object { "$src\$_" }
    Invoke-Tool cl (@('/nologo', '/c') + $clr + @('/W3', '/wd4947', "/AI$fw") + $refs + @("/Fo$o\") + $cpp)

    $objs = 'AssemblyInfo', 'exec', 'pinmap', 'portprms', 'setup' | ForEach-Object { "$o\$_.obj" }
    Invoke-Tool link (@('/nologo', '/SUBSYSTEM:WINDOWS', '/ENTRY:main', '/MACHINE:ARM64', "/OUT:$Out\setupg.exe",
                        "/ASSEMBLYRESOURCE:$o\SetupApp.Form1.resources", "/LIBPATH:$fw",
                        '/MANIFEST:EMBED', '/MANIFESTUAC:NO', "/MANIFESTINPUT:$Root\requireAdministrator.manifest") + $objs + @("$o\app.res"))
}

# hub4com (the communications hub) lives next to this folder as ..\hub4com-2.0.0.0.
# Builds the "static" flavour (all plugins linked into one hub4com.exe) from the file list of its vcproj.
function Build-Hub4com {
    $h = Join-Path (Split-Path -Parent $Root) 'hub4com-2.0.0.0'
    $vcproj = Join-Path $h 'static\hub4com-static.vcproj'
    if (-not (Test-Path $vcproj)) { Write-Host "hub4com sources not found at $h - skipping."; return }
    Write-Step 'hub4com.exe (static plugins)'

    $o = Join-Path $Obj 'hub4com'
    New-CleanDir $o

    $xml = New-Object System.Xml.XmlDocument
    $xml.Load($vcproj)
    $files = $xml.SelectNodes('//File') | ForEach-Object { [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $vcproj) $_.RelativePath)) }
    $rc = $files | Where-Object { $_ -like '*.rc' } | Select-Object -First 1
    $groups = $files | Where-Object { $_ -like '*.cpp' } | Group-Object { Split-Path -Parent $_ }

    $objs = @()
    $n = 0
    foreach ($g in $groups) {
        # Plugins reuse file names (comport.cpp, filter.cpp, ...): keep each directory's objects apart.
        $od = Join-Path $o ('d{0:D2}' -f $n++)
        New-Item -ItemType Directory -Force $od | Out-Null
        Push-Location $g.Name
        try {
            Invoke-Tool cl (@('/nologo', '/c', '/MT', '/O2', '/W3', '/EHsc', '/DUSE_STATIC_PLUGINS', '/D_CRT_SECURE_NO_DEPRECATE', "/Fo$od\") +
                            ($g.Group | ForEach-Object { Split-Path -Leaf $_ }))
        }
        finally { Pop-Location }
        $objs += Get-ChildItem $od -Filter *.obj | ForEach-Object FullName
    }

    Invoke-Tool rc @('/nologo', "/fo$o\hub4com.res", $rc)
    Invoke-Tool link (@('/nologo', '/SUBSYSTEM:CONSOLE', '/MACHINE:ARM64', "/OUT:$Out\hub4com.exe") + $objs + @("$o\hub4com.res", 'ws2_32.lib', 'advapi32.lib'))
}

function Build-Tests {
    Write-Step 'tests (c0ctest.c as native arm64, emulated x64, WOW64 x86)'
    $td = Join-Path $Out 'tests'
    New-CleanDir $td
    $bat = Join-Path $VsRoot 'VC\Auxiliary\Build\vcvarsall.bat'
    $hostIsArm = ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') -or ($env:PROCESSOR_ARCHITEW6432 -eq 'ARM64')
    $vcArch = if ($hostIsArm) { @{ arm64 = 'arm64'; x64 = 'arm64_x64'; x86 = 'arm64_x86' } }
              else            { @{ arm64 = 'x64_arm64'; x64 = 'x64'; x86 = 'x64_x86' } }
    foreach ($a in 'arm64', 'x64', 'x86') {
        $exe = Join-Path $td "c0ctest-$a.exe"
        # /MT: the same exe must run on machines without the VC++ redistributable.
        $line = "`"$bat`" $($vcArch[$a]) >nul 2>&1 && cl /nologo /O2 /W4 /MT /D_CRT_SECURE_NO_WARNINGS /Fo`"$td\c0ctest-$a.obj`" `"$Root\tests\c0ctest.c`" /Fe`"$exe`" /link /SUBSYSTEM:CONSOLE"
        cmd /c "call $line"
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $exe)) { throw "building c0ctest-$a failed" }
    }
    Remove-Item "$td\*.obj" -ErrorAction SilentlyContinue
}

# Builds NSIS\install.nsi (the upstream installer script, extended for ARM64) from the signed package.
function Build-Installer {
    Write-Step 'installer (NSIS)'
    $nsisVer = '3.11'
    $nsisHash = 'c7d27f780ddb6cffb4730138cd1591e841f4b7edb155856901cdf5f214394fa1'
    $nsis = Join-Path $Deps "nsis-$nsisVer"
    if (-not (Test-Path "$nsis\makensis.exe")) {
        New-Item -ItemType Directory -Force $Deps | Out-Null
        $zip = Join-Path $Deps "nsis-$nsisVer.zip"
        Write-Host "Downloading NSIS $nsisVer (about 2 MB) ..."
        # curl.exe (in Windows since 10 1803): SourceForge answers PowerShell's Invoke-WebRequest with an HTML page.
        Invoke-Tool curl.exe @('-sSL', '--fail', '-o', $zip, "https://sourceforge.net/projects/nsis/files/NSIS%203/$nsisVer/nsis-$nsisVer.zip/download")
        if ((Get-FileHash $zip -Algorithm SHA256).Hash.ToLower() -ne $nsisHash) { Remove-Item $zip -Force; throw 'NSIS download hash mismatch.' }
        Expand-Archive $zip -DestinationPath $Deps -Force
    }

    $ver = 'V1', 'V2', 'V3', 'V4' | ForEach-Object { if ((Get-Content "$Root\sys\version.h" -Raw) -match "C0C_$_\s+(\d+)") { $Matches[1] } }
    $exe = Join-Path $Out ("com0com-{0}-arm64-testsigned-setup.exe" -f ($ver -join '.'))
    Push-Location (Join-Path $Root 'NSIS')
    try {
        # The installer is an x86 program (NSIS has no ARM64 stub) that installs the native ARM64 files.
        Invoke-Tool "$nsis\makensis.exe" @('/V2', '/DADD_TARGET_CPU_arm64', "/DCPU_DIR_arm64=$Pkg", "/DSETUPG_EXE=$Pkg\setupg.exe",
                                          "/DTEST_CERT=$Pkg\com0com-test.cer", "/DOUTPUT_FILE=$exe", 'install.nsi')
    }
    finally { Pop-Location }
}

function Get-TestCertificate {
    $cert = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert |
            Where-Object { $_.Subject -eq $CertSubject -and $_.NotAfter -gt (Get-Date).AddDays(30) } |
            Sort-Object NotAfter -Descending | Select-Object -First 1
    if (-not $cert) {
        Write-Host "Creating self-signed code-signing certificate '$CertSubject' (valid 5 years) ..."
        $cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject $CertSubject -KeyAlgorithm RSA -KeyLength 2048 `
                    -HashAlgorithm SHA256 -CertStoreLocation Cert:\CurrentUser\My -NotAfter (Get-Date).AddYears(5)
    }
    $certDir = Join-Path $Out 'cert'
    New-Item -ItemType Directory -Force $certDir | Out-Null
    Export-Certificate -Cert $cert -FilePath (Join-Path $certDir 'com0com-test.cer') | Out-Null
    $cert
}

function Build-Package {
    Write-Step 'package (test-signed driver package)'
    New-CleanDir $Pkg
    foreach ($f in 'com0com.sys', 'setup.dll', 'setupc.exe', 'setupg.exe') {
        if (Test-Path "$Out\$f") { Copy-Item "$Out\$f" $Pkg }
    }
    foreach ($f in 'com0com.inf', 'cncport.inf', 'comport.inf', 'ReadMe.txt', 'license.txt', 'install-arm64.ps1') {
        Copy-Item (Join-Path $Root $f) $Pkg
    }

    if ($SkipSign) { Write-Host 'Signing skipped (-SkipSign): the package cannot be installed until it is signed.'; return }

    if (-not $Inf2Cat) { throw 'Inf2Cat.exe not found in the WDK.' }
    $cert = Get-TestCertificate
    Copy-Item (Join-Path $Out 'cert\com0com-test.cer') $Pkg
    $signtool = Find-SdkTool 'signtool.exe'
    Write-Host "Certificate   : $($cert.Subject)  [$($cert.Thumbprint)]"

    Invoke-Tool $signtool @('sign', '/sha1', $cert.Thumbprint, '/fd', 'sha256', "$Pkg\com0com.sys")
    # The catalog hashes the .sys, so it must be created after the .sys is signed.
    Invoke-Tool $Inf2Cat @("/driver:$Pkg", '/os:10_NI_ARM64,10_GE_ARM64')
    Invoke-Tool $signtool @('sign', '/sha1', $cert.Thumbprint, '/fd', 'sha256', "$Pkg\com0com.cat")
    # Sanity checks: the catalog signature is valid and the signed .sys is a member of the catalog.
    # (Chain trust needs the test certificate in the Root store - see install-arm64.ps1.)
    Invoke-Tool $signtool @('verify', '/pa', "$Pkg\com0com.cat")
    Invoke-Tool $signtool @('verify', '/pa', '/c', "$Pkg\com0com.cat", "$Pkg\com0com.sys")
}

# ---------------------------------------------------------------------------------------------
if ($Clean -and (Test-Path $Out)) {
    Write-Step 'clean'
    Get-ChildItem $Out -Force | Where-Object { $_.Name -ne '_deps' } | Remove-Item -Recurse -Force
}
New-Item -ItemType Directory -Force $Out | Out-Null

Write-Step 'toolchain'
Import-VcEnvironment
Resolve-Wdk

Build-Driver
Build-Setup
if (-not $SkipGui) { Build-Gui }
if (-not $SkipHub4com) { Build-Hub4com }
if (-not $SkipTests) { Build-Tests }
Build-Package
if (-not $SkipInstaller -and -not $SkipSign) { Build-Installer }

Write-Step 'result'
Get-ChildItem $Out -File | Where-Object Extension -in '.sys', '.dll', '.exe' | Select-Object Name, Length, LastWriteTime | Format-Table -AutoSize
Write-Host "Package: $Pkg" -ForegroundColor Green
