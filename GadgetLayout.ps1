<#
.SYNOPSIS
  Per-monitor-setup gadget positions for the Windows Sidebar / 8GadgetPack.

  GadgetLayout.ps1 -Save home     Save current gadget positions as profile "home" for the CURRENT monitor layout
  GadgetLayout.ps1 -Apply         Apply the profile matching the current monitor layout (restarts the sidebar)
  GadgetLayout.ps1 -Watch         Apply now, then poll and re-apply whenever the monitor layout changes (for the scheduled task)
  GadgetLayout.ps1 -List          Show profiles and the current monitor signature
#>
param([string]$Save, [switch]$Apply, [switch]$Watch, [switch]$List, [switch]$Force)

$ErrorActionPreference = 'Stop'
$dir      = $PSScriptRoot
$profiles = Join-Path $dir 'profiles.json'
$state    = Join-Path $dir 'state.json'
$log      = Join-Path $dir 'GadgetLayout.log'
$ini      = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Sidebar\Settings.ini'
$sidebar  = 'C:\Program Files\Windows Sidebar\sidebar.exe'

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type @'
using System; using System.Text; using System.Collections.Generic; using System.Runtime.InteropServices;
public static class GadgetWin32 {
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr c);
    [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr c);
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc p, IntPtr l);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int L, T, R, B; }
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    // visible gadget frame windows ("BasicWindow") of the given processes as { x, y, width, height }
    public static List<int[]> GadgetFrames(uint[] pids) {
        var res = new List<int[]>(); var set = new HashSet<uint>(pids);
        EnumWindows((h, l) => {
            uint pid; GetWindowThreadProcessId(h, out pid);
            var cls = new StringBuilder(64); RECT r;
            if (set.Contains(pid) && IsWindowVisible(h) && GetClassName(h, cls, 64) > 0 && cls.ToString() == "BasicWindow" && GetWindowRect(h, out r))
                res.Add(new[] { r.L, r.T, r.R - r.L, r.B - r.T });
            return true; }, IntPtr.Zero);
        return res;
    }
}
'@
# physical pixels, same units as Settings.ini; the thread call also works when the host process already has an awareness set
[void][GadgetWin32]::SetProcessDpiAwarenessContext([IntPtr](-4))
[void][GadgetWin32]::SetThreadDpiAwarenessContext([IntPtr](-4))

function Write-Log($m) { Add-Content -LiteralPath $log -Value ("{0:s} {1}" -f (Get-Date), $m) }

function Get-Signature {
    ([System.Windows.Forms.Screen]::AllScreens | ForEach-Object {
        $b = $_.Bounds; '{0}x{1}@{2},{3}' -f $b.Width, $b.Height, $b.X, $b.Y
    } | Sort-Object) -join ' | '
}

function Read-Ini {
    $fs = [IO.File]::Open($ini, 'Open', 'Read', 'ReadWrite')   # the running sidebar keeps the file open
    try { $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::Unicode); $t = $sr.ReadToEnd() -replace "(`r?`n)+\z", ""; $t -split "`r?`n" } finally { $fs.Close() }
}
function Save-Ini($lines) {
    [IO.File]::WriteAllLines($ini, $lines, (New-Object Text.UnicodeEncoding($false, $true)))
}

# Live gadget sections -> @{ Key = "file.gadget#n"; XLine = idx; YLine = idx; X; Y }
function Get-GadgetEntries($lines) {
    $entries = @(); $count = @{}; $cur = $null
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $l = $lines[$i]
        if ($l -match '^\[Section \d+\]') { $cur = $null; continue }
        if ($l -match '^PrivateSetting_GadgetName="(.*)"') {
            $path = [Uri]::UnescapeDataString($Matches[1])
            if (-not (Test-Path -LiteralPath $path)) { $cur = $null; continue }   # stale entry from another profile
            $name = (Split-Path $path -Leaf).ToLowerInvariant()
            $count[$name] = 1 + [int]$count[$name]
            $cur = @{ Key = "$name#$($count[$name])"; XLine = -1; YLine = -1 }
            $entries += $cur
        }
        elseif ($cur -and $l -match '^PrivateSetting_GadgetDropLocationX="(-?\d+)"') { $cur.XLine = $i; $cur.X = [int]$Matches[1] }
        elseif ($cur -and $l -match '^PrivateSetting_GadgetDropLocationY="(-?\d+)"') { $cur.YLine = $i; $cur.Y = [int]$Matches[1] }
    }
    $entries | Where-Object { $_.XLine -ge 0 -and $_.YLine -ge 0 }
}

# On start the sidebar pulls a gadget that overlaps a monitor edge fully into the work area of the monitor holding most
# of it, without updating Settings.ini. Do the same here so a saved position is exactly where the gadget will appear.
function Get-ClampedPosition($x, $y, $w, $h) {
    $rect = New-Object System.Drawing.Rectangle $x, $y, $w, $h
    $best = $null; $bestArea = 0
    foreach ($s in [System.Windows.Forms.Screen]::AllScreens) {
        $i = [System.Drawing.Rectangle]::Intersect($s.Bounds, $rect)
        if ($i.Width * $i.Height -gt $bestArea) { $bestArea = $i.Width * $i.Height; $best = $s.WorkingArea }
    }
    if (-not $best) { return $x, $y }   # entirely off-screen: leave it to the sidebar
    [Math]::Max($best.Left, [Math]::Min($x, $best.Right - $w)), [Math]::Max($best.Top, [Math]::Min($y, $best.Bottom - $h))
}

