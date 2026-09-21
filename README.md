# Epic Auto-Close

Automatically closes the Epic Games Launcher the instant you launch a game
through it. No config file, no manual game list to maintain, and it doesn't
run at Windows startup — only when it's actually needed.

## How it works

1. **On-demand, not always-on.** The tool doesn't run at boot. It installs a
   Scheduled Task that watches for `EpicGamesLauncher.exe` starting (using
   Windows' built-in Process Creation auditing, Event ID 4688) and starts a
   background service only at that exact moment.
2. **Detects your games automatically.** Once running, the service reads
   Epic's own manifest files
   (`C:\ProgramData\Epic\EpicGamesLauncher\Data\Manifests\*.item`) to build
   the list of your installed games — nothing to type in manually. It
   rechecks every 10 minutes in case you install something new mid-session.
3. **Instant close.** Using a WMI event watcher, the moment one of those game
   processes starts, the service immediately closes `EpicGamesLauncher.exe`,
   `EpicWebHelper.exe`, and `CrashReportClient.exe`.
4. **Self-stops.** Right after closing the launcher, the service stops
   itself. Nothing lingers in the background between sessions.
5. **No external dependencies.** The service is a small C# Windows Service,
   compiled at install time using `csc.exe` — the compiler that ships with
   every Windows install as part of .NET Framework. No runtime to install,
   no third-party tools.

## Requirements

- Windows 10/11 with Epic Games Launcher installed
- .NET Framework (included with Windows by default)
- Administrator rights (needed once, at install time)

## Install

1. Download `EpicAutoClose_Install.ps1`.
2. Right-click it → **Run with PowerShell**, and accept the UAC prompt.
   - If nothing happens when you do this, see [Running the
     script](#running-the-script) below — it's almost always a script
     execution policy issue, not a bug.
3. Choose **1** to install.

That's it — just use Epic Games Launcher normally from now on. The tool
works silently in the background.

## Menu options

| Option | What it does |
|---|---|
| 1 | Installs and configures everything (service + scheduled task) |
| 2 | Fully removes the service and task, and reverts the audit setting |
| 3 | Lists the games currently detected from your Epic library |

## Running the script

Windows sometimes blocks `.ps1` files from running at all when double-clicked
or right-clicked, depending on the execution policy. If that happens, open
**PowerShell as Administrator** and run:

```powershell
powershell -ExecutionPolicy Bypass -File "C:\path\to\EpicAutoClose_Install.ps1"
```

The included `AllowScripts.cmd` is an optional helper that flips PowerShell's
execution policy to allow scripts system-wide and unblocks files in its
folder, if you'd rather fix this once instead of using `-ExecutionPolicy
Bypass` every time.

## Uninstall

Run the script again and choose **2**. This removes the service, the
scheduled task, and turns Process Creation auditing back off.

## Notes

- This enables Windows' built-in **Process Creation** auditing subcategory —
  a standard, documented Windows feature, not something exclusive to this
  tool. It's what lets the scheduled task detect the moment the launcher
  opens. It does add a small number of extra entries to the Security event
  log.
- Epic Games only, by design.
- Every closure is logged as a single line in the Windows Event Log
  (Application log, source: `EpicAutoClose`) with the game name and
  timestamp.

## License

MIT
