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

Open [`Sophos-Live-Action-One-Liner.txt`](Sophos-Live-Action-One-Liner.txt), choose **Raw**, and copy that single plain-text line into a **CMD** command in Sophos Live Action. Copying from rendered chat or Markdown can turn bare URLs into `[text](url)` links and break the command.

The bootstrap performs a clean reinstall before starting: it ends and deletes both tasks from earlier attempts, terminates only orphaned processes whose command lines point to this workflow, cancels a restart only when this workflow's state says it scheduled one, and removes `C:\ProgramData\Win11-25H2`. It then downloads the pinned [`Upgrade-25H2.ps1`](Upgrade-25H2.ps1) and [`Win11-25H2-Launcher.bat`](Win11-25H2-Launcher.bat), verifies both files, recreates the SYSTEM tasks, starts the BAT-backed retry task, and returns control to Sophos immediately.

The cleanup is deliberately scoped: it does not remove older projects such as `C:\Win11Upgrade`, unregister Microsoft Update, or purge the shared Windows Update cache.

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
