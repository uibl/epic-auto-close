# SCRIPT RUN AS ADMIN
If (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]"Administrator"))
{
try {
    Start-Process PowerShell.exe -ArgumentList ("-NoProfile -ExecutionPolicy Bypass -File `"{0}`"" -f $PSCommandPath) -Verb RunAs -ErrorAction Stop
} catch {
    Write-Host "Failed to request Admin privileges: $($_.Exception.Message)" -ForegroundColor Red
    "$(Get-Date) - Elevation error:`n$($_ | Out-String)" | Out-File "$env:SystemDrive\Windows\Temp\EpicAutoClose_log.txt" -Append -Encoding UTF8
    Read-Host "Press Enter to close"
}
Exit}
$Host.UI.RawUI.WindowTitle = $myInvocation.MyCommand.Definition + " (Administrator)"
$Host.UI.RawUI.BackgroundColor = "Black"
Clear-Host

$serviceName = "EpicAutoClose"
$taskName    = "EpicAutoClose-Trigger"
$exePath = "$env:SystemDrive\Windows\EpicAutoCloseService.exe"
$csPath  = "$env:SystemDrive\Windows\EpicAutoCloseService.cs"
$logPath = "$env:SystemDrive\Windows\Temp\EpicAutoClose_log.txt"

function Resolve-EpicLauncherPath {
    $running = Get-Process -Name "EpicGamesLauncher" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($running -and $running.Path) { return $running.Path }

    $pf86 = ${env:ProgramFiles(x86)}
    $pf   = $env:ProgramFiles
    $candidates = @(
        "$pf86\Epic Games\Launcher\Portal\Binaries\Win64\EpicGamesLauncher.exe",
        "$pf86\Epic Games\Launcher\Portal\Binaries\Win32\EpicGamesLauncher.exe",
        "$pf\Epic Games\Launcher\Portal\Binaries\Win64\EpicGamesLauncher.exe",
        "$pf\Epic Games\Launcher\Portal\Binaries\Win32\EpicGamesLauncher.exe"
    )
    foreach ($p in $candidates) { if (Test-Path $p) { return $p } }

    $entry = Get-ChildItem "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall" -ErrorAction SilentlyContinue |
        Get-ItemProperty -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like "*Epic Games Launcher*" } | Select-Object -First 1
    if ($entry -and $entry.InstallLocation) {
        $g64 = Join-Path $entry.InstallLocation "Portal\Binaries\Win64\EpicGamesLauncher.exe"
        $g32 = Join-Path $entry.InstallLocation "Portal\Binaries\Win32\EpicGamesLauncher.exe"
        if (Test-Path $g64) { return $g64 }
        if (Test-Path $g32) { return $g32 }
    }
    return $null
}

Write-Host "1. Install and start Epic Auto-Close (runs when Epic Games Launcher opens)"
Write-Host "2. Stop and remove the tool completely"
Write-Host "3. Check detected games`n"

