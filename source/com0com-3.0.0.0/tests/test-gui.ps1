<#
.SYNOPSIS
    End-to-end test of setupg.exe (the GUI): add a pair, rename its ports, apply, move data over
    the new ports, remove the pair again. Must run elevated, in Windows PowerShell 5.1 (powershell.exe).

.PARAMETER PortA / PortB   Names given to the new pair through the GUI.
.PARAMETER ScreenshotDir   Where to save PNG screenshots (default: arm64\tests\screenshots).
#>
param(
    [string]$PortA = 'COM51',
    [string]$PortB = 'COM52',
    [string]$ScreenshotDir
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$pkg  = Join-Path $root 'arm64\package'
$exe  = Join-Path $pkg 'setupg.exe'
$ctest = Join-Path $root 'arm64\tests\c0ctest-arm64.exe'
if (-not $ScreenshotDir) { $ScreenshotDir = Join-Path $root 'arm64\tests\screenshots' }
New-Item -ItemType Directory -Force $ScreenshotDir | Out-Null

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run elevated.' }

Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System; using System.Collections.Generic; using System.Text; using System.Runtime.InteropServices;
using System.Drawing; using System.Drawing.Imaging;
public static class G {
  delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr p, EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, string l);
  [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr h, IntPtr dc, uint f);
  [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("kernel32.dll")] public static extern bool IsWow64Process2(IntPtr h, out ushort proc, out ushort native);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }

  public class Ctl { public IntPtr H; public string Cls, Text; public int X, Y; }
  static string Txt(IntPtr h) { var s = new StringBuilder(256); GetWindowText(h, s, 256); return s.ToString(); }
  static string Cls(IntPtr h) { var s = new StringBuilder(128); GetClassName(h, s, 128); return s.ToString(); }
  public static List<Ctl> Children(IntPtr parent) {
    var l = new List<Ctl>();
    EnumChildWindows(parent, (h, x) => { RECT r; GetWindowRect(h, out r); l.Add(new Ctl { H = h, Cls = Cls(h), Text = Txt(h), X = r.L, Y = r.T }); return true; }, IntPtr.Zero);
    return l;
  }
  // visible top-level dialogs (#32770) of a process
  public static List<IntPtr> Dialogs(uint pid) {
    var l = new List<IntPtr>();
    EnumWindows((h, x) => { uint p; GetWindowThreadProcessId(h, out p); if (p == pid && IsWindowVisible(h) && Cls(h) == "#32770") l.Add(h); return true; }, IntPtr.Zero);
    return l;
  }
  public static string Title(IntPtr h) { return Txt(h); }
  public static void SetText(IntPtr h, string t) { SendMessage(h, 0x000C /*WM_SETTEXT*/, IntPtr.Zero, t); }
  public static void Click(IntPtr h) { PostMessage(h, 0x00F5 /*BM_CLICK*/, IntPtr.Zero, IntPtr.Zero); }
  public static void Shot(IntPtr h, string path) {
    RECT r; GetWindowRect(h, out r);
    using (var bmp = new Bitmap(r.R - r.L, r.B - r.T)) using (var g = Graphics.FromImage(bmp)) {
      IntPtr dc = g.GetHdc(); PrintWindow(h, dc, 2); g.ReleaseHdc(dc); bmp.Save(path, ImageFormat.Png); }
  }
}
'@

$script:pass = 0; $script:fail = 0
function Check($name, $ok, $detail = '') {
    if ($ok) { $script:pass++ } else { $script:fail++ }
    '  [{0}] {1,-58} {2}' -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $detail
}
function Get-Ports { @(Get-CimInstance Win32_SerialPort | ForEach-Object DeviceID) }
function Wait-Until([scriptblock]$cond, [int]$sec = 60) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $sec) { if (& $cond) { return $true }; Start-Sleep -Milliseconds 400 }
    return $false
}
function Find-Ctl($text, $cls) { [G]::Children($script:hwnd) | Where-Object { (-not $text -or $_.Text -eq $text) -and (-not $cls -or $_.Cls -like $cls) } }

Get-Process setupg -ErrorAction SilentlyContinue | Stop-Process -Force
$before = Get-Ports
"ports before: $($before -join ', ')"

