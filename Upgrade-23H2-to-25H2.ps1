#requires -Version 5.1
<#
Special Windows 11 23H2 -> 25H2 helper.

Purpose:
- ONLY for older Windows 11 23H2 (build 22631) machines.
- Uses public Microsoft Windows Update to install Windows 11 24H2 when offered.
- After reboot, detects 24H2 and hands off to the existing proven
  sctcoder1/24to25 Upgrade-25H2.ps1 worker.
- No ISO fallback.
- 24H2/25H2 machines are not modified by this helper beyond the intended handoff/cleanup.
#>

[CmdletBinding()]
param(
    [switch]$Install,
    [switch]$CheckOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    $native = Join-Path $env:SystemRoot 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
    $args = @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$PSCommandPath)
    if ($Install) { $args += '-Install' }
    if ($CheckOnly) { $args += '-CheckOnly' }
    & $native @args
    exit $LASTEXITCODE
}

$Root      = 'C:\ProgramData\Win11-23H2-to-25H2'
$Worker    = Join-Path $Root 'Upgrade-23H2-to-25H2.ps1'
$Launcher  = Join-Path $Root 'Win11-23H2-Launcher.bat'
$LogPath   = Join-Path $Root 'Upgrade-23H2-to-25H2.log'
$StatePath = Join-Path $Root 'state.json'
$TaskStart = 'Win11-23H2-to-25H2-AtStartup'
$TaskRetry = 'Win11-23H2-to-25H2-Retry'
$TaskNames = @($TaskStart,$TaskRetry)
$MutexName = 'Global\Win11_23H2_to_25H2_Special'

# Existing proven 24H2 -> 25H2 worker in this same public repository.
$Existing24to25Uri  = 'https://raw.githubusercontent.com/sctcoder1/24to25/main/Upgrade-25H2.ps1'
$Existing24to25Hash = '8A1D45268C88DE9A9B37873166DA615A85067AE9AAF9D996FA0770B39A7E13E6'

function Get-OsSnapshot {
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $os = Get-CimInstance Win32_OperatingSystem
    [pscustomobject]@{
        InstallationType = [string]$cv.InstallationType
        DisplayVersion   = [string]$cv.DisplayVersion
        Build            = [int]$cv.CurrentBuildNumber
        UBR              = [int]$cv.UBR
        RunningBuild     = [int]$os.BuildNumber
        Edition          = [string]$cv.EditionID
        Architecture     = $env:PROCESSOR_ARCHITECTURE
    }
}

function Get-Disposition([object]$Os) {
    if ($Os.InstallationType -ne 'Client') { return 'Unsupported' }
    if ($Os.Architecture -ne 'AMD64') { return 'Unsupported' }
    if ($Os.Edition -match '^(EnterpriseS|IoTEnterpriseS)') { return 'Unsupported' }

    if ($Os.DisplayVersion -eq '25H2' -and $Os.Build -eq 26200 -and $Os.RunningBuild -eq 26200) {
        return 'Complete'
    }

    if ($Os.DisplayVersion -eq '24H2' -and $Os.Build -eq 26100 -and $Os.RunningBuild -eq 26100) {
        return 'Handoff24'
    }

    if ($Os.DisplayVersion -eq '25H2' -and $Os.Build -eq 26200 -and $Os.RunningBuild -eq 26100) {
        return 'Handoff24'
    }

    if ($Os.DisplayVersion -eq '23H2' -and $Os.Build -eq 22631 -and $Os.RunningBuild -eq 22631) {
        return 'Upgrade23'
    }

    return 'Unsupported'
}