while ($true) {
$choice = Read-Host " "
if ($choice -match '^[1-3]$') {
switch ($choice) {
1 {

Clear-Host

$launcherPath = Resolve-EpicLauncherPath
if (-not $launcherPath) {
    Write-Host "Could not find EpicGamesLauncher.exe path - make sure it is installed, or run it once and try again." -ForegroundColor Red
    $pf86dbg = ${env:ProgramFiles(x86)}
    $pfdbg   = $env:ProgramFiles
    $dbg = "$(Get-Date) - Launcher path not found. Checked:`n" +
           "- Running process: $((Get-Process -Name 'EpicGamesLauncher' -ErrorAction SilentlyContinue).Path)`n" +
           "- $pf86dbg\Epic Games\Launcher\Portal\Binaries\Win64\EpicGamesLauncher.exe`n" +
           "- $pf86dbg\Epic Games\Launcher\Portal\Binaries\Win32\EpicGamesLauncher.exe`n" +
           "- $pfdbg\Epic Games\Launcher\Portal\Binaries\Win64\EpicGamesLauncher.exe`n" +
           "- $pfdbg\Epic Games\Launcher\Portal\Binaries\Win32\EpicGamesLauncher.exe`n" +
           "- Registry uninstall entry match: $((Get-ChildItem 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall' -ErrorAction SilentlyContinue | Get-ItemProperty -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like '*Epic Games Launcher*' } | Select-Object -First 1).InstallLocation)"
    $dbg | Out-File $logPath -Append -Encoding UTF8
    Write-Host "Details saved here: $logPath" -ForegroundColor Yellow
    Read-Host "Press Enter to close"
    exit
}
Write-Host "Detected path: $launcherPath"

try {

# create .cs file
$csfile = @'
using System;
using System.IO;
using System.Text.RegularExpressions;
using System.Collections.Generic;
using System.Diagnostics;
using System.ServiceProcess;
using System.ComponentModel;
using System.Configuration.Install;
using System.Management;
using System.Timers;
using System.Threading;
using System.Reflection;

[assembly: AssemblyVersion("1.0")]
[assembly: AssemblyProduct("Epic Auto-Close Service")]
namespace EpicAutoCloseService
{
    class WindowsService : ServiceBase
    {
        const string ManifestsPath = @"C:\ProgramData\Epic\EpicGamesLauncher\Data\Manifests";
        static readonly string[] LauncherProcesses = { "EpicGamesLauncher", "EpicWebHelper", "CrashReportClient" };
        const int RescanIntervalMs = 10 * 60 * 1000; // 10 minutes

        ManagementEventWatcher watcher;
        System.Timers.Timer rescanTimer;
        List<string> currentGames = new List<string>();
        readonly object lockObj = new object();

        public WindowsService()
        {
            this.ServiceName = "EpicAutoClose";
            this.EventLog.Log = "Application";
            this.CanStop = true;
            this.CanHandlePowerEvent = false;
            this.CanHandleSessionChangeEvent = false;
            this.CanPauseAndContinue = false;
            this.CanShutdown = false;
        }

        static void Main()
        {
            ServiceBase.Run(new WindowsService());
        }

        protected override void OnStart(string[] args)
        {
            base.OnStart(args);
            RefreshWatcher();

            rescanTimer = new System.Timers.Timer(RescanIntervalMs);
            rescanTimer.Elapsed += (s, e) => RefreshWatcher();
            rescanTimer.AutoReset = true;
            rescanTimer.Start();
        }

        protected override void OnStop()
        {
            if (rescanTimer != null)
            {
                rescanTimer.Stop();
                rescanTimer.Dispose();
            }
            StopWatcher();
            base.OnStop();
        }

        void RefreshWatcher()
        {
            List<string> games = ScanInstalledGames();

            lock (lockObj)
            {
                if (watcher != null && ListsEqual(games, currentGames))
                    return;

                currentGames = games;
                StopWatcher();

                if (currentGames.Count == 0)
                    return;

                try
                {
                    string namesClause = "TargetInstance.Name=\"" + String.Join("\" OR TargetInstance.Name=\"", currentGames.ToArray()) + "\"";
                    string query = "SELECT * FROM __InstanceCreationEvent WITHIN 0.5 WHERE (TargetInstance isa \"Win32_Process\") AND (" + namesClause + ")";
                    watcher = new ManagementEventWatcher(query);
                    watcher.EventArrived += Watcher_EventArrived;
                    watcher.Start();
                }
                catch (Exception ex)
                {
                    LogSafe("Failed to start watcher: " + ex.Message, EventLogEntryType.Error);
                }
            }
        }

        void StopWatcher()
        {
            if (watcher != null)
            {
                try { watcher.Stop(); watcher.Dispose(); } catch { }
                watcher = null;
            }
        }

        void Watcher_EventArrived(object sender, EventArrivedEventArgs e)
        {
            try
            {
                ManagementBaseObject process = (ManagementBaseObject)e.NewEvent.Properties["TargetInstance"].Value;
                string gameName = process.Properties["Name"].Value as string;

                CloseLauncher(gameName);

                ThreadPool.QueueUserWorkItem(_ => StopSelf());
            }
            catch (Exception ex)
            {
                LogSafe("Event handling error: " + ex.Message, EventLogEntryType.Warning);
            }
        }

        void CloseLauncher(string gameName)
        {
            bool closedAny = false;
            foreach (var procName in LauncherProcesses)
            {
                Process[] procs = Process.GetProcessesByName(procName);
                foreach (var p in procs)
                {
                    try { p.Kill(); closedAny = true; }
                    catch { }
                }
            }

            if (closedAny)
                LogSafe("Closed Epic Games Launcher (game: " + gameName + ")", EventLogEntryType.Information);
        }

        void StopSelf()
        {
            try
            {
                ServiceController sc = new ServiceController(this.ServiceName);
                sc.Stop();
            }
            catch (Exception ex)
            {
                LogSafe("Self-stop failed: " + ex.Message, EventLogEntryType.Warning);
            }
        }

        List<string> ScanInstalledGames()
        {
            List<string> result = new List<string>();
            try
            {
                if (!Directory.Exists(ManifestsPath))
                    return result;

                foreach (var file in Directory.GetFiles(ManifestsPath, "*.item"))
                {
                    try
                    {
                        string content = File.ReadAllText(file);
                        Match match = Regex.Match(content, "\"LaunchExecutable\"\\s*:\\s*\"([^\"]*)\"");
                        if (match.Success)
                        {
                            string exeName = Path.GetFileName(match.Groups[1].Value);
                            if (!String.IsNullOrEmpty(exeName) && !ContainsIgnoreCase(result, exeName))
                                result.Add(exeName);
                        }
                    }
                    catch { }
                }
            }
            catch (Exception ex)
            {
                LogSafe("Manifest scan error: " + ex.Message, EventLogEntryType.Warning);
            }
            return result;
        }

        static bool ContainsIgnoreCase(List<string> list, string value)
        {
            foreach (var item in list)
                if (String.Equals(item, value, StringComparison.OrdinalIgnoreCase))
                    return true;
            return false;
        }

        static bool ListsEqual(List<string> a, List<string> b)
        {
            if (a.Count != b.Count) return false;
            List<string> sortedA = new List<string>(a);
            List<string> sortedB = new List<string>(b);
            sortedA.Sort(StringComparer.OrdinalIgnoreCase);
            sortedB.Sort(StringComparer.OrdinalIgnoreCase);
            for (int i = 0; i < sortedA.Count; i++)
            {
                if (!String.Equals(sortedA[i], sortedB[i], StringComparison.OrdinalIgnoreCase))
                    return false;
            }
            return true;
        }

        void LogSafe(string message, EventLogEntryType type)
        {
            if (this.EventLog != null)
            {
                try { this.EventLog.WriteEntry(message, type); } catch { }
            }
        }
    }

    [RunInstaller(true)]
    public class WindowsServiceInstaller : Installer
    {
        public WindowsServiceInstaller()
        {
            ServiceProcessInstaller serviceProcessInstaller = new ServiceProcessInstaller();
            ServiceInstaller serviceInstaller = new ServiceInstaller();
            serviceProcessInstaller.Account = ServiceAccount.LocalSystem;
            serviceProcessInstaller.Username = null;
            serviceProcessInstaller.Password = null;
            serviceInstaller.DisplayName = "Epic Auto-Close Service";
            serviceInstaller.StartType = ServiceStartMode.Manual;
            serviceInstaller.ServiceName = "EpicAutoClose";
            this.Installers.Add(serviceProcessInstaller);
            this.Installers.Add(serviceInstaller);
        }
    }
}
'@
Set-Content -Path $csPath -Value $csfile -Force

# compile
$compileOut = "$env:SystemDrive\Windows\Temp\EpicAutoCloseService_compile.log"
$compileErr = "$env:SystemDrive\Windows\Temp\EpicAutoCloseService_compile_err.log"
Remove-Item $compileOut, $compileErr -ErrorAction SilentlyContinue | Out-Null
$compileProc = Start-Process -Wait -PassThru -NoNewWindow "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe" -ArgumentList "-nologo -out:$exePath $csPath" -RedirectStandardOutput $compileOut -RedirectStandardError $compileErr

if ($compileProc.ExitCode -ne 0 -or -not (Test-Path $exePath)) {
    $compileText = ""
    if (Test-Path $compileOut) { $compileText += (Get-Content $compileOut -Raw) }
    if (Test-Path $compileErr) { $compileText += (Get-Content $compileErr -Raw) }
    throw "C# compile failed (exit code $($compileProc.ExitCode)):`n$compileText"
}

# remove cs file
Remove-Item $csPath -ErrorAction SilentlyContinue | Out-Null

# remove old service if exists
if (Get-Service -Name $serviceName -ErrorAction SilentlyContinue) {
sc.exe delete $serviceName | Out-Null
Start-Sleep -Seconds 2
}

# install service as Manual (no auto-start with Windows)
New-Service -Name $serviceName -BinaryPathName $exePath -DisplayName "Epic Auto-Close Service" -StartupType Manual -ErrorAction Stop | Out-Null

# enable process-creation auditing (needed to detect when EpicGamesLauncher.exe opens)
auditpol /set /subcategory:"Process Creation" /success:enable | Out-Null

# remove old task if exists
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

# build event trigger: fires when EpicGamesLauncher.exe starts
$eventXPath = @"
<QueryList>
  <Query Id="0" Path="Security">
    <Select Path="Security">*[System[(EventID=4688)]] and *[EventData[Data[@Name='NewProcessName']='$launcherPath']]</Select>
  </Query>
</QueryList>
"@

$triggerClass = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace Root/Microsoft/Windows/TaskScheduler
$trigger = New-CimInstance -CimClass $triggerClass -ClientOnly
$trigger.Subscription = $eventXPath
$trigger.Enabled = $true

$action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\sc.exe" -Argument "start $serviceName"
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

Register-ScheduledTask -TaskName $taskName -Trigger $trigger -Action $action -Principal $principal -Force -ErrorAction Stop | Out-Null

} catch {
    Write-Host "`nAn error occurred during installation:" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    "$(Get-Date) - Install error:`n$($_ | Out-String)" | Out-File $logPath -Append -Encoding UTF8
    Write-Host "Full details saved here: $logPath" -ForegroundColor Yellow
}

Read-Host "`nPress Enter to close"
exit

          }
        2 {

Clear-Host

try {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Stop-Service -Name $serviceName -ErrorAction SilentlyContinue
    sc.exe delete $serviceName | Out-Null
    Remove-Item $exePath -Force -ErrorAction SilentlyContinue | Out-Null
    auditpol /set /subcategory:"Process Creation" /success:disable | Out-Null

    Write-Host "`nService, task removed, and auditing setting reverted to default." -ForegroundColor Green
} catch {
    Write-Host "`nAn error occurred during removal:" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    "$(Get-Date) - Uninstall error:`n$($_ | Out-String)" | Out-File $logPath -Append -Encoding UTF8
    Write-Host "Full details saved here: $logPath" -ForegroundColor Yellow
}

Read-Host "`nPress Enter to close"
exit

          }
        3 {

Clear-Host

$manifestsPath = "$env:ProgramData\Epic\EpicGamesLauncher\Data\Manifests"

if (-not (Test-Path $manifestsPath)) {
    Write-Host "Manifests folder not found: $manifestsPath" -ForegroundColor Red
} else {
    $games = @()
    Get-ChildItem $manifestsPath -Filter "*.item" -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $json = Get-Content $_.FullName -Raw -ErrorAction Stop | ConvertFrom-Json
            if ($json.LaunchExecutable) {
                $games += [PSCustomObject]@{
                    Game    = $json.DisplayName
                    Process = (Split-Path $json.LaunchExecutable -Leaf)
                }
            }
        } catch { }
    }

    if ($games.Count -eq 0) {
        Write-Host "No games detected from Epic manifests." -ForegroundColor Yellow
    } else {
        Write-Host "Detected games (these are the processes being watched):`n" -ForegroundColor Green
        $games | Format-Table -AutoSize | Out-String | Write-Host
    }
}

Read-Host "`nPress Enter to close"
exit

          }
        } } else { Write-Host "Invalid choice. Pick 1, 2 or 3." } }
