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

Add-Type -AssemblyName System.Windows.Forms
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class DpiAware { [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr c); }
'@
[void][DpiAware]::SetProcessDpiAwarenessContext([IntPtr](-4))   # physical pixels, so signatures don't depend on scaling quirks

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
    $entries = Get-GadgetEntries (Read-Ini)
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