function Ensure-Root {
    if (Test-Path -LiteralPath $Root) {
        if ((Get-Item -LiteralPath $Root -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Refusing redirected deployment folder: $Root"
        }
    } else {
        New-Item -ItemType Directory -Path $Root -Force | Out-Null
    }

    $acl = Get-Acl -LiteralPath $Root
    $acl.SetSecurityDescriptorSddlForm('O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)')
    Set-Acl -LiteralPath $Root -AclObject $acl
}

function Write-Log([string]$Message) {
    Ensure-Root
    $line = '{0} [23H2Special] {1}' -f [datetime]::UtcNow.ToString('o'), $Message
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    Write-Host $line
}

function Save-State([string]$Phase,[string]$Detail) {
    Ensure-Root
    [ordered]@{
        Phase      = $Phase
        Detail     = $Detail
        UpdatedUtc = [datetime]::UtcNow.ToString('o')
        Computer   = $env:COMPUTERNAME
    } | ConvertTo-Json | Set-Content -LiteralPath $StatePath -Encoding UTF8
}

function Test-RebootPending {
    try {
        $info = New-Object -ComObject Microsoft.Update.SystemInfo
        if ($info.RebootRequired) { return $true }
    } catch {}

    return (
        (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
        (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
    )
}

function Request-Reboot([string]$Reason) {
    Save-State 'AwaitingRestart' $Reason
    $message = "Windows 11 maintenance: this computer will restart in 10 minutes. Save your work; applications will close. $Reason"

    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & "$env:SystemRoot\System32\shutdown.exe" /r /t 600 /d p:2:3 /c $message 2>&1
        $code = $LASTEXITCODE
        if ($code -notin 0,1190) {
            throw "Restart scheduling failed ($code): $($output | Out-String)"
        }
        try { & "$env:SystemRoot\System32\msg.exe" '*' /TIME:600 $message 2>&1 | Out-Null } catch {}
        Write-Log "Restart requested in 10 minutes. Reason: $Reason"
    }
    finally {
        $ErrorActionPreference = $old
    }
}

function Get-OwnedTasks {
    @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
        $_.TaskPath -eq '\' -and $_.TaskName -in $TaskNames
    })
}

function Assert-OwnedTasks {
    foreach ($task in @(Get-OwnedTasks)) {
        foreach ($action in @($task.Actions)) {
            if (($action.Execute + ' ' + $action.Arguments) -notmatch '(?i)C:\\ProgramData\\Win11-23H2-to-25H2\\Win11-23H2-Launcher\.bat') {
                throw "Task name collision detected for $($task.TaskName). No task changes were made."
            }
        }
    }
}

function Remove-SpecialTasks {
    Assert-OwnedTasks
    foreach ($name in $TaskNames) {
        $task = Get-ScheduledTask -TaskPath '\' -TaskName $name -ErrorAction SilentlyContinue
        if ($task) {
            Unregister-ScheduledTask -InputObject $task -Confirm:$false
            Write-Log "Removed special 23H2 task $name."
        }
    }
}

function Write-Launcher {
    $text = @'
@echo off
setlocal
set "ROOT=C:\ProgramData\Win11-23H2-to-25H2"
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
echo [%date% %time%] 23H2 special launcher started.>>"%ROOT%\Launcher.log"
"%PS%" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%ROOT%\Upgrade-23H2-to-25H2.ps1" >>"%ROOT%\Launcher.log" 2>&1
set "RC=%ERRORLEVEL%"
echo [%date% %time%] Launcher finished with exit code %RC%.>>"%ROOT%\Launcher.log"
exit /b %RC%
'@
    [IO.File]::WriteAllText($Launcher,($text -replace '\r?\n',"`r`n"),[Text.Encoding]::ASCII)
}

function Install-SpecialTasks([string]$SourceFile) {
    Ensure-Root
    Assert-OwnedTasks

    if ([IO.Path]::GetFullPath($SourceFile) -ne [IO.Path]::GetFullPath($Worker)) {
        Copy-Item -LiteralPath $SourceFile -Destination $Worker -Force
    }

    Write-Launcher

    foreach ($path in @($Worker,$Launcher)) {
        $acl = Get-Acl -LiteralPath $path
        $acl.SetSecurityDescriptorSddlForm('O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)')
        Set-Acl -LiteralPath $path -AclObject $acl
    }

    $action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\cmd.exe" -Argument '/d /c C:\ProgramData\Win11-23H2-to-25H2\Win11-23H2-Launcher.bat'
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([timespan]::Zero)

    Register-ScheduledTask -TaskPath '\' -TaskName $TaskStart -Action $action -Principal $principal -Settings $settings -Trigger (New-ScheduledTaskTrigger -AtStartup) -Force | Out-Null

    $retry = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(1)) -RepetitionInterval (New-TimeSpan -Hours 3)
    Register-ScheduledTask -TaskPath '\' -TaskName $TaskRetry -Action $action -Principal $principal -Settings $settings -Trigger $retry -Force | Out-Null

    Save-State 'Installed' '23H2 special continuation tasks installed.'
    Write-Log '23H2 special SYSTEM tasks installed at startup and every 3 hours.'
    Start-ScheduledTask -TaskPath '\' -TaskName $TaskRetry
}

