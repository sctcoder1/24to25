# Forced Windows 11 23H2 to 25H2 through Sophos Live Action

This bundle is for x64, en-US Windows 11 23H2 client installations that are not
being offered a feature update by Windows Update.

The current Microsoft public retail-media API no longer exposes Windows 11
24H2. It exposes Windows 11 25H2 v2. Microsoft supports an in-place upgrade from
an older Windows 11 release using current installation media, so this worker
upgrades 23H2 directly to 25H2 instead of installing an obsolete intermediate
24H2 image.

## Files to upload to `sctcoder1/24to25`

Upload these files to the root of the repository, preserving their names:

1. `Upgrade-23H2-to-25H2-Forced.ps1`
2. `Sophos-Live-Action-23H2-Forced-One-Liner.txt`

Upload the worker first. Its required SHA256 is:

`636FA84CC5BCF4592109BFFA5FDFE3D2525B805BA0654B2067553129F67C43C1`

After both files are on GitHub, copy the entire single line from
`Sophos-Live-Action-23H2-Forced-One-Liner.txt` into Sophos Live Action CMD.

## How Sophos execution works

The Sophos command does not download the ISO or wait for Windows Setup. It:

1. Confirms the machine is Windows 11 23H2 build 22631.
2. Resolves the current GitHub `main` commit.
3. Downloads the worker from that immutable commit.
4. Verifies the worker SHA256 and parses its PowerShell syntax.
5. Runs the worker with `-Install`.
6. The worker creates SYSTEM tasks at startup and every three hours.
7. The worker starts the first task and returns control to Sophos.

The detached SYSTEM task performs the long-running operation. It uses a global
mutex and Task Scheduler's `IgnoreNew` setting to prevent overlapping runs.

## Fully automatic media path

The scheduled worker:

- removes only the previous owned 23H2 Windows-Update-only tasks;
- downloads the exact pinned Fido 1.70 script from commit
  `3d47260b8915385c58e20c73e24b36e9a9536f3f`;
- verifies Fido SHA256
  `24C86067FA399D2FD75EF0693A2EC79CA8DB162827F808CAAC03541CBF640C13`;
- asks Microsoft's download API for the current 25H2 x64 English retail ISO;
- accepts media URLs only from Microsoft's approved download hosts;
- downloads the ISO with BITS inside the scheduled task;
- requires a plausible 5-12 GB ISO size;
- mounts the ISO and validates Microsoft signatures on `setup.exe` and
  `sources\setupprep.exe`;
- requires `setup.exe` build 26200 before proceeding;
- runs Windows Setup's compatibility-only scan;
- starts a quiet in-place upgrade only when the scan reports compatibility;
- uses `/noreboot`, then displays a user warning and schedules a restart in ten
  minutes only after the online Setup phase succeeds;
- retries automatically after failures and at startup;
- verifies Windows 11 25H2 after reboot, removes its tasks, and removes the
  cached ISO while retaining the worker, state, and logs for audit.

The script sets Microsoft's `AllowUpgradesWithUnsupportedTPMOrCPU` MoSetup
allowance. It does not patch Microsoft binaries, replace `appraiserres.dll`,
clear reboot flags, disable Windows Update services, or suppress hard
application/driver compatibility blocks.

## Requirements and intentional stops

- Windows 11 23H2, build 22631
- x64
- Client installation
- Edition: Home, Pro, or Education
- System locale: en-US
- At least 35 GB free on C:
- Internet access to GitHub and Microsoft's software-download CDN

Already-25H2 machines exit without creating anything. A 24H2 machine exits and
should receive the existing normal 24H2-to-25H2 Sophos command. Unsupported or
unexpected editions/locales are not modified.

## Logs and state

- `C:\ProgramData\Win11-23H2-Forced25H2\Upgrade-23H2-to-25H2-Forced.log`
- `C:\ProgramData\Win11-23H2-Forced25H2\Launcher.log`
- `C:\ProgramData\Win11-23H2-Forced25H2\state.json`
- `C:\ProgramData\Win11-23H2-Forced25H2\CompatLogs.zip`
- `C:\ProgramData\Win11-23H2-Forced25H2\SetupLogs.zip`

Read-only Sophos status command:

```cmd
powershell.exe -NoLogo -NoProfile -NonInteractive -Command "$names='Win11-23H2-Forced25H2-AtStartup','Win11-23H2-Forced25H2-Retry';Write-Output '--- TASKS ---';foreach($n in $names){$t=Get-ScheduledTask -TaskPath '\' -TaskName $n -ErrorAction SilentlyContinue;if($t){$i=Get-ScheduledTaskInfo -InputObject $t;[pscustomobject]@{Task=$n;State=$t.State;LastRun=$i.LastRunTime;LastResult=$i.LastTaskResult;NextRun=$i.NextRunTime}}else{Write-Output ('MISSING: '+$n)}};Write-Output '--- STATE ---';if(Test-Path 'C:\ProgramData\Win11-23H2-Forced25H2\state.json'){Get-Content 'C:\ProgramData\Win11-23H2-Forced25H2\state.json' -Raw}else{'No state file'};Write-Output '--- LOG ---';if(Test-Path 'C:\ProgramData\Win11-23H2-Forced25H2\Upgrade-23H2-to-25H2-Forced.log'){Get-Content 'C:\ProgramData\Win11-23H2-Forced25H2\Upgrade-23H2-to-25H2-Forced.log' -Tail 35}else{'No log file'}"
```

## Options considered

1. Public Windows Update offer: safest and smallest download, but it is the
   route already failing on the test machine.
2. Fixed 24H2 ISO URL: deterministic, but Microsoft no longer offers 24H2 from
   its current public retail API. This requires a separately hosted and
   SHA256-pinned 24H2 ISO.
3. Windows Installation Assistant or Media Creation Tool automation: Microsoft
   hosted, but their unattended switches/UI behavior are not sufficiently
   documented for a dependable SYSTEM task.
4. Pinned Fido plus official Microsoft retail media: selected. Fido is used
   only to retrieve Microsoft's temporary ISO URL; the downloaded media is
   validated before Setup runs.

Test on a small canary group before broad deployment. Microsoft may rate-limit
large numbers of simultaneous ISO-link requests, so stagger mass deployment.

## Research references

- Microsoft Windows 11 download: https://www.microsoft.com/software-download/windows11
- Windows Setup command-line options: https://learn.microsoft.com/windows-hardware/manufacture/desktop/windows-setup-command-line-options
- Windows 11 24H2 is a full OS swap: https://learn.microsoft.com/windows/whats-new/whats-new-windows-11-version-24h2
- Fido: https://github.com/pbatard/Fido
- DirectWindowsUpgrade comparison: https://github.com/Ad3t0/DirectWindowsUpgrade
- MediaCreationTool.bat comparison: https://github.com/AveYo/MediaCreationTool.bat