$p = Start-Process $exe -WorkingDirectory $pkg -PassThru
try {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($p.MainWindowHandle -eq 0 -and $sw.Elapsed.TotalSeconds -lt 30 -and -not $p.HasExited) { Start-Sleep -Milliseconds 200; $p.Refresh() }
    Check 'setupg.exe starts and shows its window' ($p.MainWindowHandle -ne 0) "title '$($p.MainWindowTitle)'"
    $script:hwnd = $p.MainWindowHandle
    [uint16]$pm = 0; [uint16]$nm = 0
    [void][G]::IsWow64Process2($p.Handle, [ref]$pm, [ref]$nm)
    Check 'runs as a native ARM64 process (not emulated)' ($pm -eq 0 -and $nm -eq 0xAA64) ('process=0x{0:X} native=0x{1:X}' -f $pm, $nm)
    Start-Sleep 1

    # --- Add Pair ---
    $btnAdd = Find-Ctl 'Add Pair' 'WindowsForms10.BUTTON*' | Select-Object -First 1
    Check 'finds the "Add Pair" button' ($null -ne $btnAdd)
    [G]::Click($btnAdd.H)
    $added = Wait-Until { (Get-Ports).Count -ge $before.Count + 2 } 90
    $now = Get-Ports
    Check 'Add Pair creates two new ports' $added "ports: $($now -join ', ')"
    Start-Sleep 1
    [G]::Shot($script:hwnd, "$ScreenshotDir\gui-1-after-add.png")

    # --- rename the new pair's ports and Apply ---
    $edits = @(Find-Ctl $null 'WindowsForms10.EDIT*' | Sort-Object X)
    Check 'finds the two port-name boxes' ($edits.Count -eq 2) "count=$($edits.Count)"
    [G]::SetText($edits[0].H, $PortA)
    [G]::SetText($edits[1].H, $PortB)
    Start-Sleep -Milliseconds 500
    $btnApply = Find-Ctl 'Apply' 'WindowsForms10.BUTTON*' | Select-Object -First 1
    [G]::Click($btnApply.H)
    $renamed = Wait-Until { $ps = Get-Ports; ($ps -contains $PortA) -and ($ps -contains $PortB) } 90
    Check "Apply renames the ports to $PortA / $PortB" $renamed "ports: $((Get-Ports) -join ', ')"
    Start-Sleep 1
    [G]::Shot($script:hwnd, "$ScreenshotDir\gui-2-after-apply.png")

    # --- the GUI-made pair must actually carry data ---
    if ($renamed -and (Test-Path $ctest)) {
        $out = & $ctest $PortA $PortB 2>&1
        $last = ($out | Select-Object -Last 1)
        Check "c0ctest (arm64) over $PortA <-> $PortB" ($LASTEXITCODE -eq 0) $last
    }

    # --- Remove Pair (modal Yes/No prompt) ---
    $btnRem = Find-Ctl 'Remove Pair' 'WindowsForms10.BUTTON*' | Select-Object -First 1
    [G]::Click($btnRem.H)
    $dlg = $null
    Wait-Until { $script:d = [G]::Dialogs([uint32]$p.Id); $script:d.Count -gt 0 } 15 | Out-Null
    if ($script:d.Count -gt 0) {
        $dlg = $script:d[0]
        $kids = [G]::Children($dlg)
        Check 'Remove Pair asks for confirmation' $true ("'" + (($kids | Where-Object { $_.Cls -eq 'Static' }).Text -join ' ') + "'")
        $yes = $kids | Where-Object { $_.Text -match '^&?Yes$' } | Select-Object -First 1
        [G]::Click($yes.H)
    } else { Check 'Remove Pair asks for confirmation' $false 'no dialog appeared' }
    $gone = Wait-Until { $ps = Get-Ports; -not ($ps -contains $PortA) -and -not ($ps -contains $PortB) } 90
    Check 'Remove Pair deletes the ports' $gone "ports: $((Get-Ports) -join ', ')"
    Start-Sleep 1
    [G]::Shot($script:hwnd, "$ScreenshotDir\gui-3-after-remove.png")
    Check 'original pair is untouched' (($before | Where-Object { (Get-Ports) -notcontains $_ }).Count -eq 0) ''

    # --- close ---
    [void]$p.CloseMainWindow()
    $closed = $p.WaitForExit(8000)
    Check 'closes cleanly' ($closed -and $p.ExitCode -eq 0) $(if ($closed) { "exit code $($p.ExitCode)" } else { 'did not exit' })
}
finally {
    if (-not $p.HasExited) { $p.Kill() }
}
"`nGUI test: $script:pass passed, $script:fail failed"
exit $(if ($script:fail) { 1 } else { 0 })