function Find-24H2FeatureUpdate {
    Write-Log 'Searching public Microsoft Windows Update for Windows 11 24H2.'

    $session = New-Object -ComObject Microsoft.Update.Session
    $session.ClientApplicationID = 'Win11-23H2-Special'
    $session.UserLocale = 1033

    $searcher = $session.CreateUpdateSearcher()
    $searcher.ServerSelection = 2
    $searcher.Online = $true

    $result = $searcher.Search("IsInstalled=0 and IsHidden=0 and Type='Software'")
    if ($result.ResultCode -ne 2) {
        throw "Windows Update search did not complete successfully. ResultCode=$($result.ResultCode)"
    }

    $matches = @()
    for ($i=0; $i -lt $result.Updates.Count; $i++) {
        $u = $result.Updates.Item($i)
        if (
            $u.Title -match '(?i)(Feature update to Windows 11.*24H2|Windows 11.*version 24H2)' -and
            $u.Title -notmatch '(?i)Preview|Insider|Dynamic Update|Safe OS|\.NET'
        ) {
            $matches += $u
        }
    }

    if (-not $matches.Count) { return $null }
    return ($matches | Sort-Object LastDeploymentChangeTime -Descending | Select-Object -First 1)
}

function Install-24H2FeatureUpdate {
    if (Test-RebootPending) {
        Request-Reboot 'A Windows servicing restart is already pending. The 23H2 to 24H2 upgrade will retry after restart.'
        return
    }

    $update = Find-24H2FeatureUpdate
    if (-not $update) {
        Save-State 'WaitingFor24H2Offer' 'Public Windows Update did not offer an applicable 24H2 feature update.'
        Write-Log '24H2 is not currently offered to this device by public Windows Update. No ISO fallback will be attempted.'
        return
    }

    Write-Log ("Selected feature update: " + $update.Title)
    Save-State 'Downloading24H2' $update.Title

    if (-not $update.EulaAccepted) { $update.AcceptEula() }

    $collection = New-Object -ComObject Microsoft.Update.UpdateColl
    [void]$collection.Add($update)

    $session = New-Object -ComObject Microsoft.Update.Session
    $session.ClientApplicationID = 'Win11-23H2-Special'
    $session.UserLocale = 1033

    $downloader = $session.CreateUpdateDownloader()
    $downloader.Updates = $collection
    $download = $downloader.Download()
    $downloadItem = $download.GetUpdateResult(0)

    if ($download.ResultCode -ne 2 -or $downloadItem.ResultCode -ne 2 -or -not $update.IsDownloaded) {
        throw "24H2 feature update download failed. ResultCode=$($download.ResultCode), ItemResult=$($downloadItem.ResultCode), HRESULT=$($downloadItem.HResult)"
    }

    Save-State 'Installing24H2' $update.Title
    Write-Log '24H2 feature update downloaded. Starting quiet installation.'

    $installer = $session.CreateUpdateInstaller()
    $installer.Updates = $collection
    $installer.ForceQuiet = $true
    $installer.AllowSourcePrompts = $false

    if ($installer.IsBusy -or $installer.RebootRequiredBeforeInstallation) {
        throw 'Windows servicing is busy or requires a restart before installation. Retry later.'
    }

    $installed = $installer.Install()
    $item = $installed.GetUpdateResult(0)

    if ($installed.ResultCode -ne 2 -or $item.ResultCode -ne 2) {
        throw "24H2 feature update installation did not complete successfully. ResultCode=$($installed.ResultCode), ItemResult=$($item.ResultCode), HRESULT=$($item.HResult)"
    }

    Write-Log '24H2 feature update installation stage completed successfully.'

    if ($installed.RebootRequired -or $item.RebootRequired -or (Test-RebootPending)) {
        Request-Reboot 'Windows 11 24H2 feature update installed. After restart the normal 24H2 to 25H2 process will be started.'
    } else {
        Save-State '24H2InstallComplete' 'Installer reported success without a restart requirement. Rechecking on next scheduled run.'
    }
}

