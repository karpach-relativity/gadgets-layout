<#
.SYNOPSIS
  Diagnostic: prints the monitors and every visible sidebar.exe window with its on-screen rectangle (physical pixels).
  Compare the BasicWindow rows with PrivateSetting_GadgetDropLocationX/Y in Settings.ini to see where gadgets really are.

  Run in a fresh process so the DPI awareness and screen list are current:
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\Show-GadgetWindows.ps1
#>
Add-Type @'
using System; using System.Text; using System.Collections.Generic; using System.Runtime.InteropServices;
public static class GadgetWindows {
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr c);
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc p, IntPtr l);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int L, T, R, B; }
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern uint GetDpiForWindow(IntPtr h);
    public static List<string> List(uint target) {
        var res = new List<string>();
        EnumWindows((h, l) => {
            uint pid; GetWindowThreadProcessId(h, out pid);
            if (pid == target && IsWindowVisible(h)) {
                var cls = new StringBuilder(256); GetClassName(h, cls, 256);
                var title = new StringBuilder(256); GetWindowText(h, title, 256);
                RECT r; GetWindowRect(h, out r);
                res.Add(String.Format("{0,-24} [{1}] L={2} T={3} W={4} H={5} dpi={6}", cls, title, r.L, r.T, r.R - r.L, r.B - r.T, GetDpiForWindow(h)));
            }
            return true; }, IntPtr.Zero);
        return res;
    }
}
'@
[void][GadgetWindows]::SetProcessDpiAwarenessContext([IntPtr](-4))
Add-Type -AssemblyName System.Windows.Forms
[System.Windows.Forms.Screen]::AllScreens | ForEach-Object { "screen $($_.DeviceName) bounds=$($_.Bounds) work=$($_.WorkingArea)" }
$p = Get-Process sidebar -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $p) { 'sidebar.exe is not running'; return }
[GadgetWindows]::List([uint32]$p.Id)
