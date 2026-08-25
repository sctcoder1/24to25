# Windows 11 24H2 to 25H2 via Sophos Live Action

This repository provides a self-healing, unattended upgrade for eligible Windows 11 24H2 devices. It runs as `SYSTEM`, scans Microsoft's public Microsoft Update service directly (not the device's managed WSUS source), installs a current non-preview 24H2 cumulative update when the 25H2 prerequisite is missing, and then installs **Windows 11, version 25H2**.

Microsoft requires Windows 11 24H2 build **26100.5074** (KB5064081) or a later cumulative update before the 25H2 enablement package (KB5054156) can be applied. The script discovers the currently applicable, non-preview cumulative update at run time instead of hard-coding a monthly KB.

## Behavior

- Targets only Windows 11 24H2 (build 26100). Other operating systems and releases exit without modification.
- Uses a small BAT launcher, following the proven Sophos Live Action pattern: Sophos only downloads files, creates two highest-privilege `SYSTEM` tasks with `schtasks.exe`, starts one, and exits immediately.
- The two tasks run at startup and every three hours; both launch the BAT, which runs the PowerShell workflow outside the Sophos Live Action process.
- Uses both task-level `IgnoreNew` handling and a global mutex to prevent overlapping runs.
- Keeps the script, state, and append-only log in `C:\ProgramData\Win11-25H2`.
- Never restarts immediately. When a restart is needed, it warns all interactive users and schedules the restart for 60 minutes later.
- Retries after failures, safeguard holds, network outages, or update-service errors.
- After a reboot verifies 25H2 from the operating-system registry, removes both scheduled tasks, and retains the script/log/state for audit.

## Sophos Live Action deployment

Copy the command from [`Sophos-Live-Action-One-Liner.txt`](Sophos-Live-Action-One-Liner.txt) and run it as a **CMD** command in Sophos Live Action. It downloads the pinned [`Upgrade-25H2.ps1`](Upgrade-25H2.ps1) and [`Win11-25H2-Launcher.bat`](Win11-25H2-Launcher.bat), verifies both files, creates the SYSTEM startup and three-hour retry tasks with `schtasks.exe`, starts the first task, and then returns control to Sophos immediately.

The same command is shown here for reference:

```cmd
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop';$r='C:\ProgramData\Win11-25H2';$ps=Join-Path $r 'Upgrade-25H2.ps1';$bat=Join-Path $r 'Win11-25H2-Launcher.bat';$st=Join-Path $env:SystemRoot 'System32\schtasks.exe';New-Item -ItemType Directory -Path $r -Force|Out-Null;[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12;iwr -UseBasicParsing 'https://raw.githubusercontent.com/sctcoder1/24to25/04e1e8e75c3c03586d832290ee52c1f48c714e10/Upgrade-25H2.ps1' -OutFile $ps;iwr -UseBasicParsing 'https://raw.githubusercontent.com/sctcoder1/24to25/04e1e8e75c3c03586d832290ee52c1f48c714e10/Win11-25H2-Launcher.bat' -OutFile $bat;if((Get-FileHash -Algorithm SHA256 $ps).Hash -ne 'FE151F18A4E29927CB42A33533F56DE34FAF222D19F70642B433A671DF51E416'){throw 'Upgrade-25H2.ps1 SHA256 mismatch'};if((Get-FileHash -Algorithm SHA256 $bat).Hash -ne '1ECFA11C3798D894DE76AA369025CD901162D9DFF0FC95BA1E3891E02212D42D'){throw 'Win11-25H2-Launcher.bat SHA256 mismatch'};& $st /Delete /TN 'Win11-25H2-AtStartup' /F 2>$null|Out-Null;& $st /Delete /TN 'Win11-25H2-Retry' /F 2>$null|Out-Null;& $st /Create /TN 'Win11-25H2-AtStartup' /TR 'cmd.exe /d /c C:\ProgramData\Win11-25H2\Win11-25H2-Launcher.bat' /SC ONSTART /RU SYSTEM /RL HIGHEST /F|Out-Null;if($LASTEXITCODE){throw 'Failed to create startup task'};& $st /Create /TN 'Win11-25H2-Retry' /TR 'cmd.exe /d /c C:\ProgramData\Win11-25H2\Win11-25H2-Launcher.bat' /SC HOURLY /MO 3 /RU SYSTEM /RL HIGHEST /F|Out-Null;if($LASTEXITCODE){throw 'Failed to create retry task'};& $st /Run /TN 'Win11-25H2-Retry'|Out-Null;if($LASTEXITCODE){throw 'Failed to start upgrade task'};Write-Output 'Scheduled SYSTEM upgrade tasks created and first run started.'"
```

The one-liner downloads only the file at a pinned commit, verifies its SHA256 before execution, installs the scheduled tasks, and starts the first run. Do not use a `main` branch URL for production deployment.

## Verification and audit

On an endpoint, review:

```powershell
Get-Content C:\ProgramData\Win11-25H2\Upgrade-25H2.log -Tail 100
Get-Content C:\ProgramData\Win11-25H2\Launcher.log -Tail 50
Get-Content C:\ProgramData\Win11-25H2\state.json
Get-ScheduledTask Win11-25H2-AtStartup,Win11-25H2-Retry -ErrorAction SilentlyContinue
```

Successful completion is recorded as `Complete` in `state.json`. The two tasks should then be absent; retained files provide the audit trail.

## Operational notes

- Windows 11 may retain a legacy `ProductName` registry value such as `Windows 10 Pro`. The script therefore validates the client installation type, release, and build instead of relying on that misleading label.
- A device must be able to reach Microsoft Update endpoints. Policies that prohibit dual scan or public Microsoft Update access can prevent this workflow from scanning; failures remain logged and retry automatically.
- Microsoft may withhold 25H2 because of a safeguard hold. This script does not bypass compatibility safeguards.
- The restart command uses Windows' native scheduled-restart notification plus `msg.exe` for a clear 60-minute warning to logged-on users.
- Test on a representative device group before broad production rollout.

## Microsoft references

- [KB5054156: Feature update to Windows 11, version 25H2 by using an enablement package](https://support.microsoft.com/en-us/topic/kb5054156-feature-update-to-windows-11-version-25h2-by-using-an-enablement-package-4d307e2d-3028-4323-bb46-552cff491643)
- [How Windows Update works (service IDs and scan sources)](https://learn.microsoft.com/windows/deployment/update/how-windows-update-works)
- [Windows Update Agent API](https://learn.microsoft.com/windows/win32/api/_wua/)
