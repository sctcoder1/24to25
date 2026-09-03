# Direct Windows 11 24H2 to 25H2 deployment

This is the **aggressive direct-enablement replacement** for the older offer-based scripts. It installs the released, Microsoft-signed x64 KB5054156 enablement package without waiting for Windows Update to offer 25H2. Use on a backed-up pilot first. Automated regression checks pass; an actual endpoint upgrade has not been performed as part of this code verification.

## What is bypassed, and what is not

- Explicit `-AllowOfferBypass` authorizes deploying outside Windows Update's feature-offer and safeguard gating. A missing offer is no longer a blocker. This can expose known compatibility problems; a blank local safeguard list is not proof that a device is safe.
- No safeguard, WSUS, target-release, CPU, TPM, Secure Boot, Defender, or BitLocker policies are changed. Organizational update settings are not deleted. No encryption is suspended.
- Only regular **x64 Windows 11 24H2 clients**, build 26100, are targeted. Server, ARM64, LTSC and other releases are excluded. Already-running 25H2 is recognized for cleanup. A legacy registry ProductName saying Windows 10 is ignored.
- Minimum installed 24H2 build remains **26100.5074**. Below that, an applicable current non-preview 24H2 cumulative update is selected from the public **Windows Update service** (`ServerSelection=2`), not the managed WSUS source. A policy or network block on public scans is reported, not silently removed. The worker never treats partial success as successful installation.
- The enablement package must pass its fixed SHA256 and Microsoft Authenticode checks. DISM retains its applicability checks: no `/IgnoreCheck`. Broken servicing, wrong architecture or an unmet prerequisite cannot be wished away by a force flag.

Microsoft lists KB5054156 through Windows Update and WSUS, **not as a standalone Microsoft Update Catalog offering**. This deployment uses a separately verified Microsoft delivery-CDN package with DISM; do not mistake it for Microsoft's documented Catalog deployment procedure.

## Sophos: copy the new one-line CMD command

The 10-minute deployment ZIP contains only the four files to upload: `Upgrade-25H2.ps1`, `Win11-25H2-Launcher.bat`, `Sophos-Live-Action-One-Liner.txt`, and `README.md`. Optional test, repair and command-generator scripts are developer/support tools, not required deployment files. This version retains the state-save fix. It does not shorten an already scheduled countdown or change an endpoint until redeployed.

**Publishing prerequisite:** these replacement files must first be uploaded to the root of `sctcoder1/24to25`. Repository publishing was blocked in the preparation session. Upload the actual files, not copied/pasted code, to preserve the reviewed bytes. The expected worker SHA256 is `E953A8856BCAE93B900CC8FF80FE458B6A77F89B06A91E427DD33BE07AC69D97`. The command intentionally rejects the old GitHub worker.

Open [Sophos-Live-Action-One-Liner.txt](Sophos-Live-Action-One-Liner.txt), choose **Raw**, and copy the entire single line into **Sophos Live Action's CMD command**, running elevated/SYSTEM. Do not paste it at a PowerShell prompt. Do not copy Markdown `[url](url)` wrappers. Discard previously saved copies of the old command: their pinned commits still download the old worker.

The supplied command resolves `main` to an immutable commit SHA, downloads that commit's worker into a unique staging filename, verifies the fixed approved SHA256, then calls `-Install -AllowOfferBypass`. Thus a later changed worker will not be executed just because it is on `main`. The verified worker writes its embedded BAT launcher, registers tasks and requests the first run. Sophos does not remain attached to the lengthy update operation. A bootstrap success means the first run was requested, **not** that the upgrade has completed.

For a fleet, generate a **fixed-commit command** after publishing, to avoid GitHub's unauthenticated API rate limit on commit discovery. From an elevated or ordinary PowerShell window in this extracted bundle, run `New-SophosCommand.ps1 -Commit` with the actual 40-character GitHub commit SHA containing the uploaded worker. The generator prints a ready CMD line; it does not perform deployment. Copy that output into Sophos. No GitHub token is needed. The public repository and raw-download endpoint must be reachable.

