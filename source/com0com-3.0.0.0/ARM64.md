# com0com for Windows on ARM (ARM64)

com0com 3.0.0.0 (null-modem emulator, virtual serial port pairs) built and tested natively for
**Windows 11 on ARM64**: kernel driver, setup DLL, `setupc` (command line), `setupg` (GUI), an installer,
and the companion **hub4com** 2.0.0.0. Everything is built without the legacy DDK `build` tool.

The upstream sources are unchanged apart from the small edits listed under
[Differences from upstream](#differences-from-upstream-3000).

## Contents

| Output (`arm64\`)                       | What it is |
|-----------------------------------------|------------|
| `com0com.sys`                           | Kernel driver, native ARM64 (non-executable pool, no RWX sections) |
| `setup.dll`, `setupc.exe`               | Setup engine and CLI. Static CRT, so no VC++ redistributable is needed. `setupc` asks for administrator rights |
| `setupg.exe`                            | GUI. Managed code compiled with `/clr:safe`; runs as a native ARM64 process on .NET Framework 4.x (present on Windows 11) |
| `hub4com.exe`                           | hub4com 2.0.0.0, all plugins linked in ("static" flavour) |
| `package\`                              | Test-signed driver package: INFs, signed `com0com.sys`, signed `com0com.cat`, tools, `com0com-test.cer`, `install-arm64.ps1` |
| `com0com-3.0.0.0-arm64-testsigned-setup.exe` | NSIS installer for the test-signed package |
| `tests\c0ctest-{arm64,x64,x86}.exe`     | Native Win32 test tool, built for three client architectures |

## Quick start

Everything below runs from this folder. Building needs no administrator rights; installing and testing do.

```powershell
.\build-arm64.ps1            # build everything into .\arm64  (add -Clean for a from-scratch build)
.\install-arm64.ps1          # elevated: trust the test certificate, enable test signing, install driver + first pair
.\test-arm64.ps1             # elevated, PowerShell 7: run the whole test suite (several minutes)
```

After `install-arm64.ps1` a pair `CNCA0 <-> CNCB0` exists. Use `setupg.exe` (GUI) or `setupc.exe` (CLI, from
`arm64\package`) to manage pairs, for example:

```
setupc install PortName=COM31 PortName=COM32       :: a named pair
setupc install PortName=COM# PortName=COM#         :: let Windows pick the COM numbers
setupc change CNCA1 EmuBR=yes                      :: options are addressed by CNCA<n> / CNCB<n>, not by COM name
setupc list
setupc remove 1
```

The first run of `install-arm64.ps1` turns on test-signing mode and asks for a reboot; run it again afterwards.

### Requirements

* Windows 11 on ARM64 (developed and tested on 25H2, build 26200).
* Visual Studio 2022 or later with **MSVC ARM64 build tools** (`Microsoft.VisualStudio.Component.VC.Tools.ARM64`)
  and a Windows 10/11 SDK. No installed WDK is needed: if none is found the script downloads the
  `Microsoft.Windows.WDK.ARM64` NuGet package (10.0.26100.6584, SHA-256 pinned) into `arm64\_deps`.
* The hub4com sources unpacked next to this folder, as `..\hub4com-2.0.0.0` (from `source\hub4com-2.0.0.0.zip`;
  hub4com is skipped with a message if the folder is missing).
* Windows PowerShell 5.1 (compiles `Form1.resx`; the GUI test uses it too) and PowerShell 7 (test runner).
* Internet access the first time only (WDK from NuGet, NSIS from SourceForge, both hash-checked).
* `sudo` / an elevated prompt for installing and testing.

`build-arm64.ps1` options: `-Clean`, `-SkipGui`, `-SkipSign`, `-SkipTests`, `-SkipHub4com`, `-SkipInstaller`,
`-WdkVersion`, `-GuiClr safe|mixed`, `-CertSubject`. `Get-Help .\build-arm64.ps1 -Full` has the details.

## Testing

`test-arm64.ps1` uses the *installed* driver and the tools from the build. It creates its own temporary pairs
(`COM61`..`COM66`), removes them at the end, and leaves the pairs that existed before untouched.
`-Quick` runs only the setupc suite and the ARM64 client (a couple of minutes).

| Suite | What it checks |
|-------|----------------|
| **setupc** | `install` (named, options, `PortName=COM#`), `list`, `change`, `remove`; the `COM#` pair's devices start and carry data |
| **c0ctest** as **ARM64**, **x64 (emulated)** and **x86 (WOW64)** clients | 44 checks each on a pair: exclusive open, DCB and timeout round trips, data integrity (text, all 256 byte values, 4 MiB full duplex with random chunk sizes and in-order check), `ClearCommError`/`PurgeComm`, RTS/CTS and DTR/DSR wiring, `WaitCommEvent` (`EV_RXCHAR`, `CTS`, `DSR`, `BREAK`, `TXEMPTY`), RTS/CTS and XON/XOFF flow control, read timeouts, cancel/close/reopen, 300 open/close cycles |
| **baud-rate emulation** | with `EmuBR=yes`, 960 bytes at 9600 8N1 take about 1.0 s; without it they arrive at once |
| **hub4com** | serial bridge between two pairs (256 KiB each way), TCP server mode and TCP client mode |
| **setupg** | drives the real GUI: Add Pair, rename ports, Apply, data over the new ports, Remove Pair (confirmation dialog), close. Screenshots go to `arm64\tests\screenshots` |
| **installer** (`tests\test-installer.ps1`, separate) | silent install, files/registry/driver/pairs verified, data over both pair types, silent uninstall leaves nothing behind. It removes any existing com0com install |

Results on the development machine (Windows 11 25H2 ARM64 virtual machine): see [Test results](#test-results).

## Differences from upstream 3.0.0.0

Source changes (everything else is byte-identical to `com0com-3.0.0.0.zip` / `hub4com-2.0.0.0.zip`):

1. **`com0com.inf`, `cncport.inf`, `comport.inf`**: added `NTarm64` sections (the drivers had no ARM64 entries).
2. **`comport.inf`**: the ARM64 entry uses its own install section without `Include = msports.inf` /
   `Needs = SerialEnumerator.NT` and without the `serenum` upper filter. Windows 11 25H2 (build 26200) no longer
   ships `msports.inf`, `serial.sys` or the Serenum service (other recent releases may not either), so the generic
   section fails there
   (`Could not include msports.inf`, device stuck in `CM_PROB_REGISTRY`, so pairs created with `PortName=COM#` never
   appeared). The COM port number is still assigned by the Ports class installer. The x86/x64/ia64 sections
   are untouched.
3. **`setupg\Form1.h`**: two lines changed (`String ^&`/`bool &` parameters became tracking references `%`, and
   `bool portExpand[2]` became `array<bool>^`) so the code is verifiable managed code, which `/clr:safe` requires.
4. **`NSIS\install.nsi`**: an ARM64 CPU section, native-ARM64 detection, 64-bit Program Files and registry view, and
   (only when built with `TEST_CERT`) importing the test certificate and checking for test-signing mode.
   Guarded by `!ifdef`, so builds for the other architectures behave as before.

Build differences (in `build-arm64.ps1`):

* `cl /kernel` + WDK headers replace the DDK build; the source list comes from `sys\sources`.
* `/forceInterlockedFunctions-`: with the current compiler, ARM64 `/kernel` code otherwise calls `_InterlockedXxx`
  as external functions that `ntoskrnl` does not export.
* `/DPOOL_NX_OPTIN_AUTO=1`: all `NonPagedPool` allocations become `NonPagedPoolNx` (verified in the generated
  code). Needed for Memory Integrity; the driver only keeps data in pool.
* `setup.dll`, `setupc.exe` and the tests use the static CRT (`/MT`); the admin manifest is embedded with
  `/MANIFESTUAC:NO` plus upstream's `requireAdministrator.manifest` (without that option the linker adds a second,
  conflicting manifest and the exe does not start).
* `Form1.resx` is compiled to `.resources` by `build\resx2resources.ps1` (no `resgen.exe` available).
* hub4com is built from the file list of its own `hub4com-static.vcproj`.

Added files: `build-arm64.ps1`, `install-arm64.ps1`, `test-arm64.ps1`, `tests\` (`c0ctest.c`,
`test-hub4com.ps1`, `test-gui.ps1`, `test-installer.ps1`), `build\resx2resources.ps1`, `.gitignore`, this file.

## Known limitations and things to know

* **The driver is test-signed.** It only loads with test-signing mode on (Secure Boot off). A build for machines
  running normally needs to be signed through the Microsoft Hardware Dev Center (attestation signing, needs an
  EV code-signing certificate). The driver is built to be HVCI-friendly, but it has **not** been tested with
  Memory Integrity enabled.
* **Tested on one machine:** a Windows 11 25H2 ARM64 virtual machine. Not tested: Windows 10 on ARM, physical ARM64
  hardware, sleep/resume, Driver Verifier, long-duration stress, third-party terminal programs.
* **`/clr:safe` is deprecated** by Microsoft ("will be removed in a future release"). `-GuiClr mixed` builds the same
  sources with plain `/clr` as a fallback, but it needs Visual Studio's C++/CLI component (for `mscoree.lib`) and it
  has **not** been verified. The alternative is porting the small GUI to C#.
* **Port settings outlive their pair.** com0com keeps per-port options in the registry; `setupc remove` does not
  clear them, so a new pair that reuses a pair number inherits the old options (for example `EmuBR=yes`).
  `setupc uninstall` clears them. Spell out the options you rely on when you create a pair (the test suite does).
* `setupc change` takes the port identifier (`CNCA1`), not the COM name; with a COM name it silently does nothing.
* The NSIS stub has no ARM64 flavour, so the installer itself is an x86 program (run under emulation) that installs
  the native ARM64 files. Start-menu shortcuts go to the installing user's Start menu (upstream behaviour).
* hub4com is built with statically linked plugins only (the dynamic `plugins\*.dll` flavour is not built).

## Test results

Machine: Windows 11 25H2 (build 26200.9457), ARM64 virtual machine, test-signing mode on. Run on 2026-09-19.

**Full run, `test-arm64.ps1`: 301 checks, 0 failed.**

| Suite | Checks |
|-------|-------:|
| setupc: install / change / list / remove (including a `COM#` pair carrying data) | 13 |
| c0ctest, ARM64 client, pair `COM61 <-> COM62` | 44 |
| c0ctest, x64 client (emulated), same pair | 44 |
| c0ctest, x86 client (WOW64), same pair | 44 |
| c0ctest, ARM64 client, the original `CNCA0 <-> CNCB0` pair | 44 |
| c0ctest, ARM64 client, pair with baud-rate emulation | 43 |
| c0ctest, x86 client, pair with baud-rate emulation | 43 |
| hub4com: serial bridge + TCP server + TCP client | 10 |
| setupg: GUI end to end | 11 |
| cleanup (temporary pairs removed, existing pair untouched) | 5 |

Measured along the way: full-duplex streaming of 4 MiB (random chunk sizes, in-order check) ran at 87 MiB/s
aggregate from an ARM64 client, 85 MiB/s from an x64 client and 64 MiB/s from an x86 client; baud-rate emulation
delivered 960 bytes at 9600 8N1 in 1.00-1.01 s (0.000 s without it); hub4com moved 256 KiB through a serial
bridge in about 120-140 ms; `setupg.exe` runs as a native ARM64 process (`IsWow64Process2`: not emulated).

**Installer, `tests\test-installer.ps1`: 28 checks, 0 failed, on two consecutive runs.**

The final build was produced after a comment-only change to `comport.inf` that followed the 301-check run. It was
reinstalled and re-verified with `test-arm64.ps1 -Quick` (106 checks, 0 failed) and the installer test above; the
binaries are otherwise the ones the full run covered.

Things the testing found and that are already fixed in this tree: the admin manifest conflict in `setupc`/`setupg`
(see above), `COM#` pairs failing on 25H2 (`comport.inf`), and an install sequence that skipped `preinstall`
(`install-arm64.ps1` now does what the official installer does: `preinstall`, `update`, `infclean`).
