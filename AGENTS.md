# AGENTS.md

Guidance for AI coding agents working in this repo. User-facing docs are in `README.md`.

## What this is

A single Windows PowerShell 5.1 script, `GadgetLayout.ps1`, that saves and restores Windows Sidebar / 8GadgetPack gadget positions per monitor arrangement. `register-task.ps1` registers it as a hidden logon task (`-Watch`). There is no build, no dependencies beyond Windows and 8GadgetPack, and no automated test suite.

## Layout

| Path | Notes |
| --- | --- |
| `GadgetLayout.ps1` | Everything: `-Save <name>`, `-Apply`, `-Watch`, `-List`, `-Force` |
| `register-task.ps1` | Registers the `GadgetLayout` scheduled task |
| `tools/Show-GadgetWindows.ps1` | Diagnostic: monitors plus the real on-screen rect of every sidebar window |
| `profiles.json`, `state.json`, `GadgetLayout.log` | Per-machine runtime files, git-ignored. Never commit them |

## Facts that are not obvious from the code

- **Settings file**: `%LOCALAPPDATA%\Microsoft\Windows Sidebar\Settings.ini` is UTF-16 LE with a BOM and must be written back the same way (see `Save-Ini`). The running sidebar keeps it open, so read with `FileShare.ReadWrite`. Edits only take effect if the sidebar is stopped first, otherwise it overwrites them.
- **Gadget sections**: `[Root]` lists live sections as `SectionN="<id>"`. Each `[Section <id>]` has `PrivateSetting_GadgetName` (URL-encoded path to the `.gadget` folder) and `PrivateSetting_GadgetDropLocationX/Y`. Sections for uninstalled gadgets can linger; `Get-GadgetEntries` skips them. Gadgets are keyed `<file>.gadget#<instance>`.
- **Units**: `DropLocationX/Y` are physical screen pixels on every monitor, regardless of scaling. This was verified on a 100% and a 150% monitor. The script must be per-monitor DPI aware (`SetProcessDpiAwarenessContext` / `SetThreadDpiAwarenessContext(-4)`), or `Screen.AllScreens` and window rects come back in logical units.
- **The sidebar moves gadgets on start**: a gadget overlapping a monitor edge is moved fully into the work area of the monitor holding most of it, and `Settings.ini` is not updated. That is why `-Save` reads live window rects (`BasicWindow` class windows of `sidebar.exe`) and applies the same rule (`Get-ClampedPosition`) instead of trusting the ini. Each gadget also has a `SideBar_HTMLHostWindow`, inset inside its `BasicWindow`. Use `BasicWindow`, whose top-left equals DropLocation.
- **Stale screen data**: `Screen.AllScreens` is cached per process. Test monitor changes in a fresh `powershell.exe`, not a long-lived host.
- **Sidebar crashes**: on 5K monitors, `sidebar.exe` crashes intermittently on start (combase/ntdll/mshtml access violations, heap corruption). The trigger is 8GadgetPack's background DPI fix together with the Drives Meter and All CPU Meter gadgets. The workaround is `HKCU\Software\8GadgetPack\EnableDPIFixBackground = 0` (DWORD), which is also shipped as `C:\Program Files\Windows Sidebar\8GadgetPack\DPIFixBackground_Disable.reg`. This crash is not caused by this script; `Start-Sidebar` retries for that reason.

## Conventions

- Target Windows PowerShell 5.1, not just PowerShell 7: no ternaries, `??`, or `-Parallel`.
- Keep it a single dependency-free script. Win32 calls go through one inline `Add-Type` C# class.
- The style is terse: small functions, short comments explaining *why*. Match it.
- Log meaningful actions with `Write-Log` (to `GadgetLayout.log`), since `-Watch` runs hidden.

## Verifying changes

There are no unit tests. Verify on the real machine, and back up user state first:

```powershell
Copy-Item profiles.json $env:TEMP\profiles.json.bak
Copy-Item "$env:LOCALAPPDATA\Microsoft\Windows Sidebar\Settings.ini" $env:TEMP\Settings.ini.bak

powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\GadgetLayout.ps1 -List
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\GadgetLayout.ps1 -Save <name>
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\GadgetLayout.ps1 -Apply   # restarts sidebar, ~20 s
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Show-GadgetWindows.ps1
```

A correct round trip leaves the `BasicWindow` positions unchanged, and a second `-Save` produces identical `profiles.json` coordinates.

Be careful:

- `-Save <name>` replaces any other profile with the same monitor signature.
- `-Apply` and `-Watch` kill and restart the user's sidebar.
- Don't leave the `GadgetLayout` scheduled task registered or changed unless asked.