function Start-Existing24to25 {
    Ensure-Root
    Write-Log '24H2 detected. Starting the existing proven 24H2 -> 25H2 worker.'

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $temp = Join-Path $Root ('Existing24to25-' + [guid]::NewGuid().ToString('N') + '.ps1')

    Invoke-WebRequest -UseBasicParsing -Uri $Existing24to25Uri -OutFile $temp -TimeoutSec 60

    $actual = (Get-FileHash -LiteralPath $temp -Algorithm SHA256).Hash
    if ($actual -ne $Existing24to25Hash) {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        throw "Existing 24H2 worker SHA256 mismatch. Expected $Existing24to25Hash, received $actual. No 25H2 tasks were changed."
    }

    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($temp,[ref]$tokens,[ref]$errors)
    if ($errors.Count) {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        throw 'Existing 24H2 worker contains PowerShell syntax errors.'
    }

    & $temp -Install -AllowOfferBypass
    $rc = $LASTEXITCODE

    if ($rc -ne 0) {
        throw "Existing 24H2 -> 25H2 bootstrap returned exit code $rc. The 23H2 helper will retry later."
    }

    Save-State 'HandedOffToExisting24to25' 'Existing 24H2 -> 25H2 worker installed successfully.'
    Write-Log 'Existing 24H2 -> 25H2 worker accepted the handoff. Removing only the special 23H2 helper tasks.'
    Remove-SpecialTasks
}

function Show-Check {
    $os = Get-OsSnapshot
    [pscustomobject]@{
        Computer       = $env:COMPUTERNAME
        DisplayVersion = $os.DisplayVersion
        InstalledBuild = ('{0}.{1}' -f $os.Build,$os.UBR)
        RunningBuild   = $os.RunningBuild
        Edition        = $os.Edition
        Disposition    = (Get-Disposition $os)
    } | Format-List | Out-String -Width 220 | Write-Output
}

if ($CheckOnly) {
    Show-Check
    exit 0
}

$initial = Get-OsSnapshot
$disposition = Get-Disposition $initial

# Intentionally before Ensure-Root: already-complete 25H2 creates nothing.
if ($disposition -eq 'Complete') {
    Write-Output ("Already Windows 11 25H2 - build 26200.{0}. Nothing to do." -f $initial.UBR)
    exit 0
}

# This special bootstrap is intended for 23H2 only.
if ($Install) {
    if ($disposition -eq 'Upgrade23') {
        Install-SpecialTasks -SourceFile $PSCommandPath
        exit 0
    }

    if ($disposition -eq 'Handoff24') {
        Write-Output 'This machine is already 24H2/staged 25H2. Use the normal Sophos 24H2 -> 25H2 one-liner instead.'
        exit 0
    }

    throw "This special bootstrap only supports x64 Windows 11 23H2 build 22631. Detected DisplayVersion=$($initial.DisplayVersion), Build=$($initial.Build), Running=$($initial.RunningBuild), Edition=$($initial.Edition)."
}

$mutex = New-Object Threading.Mutex($false,$MutexName)
$locked = $false
try {
    $locked = $mutex.WaitOne(0)
    if (-not $locked) {
        Write-Output 'Another 23H2 special worker is already running. Exiting.'
        exit 0
    }

    $os = Get-OsSnapshot
    switch (Get-Disposition $os) {
        'Complete' {
            Write-Log '25H2 confirmed. Removing special 23H2 helper tasks.'
            Save-State 'Complete' ('Build 26200.' + $os.UBR)
            Remove-SpecialTasks
        }
        'Handoff24' {
            Start-Existing24to25
        }
        'Upgrade23' {
            Install-24H2FeatureUpdate
        }
        default {
            throw "Unsupported or inconsistent state during scheduled run. DisplayVersion=$($os.DisplayVersion), Build=$($os.Build), Running=$($os.RunningBuild)."
        }
    }
}
catch {
    try {
        Save-State 'Error' $_.Exception.Message
        Write-Log ('ERROR: ' + $_.Exception.Message)
    } catch {}
    Write-Error $_
    exit 1
}
finally {
    if ($locked) { try { $mutex.ReleaseMutex() } catch {} }
    $mutex.Dispose()
}

exit 0