```powershell
# Replace the quoted placeholder with the actual published 40-character commit SHA.
.\New-SophosCommand.ps1 -Commit 'YOUR_PUBLISHED_40_CHARACTER_COMMIT_SHA'
```

The scheduled tasks, in the root Task Scheduler Library, are:

| Task | Trigger | Action |
| --- | --- | --- |
| `Win11-25H2-AtStartup` | Startup | SYSTEM, highest privileges, BAT launcher |
| `Win11-25H2-Retry` | Every 3 hours, plus immediate first run | Same BAT launcher |

Task-level IgnoreNew and both legacy global mutexes prevent overlapping workers. Tasks run on battery and have no hard execution timeout that could kill servicing. Operations log progress; a prerequisite operation requests soft cancellation after three hours and waits for Windows to stop safely. Transient failures retry at the next trigger.

### Migration from both old scripts

Deploy the new command once; do **not** separately run `Upgrade-24H2-to-25H2.ps1` or schedule it through TeamViewer. That file remains a legacy reference in this repository and is not used by the new deployment.

Installation replaces the two recognized idle tasks above and removes the recognized obsolete `Win11-25H2-Startup` task. It checks task actions before changing them. A name collision or running old task aborts installation: wait for servicing to finish and rerun the bootstrap. It never kills Windows Update, DISM, WUSA, setup or an existing upgrade worker.

Old canonical worker/BAT files are copied into a unique `history-*` directory before replacement. Existing logs, the old `state.json`, the older alternative script, and unrelated `C:\Win11Upgrade` projects are retained. The new worker uses **`direct-state.json`**, so old failure state is not interpreted as new success. No broad folder deletion, Windows Update cache reset or cancellation of someone else's restart is performed.

Re-running the new bootstrap preserves direct-mode state, including reboot limits; it is not a destructive reset. A partial registration failure is logged, preserves the obsolete task, and can be retried after checking the recorded error.

## Restart behavior

- No immediate restart: DISM uses `/Quiet /NoRestart`; successful servicing is followed by a **10-minute** Windows restart countdown, plus a best-effort message to signed-in users. Pending update servicing may also require a 10-minute restart before continuing.
- **Save work. Windows forcibly closes applications when a timed restart expires**, even without an explicit `/f`. The countdown applies whether or not someone is logged in; this is not a user-consent prompt.
- An existing system countdown is left unchanged (it may be sooner than 10 minutes). A retry does not extend or re-arm a countdown already recorded for the current boot. If an administrator cancels it with `shutdown /a`, restart manually to continue.
- At most three automatic restart cycles and two successfully staged enablement attempts are allowed. Failed/partial servicing requiring attention stops automatic installs and restarts; tasks remain to report the condition. This prevents a persistent reboot loop.
- After a later boot verifies client 25H2/build 26200 and no pending update restart, the worker removes its recognized startup/retry tasks. Script, BAT, logs, package and state remain for audit.

## Check progress on the endpoint

Use an **elevated PowerShell window on the target computer**:

```powershell
Get-Content 'C:\ProgramData\Win11-25H2\Upgrade-25H2.log' -Tail 40
Get-Content 'C:\ProgramData\Win11-25H2\direct-state.json'
Get-ScheduledTask -TaskPath '\' -TaskName 'Win11-25H2-*' | Select-Object TaskName,State
```

New log lines contain `[Direct25H2]`. Old offer/EulaAccepted errors earlier in the shared log do not describe the new run. For live follow, append `-Wait` to Get-Content; Ctrl+C stops following the log, not the scheduled worker.

