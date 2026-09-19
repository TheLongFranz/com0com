## Windows on ARM (ARM64) fork

This fork adds native **Windows 11 on ARM64** support to com0com: the kernel driver, `setupc` and the `setupg`
GUI, hub4com, an installer, reproducible build scripts and a test suite.

**See [`source/com0com-3.0.0.0/ARM64.md`](source/com0com-3.0.0.0/ARM64.md)** for how to build, install and test it,
what was changed compared with upstream, and the known limitations.

The ARM64 driver is **test-signed** (it needs Windows test-signing mode), and the prebuilt binaries in the top-level
folder are the original x86/x64 releases, not ARM64 ones. To use com0com on ARM64, build it from
`source/com0com-3.0.0.0` as described in `ARM64.md`.

### Credits and AI disclosure

* **com0com and hub4com were written by Vyacheslav Frolov** and are released under the GNU General Public License
  (see [`source/com0com-3.0.0.0/license.txt`](source/com0com-3.0.0.0/license.txt)). The original project is at
  http://com0com.sourceforge.net/, and this repository is forked from
  [vovsoft/com0com](https://github.com/vovsoft/com0com). All of the upstream code remains their work; this fork
  only adds ARM64 support on top of it.
* **The ARM64 support was developed with [Claude Code](https://claude.com/claude-code)**, Anthropic's AI coding
  assistant, directed by the repository owner. That covers the INF changes, the build, install and test scripts, the
  test tools, the installer changes and the documentation. The commits carry a `Co-Authored-By` line for that reason.
* It has been tested on a single Windows 11 ARM64 virtual machine, and the driver is only test-signed. The limits
  are listed in `ARM64.md`.

## com0com

Null-modem emulator (com0com) is an open source kernel-mode virtual serial port driver for Windows, available freely under GPL license.

The HUB for communications (hub4com) is a Windows application and is a part of the com0com project.

The homepage of the original com0com project is http://com0com.sourceforge.net/.

How to use: https://vovsoft.com/blog/how-to-sniff-serial-port-communication/
