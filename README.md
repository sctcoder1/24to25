# Windows 11 24H2 to 25H2 via Sophos Live Action

This repository provides a self-healing, unattended upgrade for eligible Windows 11 24H2 devices. It runs as `SYSTEM`, scans Microsoft's public Microsoft Update service directly (not the device's managed WSUS source), installs a current non-preview 24H2 cumulative update when the 25H2 prerequisite is missing, and then installs **Windows 11, version 25H2**.

Microsoft requires Windows 11 24H2 build **26100.5074** (KB5064081) or a later cumulative update before the 25H2 enablement package (KB5054156) can be applied. The script discovers the currently applicable, non-preview cumulative update at run time instead of hard-coding a monthly KB.

## Behavior

- Targets only Windows 11 24H2 (build 26100). Other operating systems and releases exit without modification.
- Creates two highest-privilege `SYSTEM` tasks: one at startup and one every three hours (also started immediately).
- Uses both task-level `IgnoreNew` handling and a global mutex to prevent overlapping runs.
- Keeps the script, state, and append-only log in `C:\ProgramData\Win11-25H2`.
- Never restarts immediately. When a restart is needed, it warns all interactive users and schedules the restart for 60 minutes later.
- Retries after failures, safeguard holds, network outages, or update-service errors.
- After a reboot verifies 25H2 from the operating-system registry, removes both scheduled tasks, and retains the script/log/state for audit.

## Sophos Live Action deployment

Run the following as a **CMD** command in Sophos Live Action. It is pinned to the immutable reviewed script commit and verifies the file before execution:

```cmd
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop';$d='C:\ProgramData\Win11-25H2';$p=Join-Path $d 'Upgrade-25H2.ps1';New-Item -ItemType Directory -Path $d -Force|Out-Null;[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12;Invoke-WebRequest -UseBasicParsing 'https://raw.githubusercontent.com/sctcoder1/24to25/4f3ae43ccb13181ae400742ced1cf05e7c7441c5/Upgrade-25H2.ps1' -OutFile $p;if((Get-FileHash -Algorithm SHA256 $p).Hash -ne '5F1ECDAEE09F5074EE0D51EEA08C2AB16997B95AAF2E126D065FF520FF385189'){Remove-Item -LiteralPath $p -Force;throw 'Upgrade script SHA256 mismatch'};& $p -Install"
```

The one-liner downloads only the file at a pinned commit, verifies its SHA256 before execution, installs the scheduled tasks, and starts the first run. Do not use a `main` branch URL for production deployment.

## Verification and audit

On an endpoint, review:

```powershell
Get-Content C:\ProgramData\Win11-25H2\Upgrade-25H2.log -Tail 100
Get-Content C:\ProgramData\Win11-25H2\state.json
Get-ScheduledTask Win11-25H2-AtStartup,Win11-25H2-Retry -ErrorAction SilentlyContinue
```

Successful completion is recorded as `Complete` in `state.json`. The two tasks should then be absent; retained files provide the audit trail.

## Operational notes

- A device must be able to reach Microsoft Update endpoints. Policies that prohibit dual scan or public Microsoft Update access can prevent this workflow from scanning; failures remain logged and retry automatically.
- Microsoft may withhold 25H2 because of a safeguard hold. This script does not bypass compatibility safeguards.
- The restart command uses Windows' native scheduled-restart notification plus `msg.exe` for a clear 60-minute warning to logged-on users.
- Test on a representative device group before broad production rollout.

## Microsoft references

- [KB5054156: Feature update to Windows 11, version 25H2 by using an enablement package](https://support.microsoft.com/en-us/topic/kb5054156-feature-update-to-windows-11-version-25h2-by-using-an-enablement-package-4d307e2d-3028-4323-bb46-552cff491643)
- [How Windows Update works (service IDs and scan sources)](https://learn.microsoft.com/windows/deployment/update/how-windows-update-works)
- [Windows Update Agent API](https://learn.microsoft.com/windows/win32/api/_wua/)