# Gadget entries with X/Y replaced by the on-screen position of the matching live gadget window (nearest one), clamped.
function Get-LivePositions($entries) {
    $pids = @(Get-Process sidebar -ErrorAction SilentlyContinue | ForEach-Object { [uint32]$_.Id })
    $frames = New-Object System.Collections.ArrayList
    if ($pids) { $frames.AddRange([GadgetWin32]::GadgetFrames($pids)) }
    foreach ($e in $entries) {
        $f = $frames | Sort-Object { [Math]::Abs($_[0] - $e.X) + [Math]::Abs($_[1] - $e.Y) } | Select-Object -First 1
        if ($f) { $frames.Remove($f); $e.X, $e.Y = Get-ClampedPosition $f[0] $f[1] $f[2] $f[3] }
        else { Write-Warning "no window for $($e.Key), saving its Settings.ini position" }
        $e
    }
}

function Load-Profiles {
    if (Test-Path $profiles) { Get-Content $profiles -Raw | ConvertFrom-Json } else { [pscustomobject]@{} }
}

function Stop-Sidebar { Get-Process sidebar -ErrorAction SilentlyContinue | ForEach-Object { [void]$_.CloseMainWindow() }
    Start-Sleep -Seconds 2
    Get-Process sidebar -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 1 }

function Start-Sidebar {
    for ($try = 1; $try -le 3; $try++) {
        $p = Start-Process $sidebar -ArgumentList '/autoRun' -PassThru
        Start-Sleep -Seconds 15
        if (-not $p.HasExited) { return }
        Write-Log "sidebar exited early (code $($p.ExitCode)), retry $try"
    }
}

function Apply-Profile {
    $sig = Get-Signature
    $all = Load-Profiles
    $match = $all.PSObject.Properties | Where-Object { $_.Value.signature -eq $sig } | Select-Object -First 1
    if (-not $match) { if ($script:noProfileSig -ne $sig) { Write-Log "no profile for [$sig]"; $script:noProfileSig = $sig }; return }
    $last = if (Test-Path $state) { (Get-Content $state -Raw | ConvertFrom-Json).signature } else { $null }
    if ($last -eq $sig -and -not $Force) { return }

    Write-Log "applying '$($match.Name)' for [$sig]"
    Stop-Sidebar
    $lines = Read-Ini
    $pos = @{}; foreach ($g in $match.Value.gadgets) { $pos[$g.key] = $g }
    $changed = 0
    foreach ($e in (Get-GadgetEntries $lines)) {
        $g = $pos[$e.Key]; if (-not $g) { continue }
        $lines[$e.XLine] = 'PrivateSetting_GadgetDropLocationX="{0}"' -f $g.x
        $lines[$e.YLine] = 'PrivateSetting_GadgetDropLocationY="{0}"' -f $g.y
        $changed++
    }
    Copy-Item -LiteralPath $ini -Destination "$ini.bak-layout" -Force
    Save-Ini $lines
    @{ signature = $sig; profile = $match.Name } | ConvertTo-Json | Set-Content $state
    Write-Log "moved $changed gadgets"
    Start-Sidebar
}

if ($List) {
    "Current: $(Get-Signature)"
    (Load-Profiles).PSObject.Properties | ForEach-Object { "{0}: {1} ({2} gadgets)" -f $_.Name, $_.Value.signature, @($_.Value.gadgets).Count }
    return
}

if ($Save) {
    $entries = @(Get-LivePositions @(Get-GadgetEntries (Read-Ini)))
    $all = Load-Profiles
    $obj = [ordered]@{}; $all.PSObject.Properties | ForEach-Object { $obj[$_.Name] = $_.Value }
    # one layout per signature: drop any other profile registered for this exact monitor layout
    $sig = Get-Signature
    foreach ($k in @($obj.Keys)) { if ($obj[$k].signature -eq $sig -and $k -ne $Save) { $obj.Remove($k) } }
    $obj[$Save] = @{ signature = $sig; gadgets = @($entries | ForEach-Object { @{ key = $_.Key; x = $_.X; y = $_.Y } }) }
    $obj | ConvertTo-Json -Depth 6 | Set-Content $profiles
    @{ signature = $sig; profile = $Save } | ConvertTo-Json | Set-Content $state
    "Saved '$Save' for [$sig]: $(@($entries).Count) gadgets"
    return
}

if ($Apply) { $Force = $true; Apply-Profile; return }

if ($Watch) {
    $Force = $true    # at logon, apply regardless of the last-applied state
    try { Apply-Profile } catch { Write-Log "apply failed: $_" }
    $Force = $false
    $seen = Get-Signature
    while ($true) {
        Start-Sleep -Seconds 10
        $now = Get-Signature
        # act only once the layout has been stable for two polls (docking raises several transient states)
        if ($now -eq $seen) { try { Apply-Profile } catch { Write-Log "apply failed: $_" } }
        $seen = $now
    }
}
