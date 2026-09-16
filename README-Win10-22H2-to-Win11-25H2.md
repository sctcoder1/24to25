# Windows 10 22H2 to Windows 11 25H2 via Sophos

This is a separate forced-media deployment for x64 Windows 10 22H2 build 19045. It does not replace the existing Windows 11 23H2 or 24H2 workers.

## Upload order

Upload these files to the root of `sctcoder1/24to25`:

1. `Upgrade-Win10-22H2-to-Win11-25H2.ps1`
2. `Sophos-Live-Action-Win10-22H2-to-Win11-25H2.txt`

Worker SHA256:

`7A192FCA8D66160EE14F95E845DC15F81A294892C59D61BA9B0CC8E5821EFBAA`

Run the complete single line from the TXT file in Sophos Live Action CMD.

## Behavior

- The Sophos command downloads only the small worker, verifies its SHA256 and syntax, installs SYSTEM tasks, starts the first task, and exits.
- The local SYSTEM task obtains a temporary official Microsoft Windows 11 25H2 x64 English ISO URL using a SHA256-pinned Fido 1.70 script.
- BITS downloads the ISO locally under `C:\ProgramData\Win10-22H2-Forced25H2`.
- During active download and Setup work, a built-in Windows power request prevents automatic idle sleep; no Caffeine executable or other third-party keep-awake binary is downloaded. The display may turn off normally.
- The worker validates ISO size, Microsoft signatures, matching edition, and build 26200 image metadata.
- A silent Windows Setup compatibility scan must approve the upgrade before installation begins.
- Setup uses `/auto upgrade`, preserving compatible applications, user data, and settings.
- Dynamic Update is enabled, BitLocker handling is delegated to Setup, and the first reboot is suppressed until Setup finishes its online phase.
- After successful preparation, users receive a clear 60-minute warning and Windows schedules the restart.
- Startup and three-hour retry tasks prevent the Sophos session from having to remain open.
- Both scheduled tasks are wake-capable. Closing the lid, explicitly selecting Sleep, shutdown, and power loss can still interrupt the work.
- A mutex prevents overlapping workers.
- After Windows 11 25H2 build 26200 is verified following reboot, the tasks and cached ISO are removed. Worker, state, and logs remain for audit.
- Failed or incomplete runs retain the valid ISO and retry every three hours.

## Scope and limits

- Source: Windows 10 22H2, build 19045, x64 Client
- Supported source editions: Home, Pro, and Education
- Language: en-US system locale
- Minimum free space: 35 GB
- Target: matching Windows 11 25H2 edition, build 26200
- The Microsoft-documented `AllowUpgradesWithUnsupportedTPMOrCPU` allowance is enabled. Microsoft Setup signatures and package applicability remain enforced.
- Hard compatibility blocks, unsupported editions, language mismatches, and insufficient space stop the attempt and are logged.

## Status command

```cmd
powershell.exe -NoLogo -NoProfile -NonInteractive -Command "Get-ScheduledTask -ErrorAction SilentlyContinue|Where-Object TaskName -Like 'Win10-22H2-Forced25H2-*'|Select-Object TaskName,State;Get-Content 'C:\ProgramData\Win10-22H2-Forced25H2\state.json' -Raw -ErrorAction SilentlyContinue;Get-Content 'C:\ProgramData\Win10-22H2-Forced25H2\Upgrade-Win10-22H2-to-Win11-25H2.log' -Tail 30 -ErrorAction SilentlyContinue"
```

## Files retained after success

- `Upgrade-Win10-22H2-to-Win11-25H2.ps1`
- `Win10-22H2-Forced25H2-Launcher.bat`
- `Upgrade-Win10-22H2-to-Win11-25H2.log`
- `Launcher.log`
- `state.json`
- compatibility and Setup copy-log archives when Windows Setup produces them
