## Windows on ARM (ARM64) fork

This fork adds native **Windows 11 on ARM64** support to com0com: the kernel driver, `setupc` and the `setupg`
GUI, hub4com, an installer, reproducible build scripts and a test suite.

**See [`source/com0com-3.0.0.0/ARM64.md`](source/com0com-3.0.0.0/ARM64.md)** for how to build, install and test it,
what was changed compared with upstream, and the known limitations.

The ARM64 driver is **test-signed** (it needs Windows test-signing mode), and the prebuilt binaries in the top-level
folder are the original x86/x64 releases, not ARM64 ones. To use com0com on ARM64, build it from
`source/com0com-3.0.0.0` as described in `ARM64.md`.

## com0com

Null-modem emulator (com0com) is an open source kernel-mode virtual serial port driver for Windows, available freely under GPL license.

The HUB for communications (hub4com) is a Windows application and is a part of the com0com project.

The homepage of the original com0com project is http://com0com.sourceforge.net/.

How to use: https://vovsoft.com/blog/how-to-sniff-serial-port-communication/