Expected ready-machine sequence: `Mode=direct` -> package hash/signature verified -> DISM install -> `DISM exit=0` or `3010` -> `AwaitingRestart` -> after restart, `Complete`. `Ready` in Task Scheduler means idle between runs; it is not an upgrade-success verdict. The BAT returns 0 for a successful stage/wait and 1 for a failure; completion is determined by state and the OS after reboot.

Additional checks:

```powershell
Get-Content 'C:\ProgramData\Win11-25H2\Launcher.log' -Tail 30
Get-ScheduledTask -TaskPath '\' -TaskName 'Win11-25H2-*' | Get-ScheduledTaskInfo | Select-Object LastRunTime,LastTaskResult,NextRunTime
& 'C:\ProgramData\Win11-25H2\Upgrade-25H2.ps1' -CheckOnly
```

If bootstrap registration succeeded but the worker failed, inspect `Detail` in `direct-state.json` and the named `DISM-*.log`. Once a transient problem is resolved, request another run:

```powershell
Start-ScheduledTask -TaskPath '\' -TaskName 'Win11-25H2-Retry'
```

Do not blindly delete state to bypass ManualAttention or reboot limits. Investigate the failure/rollback, confirm that no installation is active, and resolve Windows servicing first. Protected deployment files and logs are intentionally writable/readable only by SYSTEM and Administrators.

## Verified release payload

- Download host: `catalog.sf.dl.delivery.mp.microsoft.com` (exact HTTPS URL embedded in worker).
- Size: 175575 bytes.
- SHA256: `59A2B315141DA42066183C11F6233D974DE050B41CBB760AAFB8C89B0C88C616`.
- Authenticode: Valid, signer Microsoft Corporation, checked again on every installation.
- Manifest: released Feature Update for Windows 11 25H2 via Enablement Package, KB5054156, amd64, version `26100.6717.1.4`.
- Exact installed package identity: `Package_for_KB5054156~31bf3856ad364e35~amd64~~26100.6717.1.4`.

A different Microsoft-signed KB5054156 file labeled Dev Channel Preview was rejected during verification. Do not substitute a similarly named download or weaken hash/signature checks. No MSU is redistributed by this repository; endpoints download directly from Microsoft.

## Development verification

State-save hotfix: Windows PowerShell 5.1 converted the original `$null` backup argument to an empty path in File.Replace. The corrected worker uses `[NullString]::Value`. `Test-StatePersistence.ps1` reproduces actual first-write/replacement behavior on disk and verifies the exact repair/backup hashes, without touching servicing or tasks. On an already affected endpoint, run `Repair-25H2-State.ps1` elevated: it patches only the known affected worker, holds both worker mutexes, preserves the previous script, and leaves state/logs/package unchanged. It does not start a task or reboot. After it succeeds, start `Win11-25H2-Retry` to resume normal processing and the delayed restart. For new deployments, upload the corrected worker AND corrected one-liner (its approved hash changed).

`Test-DirectUpgrade.ps1` parses the worker and loads only function definitions. All worker/task/native servicing behavior is mocked; it does not run the entrypoint, install updates, register tasks or restart anything. Run with Windows PowerShell 5.1. If the separately downloaded verification MSU is available locally, the suite additionally verifies its real hash/signature. Tests cover target restrictions, exact task ownership/migration, direct/CU selection, partial failures, interrupt recovery, post-boot completion and countdown bounds. This is not an end-to-end upgrade certification.

## Microsoft references

- [KB5054156 and its prerequisite](https://support.microsoft.com/en-us/servicing/os/windows/docs/2025/02/kb5054156-feature-update-to-windows-11-version-25h2-by-using-an-enablement-package)
- [DISM package servicing and applicability](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/dism-operating-system-package-servicing-command-line-options?view=windows-11)
- [DISM NoRestart](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/dism-global-options-for-command-line-syntax?view=windows-11)
- [Safeguard holds and risks of other deployment channels](https://learn.microsoft.com/en-us/windows/deployment/update/safeguard-holds)
- [Shutdown timeout and forced application closure](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/shutdown)
