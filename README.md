# gadgets-layout

Remembers where your Windows Sidebar / [8GadgetPack](https://8gadgetpack.net/) gadgets belong for each monitor setup, and puts them back automatically when the monitor layout changes (docking, undocking, plugging in an external display).

Sidebar gadget positions are stored as absolute coordinates, so they end up in the wrong place or off-screen when the monitor arrangement changes. This script keeps one saved layout per monitor arrangement and restores the matching one.

## How it works

- **Monitor signature** – the current monitor layout is described by the size and position of every screen, e.g. `1920x1080@-1920,487 | 5120x2160@0,0`. The script runs DPI-aware, so signatures use physical pixels.
- **Profiles** – `profiles.json` maps a profile name to a signature plus the X/Y position of each gadget (keyed as `<gadget file>#<instance>`, e.g. `myweather.gadget#1`).
- **Save** – positions are taken from the live gadget windows rather than `Settings.ini`, because on start the sidebar silently pulls any gadget overlapping a monitor edge fully onto the monitor holding most of it, without updating `Settings.ini`. Saved positions get the same adjustment, so a gadget reappears exactly where it was saved.
- **Apply** – the script closes the sidebar, rewrites the gadget drop-location values in `%LOCALAPPDATA%\Microsoft\Windows Sidebar\Settings.ini` (backing it up to `Settings.ini.bak-layout`), then restarts `sidebar.exe`.
- **Watch** – polls every 10 seconds and re-applies once a new layout has been stable for two polls, so transient states while docking are ignored.

## Requirements

- Windows with the Windows Sidebar / 8GadgetPack installed at `C:\Program Files\Windows Sidebar\sidebar.exe`
- Windows PowerShell 5.1 or later

## Usage

Arrange your gadgets, then run from this directory:

```powershell
# Save current gadget positions as profile "Home" for the CURRENT monitor layout
.\GadgetLayout.ps1 -Save Home

# Apply the profile matching the current monitor layout (restarts the sidebar)
.\GadgetLayout.ps1 -Apply

# Apply now, then keep watching for monitor layout changes
.\GadgetLayout.ps1 -Watch

# Show saved profiles and the current monitor signature
.\GadgetLayout.ps1 -List
```

Saving a profile replaces any other profile registered for the same monitor signature, so there is one layout per monitor arrangement.

### Run automatically at logon

`register-task.ps1` registers a scheduled task named `GadgetLayout` that runs `GadgetLayout.ps1 -Watch` hidden at logon, restarting up to 3 times on failure:

```powershell
.\register-task.ps1
```

To remove it: `Unregister-ScheduledTask -TaskName GadgetLayout -Confirm:$false`

## Files

| File | Purpose |
| --- | --- |
| `GadgetLayout.ps1` | Main script (save / apply / watch / list) |
| `register-task.ps1` | Registers the logon scheduled task |
| `profiles.json` | Saved profiles (machine-specific, git-ignored) |
| `state.json` | Last applied signature and profile (git-ignored) |
| `GadgetLayout.log` | Activity log (git-ignored) |

## Troubleshooting

- Check `GadgetLayout.log` – it records applied profiles, moved gadget counts, missing profiles (`no profile for [...]`) and failures.
- If nothing happens for a new monitor setup, run `-List` to see the current signature, arrange the gadgets and `-Save` a profile for it.
- To restore the previous sidebar settings, copy `Settings.ini.bak-layout` over `Settings.ini` while the sidebar is closed.
