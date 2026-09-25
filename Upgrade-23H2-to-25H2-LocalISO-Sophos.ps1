#requires -Version 5.1
<#
Windows 11 23H2 -> 25H2 Local ISO Sophos Worker

NEW standalone workflow. It does not replace or modify existing GitHub scripts.

Prerequisite:
    A Windows 11 25H2 x64 English ISO already exists in:
        C:\Win11-25H2-Upgrade

Usage:
    -Install    Installs/starts SYSTEM scheduled tasks and returns quickly.
    -CheckOnly  Displays current OS/workflow status.

The background SYSTEM worker:
    1. Finds the local ISO.
    2. Validates Microsoft Setup signatures.
    3. Validates matching edition and Windows 11 25H2 build 26200 media.
    4. Runs Windows Setup compatibility scan.
    5. Runs the in-place upgrade with /noreboot.
    6. Schedules the first reboot with a 10-minute warning.
#>

[CmdletBinding()]
param(
    [switch]$Install,
    [switch]$CheckOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Force native 64-bit Windows PowerShell.
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    $nativePowerShell = Join-Path $env:SystemRoot 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
    $nativeArguments = @(
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy', 'Bypass',
        '-File', $PSCommandPath
    )
    if ($Install)   { $nativeArguments += '-Install' }
    if ($CheckOnly) { $nativeArguments += '-CheckOnly' }

    & $nativePowerShell @nativeArguments
    exit $LASTEXITCODE
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

$MediaFolder   = 'C:\Win11-25H2-Upgrade'
$Root          = 'C:\ProgramData\Win11-23H2-LocalISO25H2-Sophos'
$Worker        = Join-Path $Root 'Upgrade-23H2-to-25H2-LocalISO-Sophos.ps1'
$Launcher      = Join-Path $Root 'Launcher.bat'
$LogPath       = Join-Path $Root 'Upgrade.log'
$LauncherLog   = Join-Path $Root 'Launcher.log'
$StatePath     = Join-Path $Root 'state.json'
$CompatLogs    = Join-Path $Root 'CompatLogs.zip'
$SetupLogs     = Join-Path $Root 'SetupLogs.zip'

$TaskStart     = 'Win11-23H2-LocalISO25H2-Sophos-AtStartup'
$TaskRetry     = 'Win11-23H2-LocalISO25H2-Sophos-Retry'
$TaskNames     = @($TaskStart, $TaskRetry)

$MutexName     = 'Global\Win11_23H2_LocalISO25H2_Sophos'
$MinimumFreeGB = 35

# ---------------------------------------------------------------------------
# Folder / logging / file protection
# ---------------------------------------------------------------------------

function Ensure-Root {
    if (Test-Path -LiteralPath $Root) {
        if ((Get-Item -LiteralPath $Root -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Refusing redirected deployment folder: $Root"
        }
    }
    else {
        New-Item -ItemType Directory -Path $Root -Force | Out-Null
    }

    $acl = Get-Acl -LiteralPath $Root
    $acl.SetSecurityDescriptorSddlForm('O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)')
    Set-Acl -LiteralPath $Root -AclObject $acl
}

function Protect-File {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    $acl = Get-Acl -LiteralPath $Path
    $acl.SetSecurityDescriptorSddlForm('O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)')
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Write-Log {
    param([Parameter(Mandatory)][string]$Message)

    Ensure-Root
    $line = '{0} [LocalISO25H2-Sophos] {1}' -f [datetime]::UtcNow.ToString('o'), $Message
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    Write-Host $line
}

# ---------------------------------------------------------------------------
# OS / state helpers
# ---------------------------------------------------------------------------

function Get-BootStamp {
    (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
}

function Get-OsSnapshot {
    $cv = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $os = Get-CimInstance Win32_OperatingSystem
    $locale = Get-WinSystemLocale

    [pscustomobject]@{
        InstallationType = [string]$cv.InstallationType
        DisplayVersion   = [string]$cv.DisplayVersion
        Build            = [int]$cv.CurrentBuildNumber
        UBR              = [int]$cv.UBR
        RunningBuild     = [int]$os.BuildNumber
        Edition          = [string]$cv.EditionID
        Architecture     = $env:PROCESSOR_ARCHITECTURE
        SystemLocale     = [string]$locale.Name
        BootStamp        = Get-BootStamp
    }
}

function Get-Disposition {
    param([Parameter(Mandatory)][object]$Os)

    if ($Os.InstallationType -ne 'Client' -or $Os.Architecture -ne 'AMD64') {
        return 'Unsupported'
    }

    if ($Os.DisplayVersion -eq '25H2' -and $Os.Build -eq 26200 -and $Os.RunningBuild -eq 26200) {
        return 'Complete'
    }

    if ($Os.DisplayVersion -eq '25H2' -and $Os.Build -eq 26200 -and $Os.RunningBuild -ne 26200) {
        return 'Staged'
    }

    if ($Os.DisplayVersion -eq '24H2' -and $Os.Build -eq 26100 -and $Os.RunningBuild -eq 26100) {
        return 'Already24H2'
    }

    if ($Os.DisplayVersion -eq '23H2' -and $Os.Build -eq 22631 -and $Os.RunningBuild -eq 22631) {
        return 'Upgrade23H2'
    }

    return 'Unsupported'
}

function New-DefaultState {
    [ordered]@{
        Schema        = 1
        Phase         = 'New'
        Detail        = ''
        UpdatedUtc    = [datetime]::UtcNow.ToString('o')
        BootStamp     = ''
        Attempts      = 0
        SetupExitCode = ''
        IsoPath       = ''
    }
}

function Load-State {
    $state = New-DefaultState

    if (Test-Path -LiteralPath $StatePath) {
        try {
            $loaded = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json

            if ([int]$loaded.Schema -ne 1) {
                throw 'Unsupported state schema.'
            }

            foreach ($property in $loaded.PSObject.Properties) {
                $state[$property.Name] = $property.Value
            }
        }
        catch {
            Write-Log "State file could not be read and will be recreated: $($_.Exception.Message)"
        }
    }

    return $state
}

function Save-State {
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$Phase,
        [Parameter(Mandatory)][string]$Detail
    )

    Ensure-Root

    $State.Phase = $Phase
    $State.Detail = $Detail
    $State.UpdatedUtc = [datetime]::UtcNow.ToString('o')

    $temporary = Join-Path $Root ('state-' + [guid]::NewGuid().ToString('N') + '.tmp')

    try {
        $State | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $temporary -Encoding UTF8
        Move-Item -LiteralPath $temporary -Destination $StatePath -Force
        Protect-File $StatePath
    }
    finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    }
}

function Test-RebootPending {
    try {
        $systemInfo = New-Object -ComObject Microsoft.Update.SystemInfo
        if ($systemInfo.RebootRequired) {
            return $true
        }
    }
    catch {}

    return (
        (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
        (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
    )
}

# ---------------------------------------------------------------------------
# Keep machine awake while Setup is running
# ---------------------------------------------------------------------------

Add-Type @'
using System;
using System.Runtime.InteropServices;

public static class LocalIsoUpgradePower
{
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern uint SetThreadExecutionState(uint esFlags);
}
'@

function Enable-WakeLock {
    # ES_CONTINUOUS | ES_SYSTEM_REQUIRED
    [void][LocalIsoUpgradePower]::SetThreadExecutionState([uint32]2147483649)
    Write-Log 'System sleep prevention enabled for the active upgrade worker.'
}

function Disable-WakeLock {
    # ES_CONTINUOUS
    [void][LocalIsoUpgradePower]::SetThreadExecutionState([uint32]2147483648)
}

# ---------------------------------------------------------------------------
# Scheduled tasks
# ---------------------------------------------------------------------------

function Remove-DeploymentTasks {
    foreach ($name in $TaskNames) {
        $task = Get-ScheduledTask -TaskPath '\' -TaskName $name -ErrorAction SilentlyContinue

        if ($task) {
            Unregister-ScheduledTask -InputObject $task -Confirm:$false
            Write-Log "Removed scheduled task $name."
        }
    }
}

function Write-Launcher {
    $launcherText = @'
@echo off
setlocal
set "ROOT=C:\ProgramData\Win11-23H2-LocalISO25H2-Sophos"
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
echo [%date% %time%] Local ISO Sophos launcher started.>>"%ROOT%\Launcher.log"
"%PS%" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%ROOT%\Upgrade-23H2-to-25H2-LocalISO-Sophos.ps1" >>"%ROOT%\Launcher.log" 2>&1
set "RC=%ERRORLEVEL%"
echo [%date% %time%] Launcher finished with exit code %RC%.>>"%ROOT%\Launcher.log"
exit /b %RC%
'@

    [IO.File]::WriteAllText(
        $Launcher,
        ($launcherText -replace '\r?\n', "`r`n"),
        [Text.Encoding]::ASCII
    )
}

function Install-Tasks {
    param([Parameter(Mandatory)][string]$SourceFile)

    Ensure-Root

    if ([IO.Path]::GetFullPath($SourceFile) -ne [IO.Path]::GetFullPath($Worker)) {
        Copy-Item -LiteralPath $SourceFile -Destination $Worker -Force
    }

    Write-Launcher
    Protect-File $Worker
    Protect-File $Launcher

    # Only touch task names belonging to THIS new workflow.
    Remove-DeploymentTasks

    $action = New-ScheduledTaskAction `
        -Execute "$env:SystemRoot\System32\cmd.exe" `
        -Argument '/d /c C:\ProgramData\Win11-23H2-LocalISO25H2-Sophos\Launcher.bat'

    $principal = New-ScheduledTaskPrincipal `
        -UserId 'SYSTEM' `
        -LogonType ServiceAccount `
        -RunLevel Highest

    $settings = New-ScheduledTaskSettingsSet `
        -MultipleInstances IgnoreNew `
        -StartWhenAvailable `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([timespan]::Zero)

    Register-ScheduledTask `
        -TaskPath '\' `
        -TaskName $TaskStart `
        -Action $action `
        -Principal $principal `
        -Settings $settings `
        -Trigger (New-ScheduledTaskTrigger -AtStartup) `
        -Force | Out-Null

    $retryTrigger = New-ScheduledTaskTrigger `
        -Once `
        -At ((Get-Date).AddMinutes(1)) `
        -RepetitionInterval (New-TimeSpan -Hours 3)

    Register-ScheduledTask `
        -TaskPath '\' `
        -TaskName $TaskRetry `
        -Action $action `
        -Principal $principal `
        -Settings $settings `
        -Trigger $retryTrigger `
        -Force | Out-Null

    $state = Load-State
    Save-State -State $state -Phase 'Installed' -Detail 'Local ISO SYSTEM startup and three-hour retry tasks installed.'

    Write-Log 'Local ISO SYSTEM tasks installed. Existing upgrade scripts/tasks with other names were not modified.'

    Start-ScheduledTask -TaskPath '\' -TaskName $TaskRetry

    Write-Output 'Local ISO 25H2 SYSTEM task installed and first background run started.'
}

# ---------------------------------------------------------------------------
# Restart
# ---------------------------------------------------------------------------

function Request-Restart {
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$Reason
    )

    $State.BootStamp = Get-BootStamp
    Save-State -State $State -Phase 'AwaitingRestart' -Detail $Reason

    $message = 'Windows 11 25H2 is ready to continue installing. This computer will restart in 10 minutes. Save your work; applications will close.'

    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'

    try {
        try {
            & "$env:SystemRoot\System32\msg.exe" '*' /TIME:600 $message 2>&1 | Out-Null
        }
        catch {}

        $output = & "$env:SystemRoot\System32\shutdown.exe" /r /t 600 /d p:2:3 /c $message 2>&1
        $code = $LASTEXITCODE

        if ($code -notin @(0, 1190)) {
            throw "Restart scheduling failed ($code): $($output | Out-String)"
        }

        Write-Log "Restart requested in 10 minutes. Reason: $Reason"
    }
    finally {
        $ErrorActionPreference = $oldPreference
    }
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

function Assert-Preflight {
    param([Parameter(Mandatory)][object]$Os)

    if ((Get-Disposition $Os) -ne 'Upgrade23H2') {
        throw "This worker requires x64 Windows 11 23H2 build 22631. Detected $($Os.DisplayVersion), build $($Os.Build), running $($Os.RunningBuild), edition $($Os.Edition)."
    }

    if ($Os.Edition -notin @('Professional', 'Core', 'Education')) {
        throw "Unsupported Windows edition for this reviewed workflow: $($Os.Edition)."
    }

    if ($Os.SystemLocale -ne 'en-US') {
        throw "This worker is limited to en-US installations. Detected system locale $($Os.SystemLocale)."
    }

    $systemDrive = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
    $freeGB = [math]::Round(([double]$systemDrive.FreeSpace / 1GB), 1)

    if ($freeGB -lt $MinimumFreeGB) {
        throw "Insufficient free space: $freeGB GB available; $MinimumFreeGB GB required."
    }

    Write-Log "Preflight passed: edition=$($Os.Edition), locale=$($Os.SystemLocale), free=${freeGB}GB."
}

function Enable-SupportedSetupBypass {
    $moSetup = 'HKLM:\SYSTEM\Setup\MoSetup'

    if (-not (Test-Path -LiteralPath $moSetup)) {
        New-Item -Path $moSetup -Force | Out-Null
    }

    New-ItemProperty `
        -Path $moSetup `
        -Name AllowUpgradesWithUnsupportedTPMOrCPU `
        -PropertyType DWord `
        -Value 1 `
        -Force | Out-Null

    Write-Log 'Enabled AllowUpgradesWithUnsupportedTPMOrCPU.'
}

# ---------------------------------------------------------------------------
# Local ISO
# ---------------------------------------------------------------------------

function Get-LocalIso {
    if (-not (Test-Path -LiteralPath $MediaFolder)) {
        throw "Media folder does not exist: $MediaFolder"
    }

    $isos = @(
        Get-ChildItem `
            -LiteralPath $MediaFolder `
            -Filter '*.iso' `
            -File `
            -ErrorAction Stop
    )

    if ($isos.Count -eq 0) {
        throw "No ISO was found in $MediaFolder"
    }

    if ($isos.Count -gt 1) {
        throw "More than one ISO exists in $MediaFolder. Leave only the Windows 11 25H2 ISO."
    }

    $iso = $isos[0]

    if ($iso.Length -lt 5GB -or $iso.Length -gt 12GB) {
        throw "ISO size is outside the expected range: $([math]::Round($iso.Length / 1GB, 2)) GB."
    }

    Write-Log "Local ISO found: $($iso.FullName) ($([math]::Round($iso.Length / 1GB, 2)) GB)."

    return $iso.FullName
}

function Test-MicrosoftSignature {
    param([Parameter(Mandatory)][string]$Path)

    $signature = Get-AuthenticodeSignature -LiteralPath $Path

    if (
        $signature.Status -ne 'Valid' -or
        -not $signature.SignerCertificate -or
        $signature.SignerCertificate.Subject -notmatch '(?i)Microsoft'
    ) {
        throw "Microsoft signature validation failed for $Path. Status=$($signature.Status)."
    }
}

function Mount-AndValidateIso {
    param(
        [Parameter(Mandatory)][string]$IsoPath,
        [Parameter(Mandatory)][string]$Edition
    )

    Write-Log "Mounting local ISO: $IsoPath"

    $disk = Get-DiskImage -ImagePath $IsoPath -ErrorAction SilentlyContinue

    if (-not $disk -or -not $disk.Attached) {
        $disk = Mount-DiskImage -ImagePath $IsoPath -PassThru -ErrorAction Stop
    }

    Start-Sleep -Seconds 3

    $volume = Get-DiskImage -ImagePath $IsoPath |
        Get-Volume |
        Where-Object DriveLetter |
        Select-Object -First 1

    if (-not $volume) {
        throw 'Mounted ISO has no drive letter.'
    }

    $drive = "$($volume.DriveLetter):"
    $setup = Join-Path $drive 'setup.exe'
    $setupPrep = Join-Path $drive 'sources\setupprep.exe'

    if (-not (Test-Path -LiteralPath $setup)) {
        throw 'Mounted ISO is missing setup.exe.'
    }

    if (-not (Test-Path -LiteralPath $setupPrep)) {
        throw 'Mounted ISO is missing sources\setupprep.exe.'
    }

    Test-MicrosoftSignature $setup
    Test-MicrosoftSignature $setupPrep

    $imagePath = @(
        (Join-Path $drive 'sources\install.wim'),
        (Join-Path $drive 'sources\install.esd')
    ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

    if (-not $imagePath) {
        throw 'Mounted ISO is missing install.wim/install.esd.'
    }

    $editionPattern = switch ($Edition) {
        'Professional' { '^Windows 11 Pro$' }
        'Core'         { '^Windows 11 Home$' }
        'Education'    { '^Windows 11 Education$' }
        default        { '^$' }
    }

    $images = @(Get-WindowsImage -ImagePath $imagePath -ErrorAction Stop)
    $editionImages = @($images | Where-Object { $_.ImageName -match $editionPattern })

    if (-not $editionImages.Count) {
        $available = ($images | ForEach-Object { "$($_.ImageName) [index $($_.ImageIndex)]" }) -join '; '
        throw "Media does not contain the required edition. Available: $available"
    }

    $matchingImages = @()
    $inspected = @()

    foreach ($candidate in $editionImages) {
        $detail = Get-WindowsImage `
            -ImagePath $imagePath `
            -Index ([uint32]$candidate.ImageIndex) `
            -ErrorAction Stop

        $versionProperty = $detail.PSObject.Properties['Version']

        if (-not $versionProperty -or -not $versionProperty.Value) {
            throw "Detailed image metadata for index $($candidate.ImageIndex) does not include a Version value."
        }

        $imageVersion = [version][string]$versionProperty.Value
        $inspected += "$($candidate.ImageName) [$imageVersion]"

        if ($imageVersion.Build -eq 26200) {
            $matchingImages += $detail
        }
    }

    if (-not $matchingImages.Count) {
        throw "Media does not contain the required Windows 11 25H2 build-26200 edition. Inspected: $($inspected -join '; ')"
    }

    $setupVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($setup).ProductVersion

    Write-Log "Local Microsoft media validated at $drive; setup.exe version=$setupVersion; matching build-26200 edition found."

    [pscustomobject]@{
        Drive     = $drive
        Setup     = $setup
        ImagePath = $imagePath
    }
}

function Dismount-IsoSafely {
    param([string]$IsoPath)

    if ([string]::IsNullOrWhiteSpace($IsoPath)) {
        return
    }

    try {
        $disk = Get-DiskImage -ImagePath $IsoPath -ErrorAction SilentlyContinue

        if ($disk -and $disk.Attached) {
            Dismount-DiskImage -ImagePath $IsoPath -ErrorAction Stop
            Write-Log 'ISO dismounted.'
        }
    }
    catch {
        Write-Log "ISO dismount warning: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# Windows Setup
# ---------------------------------------------------------------------------

function Get-ExitHex {
    param([int]$Code)

    '{0:X8}' -f ($Code -band 0xffffffff)
}

function Invoke-CompatibilityScan {
    param(
        [Parameter(Mandatory)][string]$Setup,
        [Parameter(Mandatory)][hashtable]$State
    )

    Remove-Item -LiteralPath $CompatLogs -Force -ErrorAction SilentlyContinue

    $arguments = @(
        '/auto', 'upgrade',
        '/quiet',
        '/eula', 'accept',
        '/dynamicupdate', 'enable',
        '/compat', 'scanonly',
        '/copylogs', $CompatLogs
    )

    Save-State -State $State -Phase 'CompatibilityScan' -Detail 'Running Windows Setup compatibility scan.'
    Write-Log "Starting Windows Setup compatibility scan: $($arguments -join ' ')"

    $process = Start-Process `
        -FilePath $Setup `
        -ArgumentList $arguments `
        -PassThru `
        -Wait `
        -WindowStyle Hidden

    $hex = Get-ExitHex $process.ExitCode

    Write-Log "Compatibility scan exit code=$($process.ExitCode) (0x$hex)."

    if ($hex -ne 'C1900210') {
        $meaning = switch ($hex) {
            'C1900200' { 'hardware/system-requirement block' }
            'C1900204' { 'requested migration choice is unavailable' }
            'C1900208' { 'incompatible application or driver block' }
            'C190020E' { 'insufficient disk space' }
            default    { 'unrecognized compatibility result' }
        }

        throw "Windows Setup compatibility scan did not approve the upgrade: 0x$hex ($meaning). Review $CompatLogs and C:\`$WINDOWS.~BT\Sources\Panther."
    }

    Write-Log 'Compatibility scan passed.'
}

function Invoke-InPlaceUpgrade {
    param(
        [Parameter(Mandatory)][string]$Setup,
        [Parameter(Mandatory)][hashtable]$State
    )

    Remove-Item -LiteralPath $SetupLogs -Force -ErrorAction SilentlyContinue

    $arguments = @(
        '/auto', 'upgrade',
        '/quiet',
        '/eula', 'accept',
        '/dynamicupdate', 'enable',
        '/compat', 'ignorewarning',
        '/showoobe', 'none',
        '/bitlocker', 'alwayssuspend',
        '/priority', 'low',
        '/noreboot',
        '/copylogs', $SetupLogs
    )

    $State.Attempts = [int]$State.Attempts + 1

    Save-State `
        -State $State `
        -Phase 'Installing25H2' `
        -Detail 'Windows Setup is running silently in the SYSTEM scheduled task.'

    Write-Log "Launching Windows Setup attempt $($State.Attempts): $($arguments -join ' ')"

    $process = Start-Process `
        -FilePath $Setup `
        -ArgumentList $arguments `
        -PassThru `
        -Wait `
        -WindowStyle Hidden

    $hex = Get-ExitHex $process.ExitCode
    $State.SetupExitCode = "0x$hex"

    Write-Log "Windows Setup exit code=$($process.ExitCode) (0x$hex)."

    if ($process.ExitCode -notin @(0, 1641, 3010)) {
        throw "Windows Setup did not return a success/restart-required code: 0x$hex. Review $SetupLogs and C:\`$WINDOWS.~BT\Sources\Panther."
    }

    Request-Restart `
        -State $State `
        -Reason 'Windows Setup completed the down-level phase successfully.'
}

# ---------------------------------------------------------------------------
# Check mode
# ---------------------------------------------------------------------------

function Show-Check {
    $os = Get-OsSnapshot
    $iso = @(
        Get-ChildItem `
            -LiteralPath $MediaFolder `
            -Filter '*.iso' `
            -File `
            -ErrorAction SilentlyContinue
    )

    [pscustomobject]@{
        Computer       = $env:COMPUTERNAME
        DisplayVersion = $os.DisplayVersion
        InstalledBuild = ('{0}.{1}' -f $os.Build, $os.UBR)
        RunningBuild   = $os.RunningBuild
        Edition        = $os.Edition
        SystemLocale   = $os.SystemLocale
        Disposition    = Get-Disposition $os
        IsoCount       = $iso.Count
        Iso            = ($iso.FullName -join '; ')
        Log             = $LogPath
    } | Format-List | Out-String -Width 220 | Write-Output

    if (Test-Path -LiteralPath $StatePath) {
        Get-Content -LiteralPath $StatePath -Raw | Write-Output
    }
}

# ---------------------------------------------------------------------------
# Entry
# ---------------------------------------------------------------------------

if ($CheckOnly) {
    Show-Check
    exit 0
}

$initial = Get-OsSnapshot
$initialDisposition = Get-Disposition $initial

if ($initialDisposition -eq 'Complete') {
    Write-Output "Already Windows 11 25H2 build 26200.$($initial.UBR). Nothing to do."
    exit 0
}

if ($Install) {
    if ($initialDisposition -eq 'Already24H2') {
        Write-Output 'This device is already 24H2. Use the existing normal 24H2-to-25H2 workflow.'
        exit 0
    }

    if ($initialDisposition -ne 'Upgrade23H2') {
        throw "This bootstrap targets x64 Windows 11 23H2 build 22631. Detected $($initial.DisplayVersion), build $($initial.Build), running $($initial.RunningBuild)."
    }

    # Fail immediately in Sophos if PDQ has not staged the ISO.
    $null = Get-LocalIso

    Install-Tasks -SourceFile $PSCommandPath
    exit 0
}

$mutex = New-Object Threading.Mutex($false, $MutexName)
$locked = $false
$state = $null
$isoPath = $null

try {
    $locked = $mutex.WaitOne(0)

    if (-not $locked) {
        Write-Output 'Another Local ISO 25H2 worker is already running. Exiting without overlap.'
        exit 0
    }

    Ensure-Root
    $state = Load-State
    $os = Get-OsSnapshot

    switch (Get-Disposition $os) {
        'Complete' {
            Save-State `
                -State $state `
                -Phase 'Complete' `
                -Detail "Windows 11 25H2 build 26200.$($os.UBR) verified after reboot."

            Write-Log "Windows 11 25H2 build 26200.$($os.UBR) verified. Cleaning this workflow's scheduled tasks."
            Remove-DeploymentTasks
        }

        'Staged' {
            Request-Restart `
                -State $state `
                -Reason 'Windows 11 25H2 is staged but the running kernel has not changed.'
        }

        'Already24H2' {
            Save-State `
                -State $state `
                -Phase 'Reached24H2' `
                -Detail '24H2 detected. Use the normal 24H2-to-25H2 workflow.'

            Write-Log '24H2 detected. Removing only this Local ISO workflow tasks.'
            Remove-DeploymentTasks
        }

        'Upgrade23H2' {
            if ($state.Phase -eq 'AwaitingRestart' -and $state.BootStamp -eq $os.BootStamp) {
                Request-Restart `
                    -State $state `
                    -Reason 'The prepared 25H2 upgrade is still awaiting its first restart.'

                break
            }

            if (Test-RebootPending) {
                Request-Restart `
                    -State $state `
                    -Reason 'Windows servicing requires a restart before the media upgrade can start.'

                break
            }

            Assert-Preflight $os
            Enable-SupportedSetupBypass
            Enable-WakeLock

            $isoPath = Get-LocalIso
            $state.IsoPath = $isoPath

            Save-State `
                -State $state `
                -Phase 'MediaFound' `
                -Detail "Using local ISO: $isoPath"

            $media = $null

            try {
                $media = Mount-AndValidateIso `
                    -IsoPath $isoPath `
                    -Edition $os.Edition

                Invoke-CompatibilityScan `
                    -Setup $media.Setup `
                    -State $state

                Invoke-InPlaceUpgrade `
                    -Setup $media.Setup `
                    -State $state
            }
            finally {
                Dismount-IsoSafely -IsoPath $isoPath
            }
        }

        default {
            throw "Unsupported or inconsistent OS state: $($os.DisplayVersion), build $($os.Build), running $($os.RunningBuild), edition $($os.Edition)."
        }
    }
}
catch {
    $detail = $_.Exception.Message

    try {
        if (-not $state) {
            $state = Load-State
        }

        Save-State `
            -State $state `
            -Phase 'FailedWillRetry' `
            -Detail $detail

        Write-Log "ERROR: $detail"
    }
    catch {}

    Write-Error $_
    exit 1
}
finally {
    try {
        Disable-WakeLock
    }
    catch {}

    if ($locked) {
        try {
            $mutex.ReleaseMutex()
        }
        catch {}
    }

    $mutex.Dispose()
}

exit 0
