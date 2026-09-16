#requires -Version 5.1
[CmdletBinding()]
param([switch]$Install)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Root        = 'C:\ProgramData\Win11-25H2-Updates'
$Worker      = Join-Path $Root 'Update-Windows25H2.ps1'
$Launcher    = Join-Path $Root 'Update-Windows25H2-Launcher.bat'
$LogPath     = Join-Path $Root 'Update-Windows25H2.log'
$StatePath   = Join-Path $Root 'state.json'
$TaskStart   = 'Win11-25H2-CurrentUpdates-AtStartup'
$TaskRetry   = 'Win11-25H2-CurrentUpdates-Retry'
$ServiceId   = '7971f918-a847-4430-9279-4a52d1efe18d'
$MutexName   = 'Global\Win11_25H2_CurrentUpdates'

function Ensure-Root {
    if (Test-Path -LiteralPath $Root) {
        if ((Get-Item -LiteralPath $Root -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw 'Refusing redirected deployment folder.'
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
    $line = '{0} [Current25H2Updates] {1}' -f [datetime]::UtcNow.ToString('o'),$Message
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    Write-Output $line
}

function Save-State([string]$Phase,[string]$Detail) {
    Ensure-Root
    [ordered]@{
        Schema     = 1
        Computer   = $env:COMPUTERNAME
        Phase      = $Phase
        Detail     = $Detail
        UpdatedUtc = [datetime]::UtcNow.ToString('o')
    } | ConvertTo-Json | Set-Content -LiteralPath $StatePath -Encoding UTF8
}

function Get-OsVersion {
    $cv = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    [pscustomobject]@{
        InstallationType = [string]$cv.InstallationType
        DisplayVersion   = [string]$cv.DisplayVersion
        Build            = [int]$cv.CurrentBuildNumber
        UBR              = [int]$cv.UBR
    }
}

function Assert-25H2 {
    $os = Get-OsVersion
    if ($os.InstallationType -ne 'Client' -or $os.DisplayVersion -ne '25H2' -or $os.Build -ne 26200) {
        throw "This worker requires a Windows 11 25H2 client. Detected $($os.DisplayVersion), installed $($os.Build).$($os.UBR)."
    }
    Write-Log "Detected Windows 11 25H2 build $($os.Build).$($os.UBR)."
}

function Test-RebootPending {
    try {
        $info = New-Object -ComObject Microsoft.Update.SystemInfo
        if ([bool]$info.RebootRequired) { return $true }
    } catch {}
    return (
        (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
        (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
    )
}

function Notify-RestartRequired {
    $message = 'Windows updates installed successfully and require a restart. Please save your work and restart this computer when convenient. No automatic restart has been scheduled.'
    try { & "$env:SystemRoot\System32\msg.exe" '*' /TIME:600 $message 2>&1 | Out-Null } catch {}
    Write-Log $message
}

function Remove-Tasks {
    foreach ($name in @($TaskStart,$TaskRetry)) {
        $task = Get-ScheduledTask -TaskPath '\' -TaskName $name -ErrorAction SilentlyContinue
        if ($task) { Unregister-ScheduledTask -InputObject $task -Confirm:$false }
    }
}

function Install-Tasks {
    Ensure-Root
    Copy-Item -LiteralPath $PSCommandPath -Destination $Worker -Force
    $batch = @'
@echo off
setlocal
set "ROOT=C:\ProgramData\Win11-25H2-Updates"
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
echo [%date% %time%] Launcher started.>>"%ROOT%\Launcher.log"
"%PS%" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%ROOT%\Update-Windows25H2.ps1" >>"%ROOT%\Launcher.log" 2>&1
set "RC=%ERRORLEVEL%"
echo [%date% %time%] Launcher finished with exit code %RC%.>>"%ROOT%\Launcher.log"
exit /b %RC%
'@
    Set-Content -LiteralPath $Launcher -Value $batch -Encoding ASCII

    Remove-Tasks
    $action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\cmd.exe" -Argument '/d /c C:\ProgramData\Win11-25H2-Updates\Update-Windows25H2-Launcher.bat'
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable -ExecutionTimeLimit ([timespan]::Zero)
    Register-ScheduledTask -TaskName $TaskStart -TaskPath '\' -Action $action -Trigger (New-ScheduledTaskTrigger -AtStartup) -Principal $principal -Settings $settings -Force | Out-Null
    $trigger = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(1)) -RepetitionInterval (New-TimeSpan -Hours 6)
    Register-ScheduledTask -TaskName $TaskRetry -TaskPath '\' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Save-State -Phase 'Installed' -Detail 'SYSTEM startup and six-hour retry tasks installed.'
    Start-ScheduledTask -TaskPath '\' -TaskName $TaskRetry
    Write-Log 'SYSTEM update tasks installed and first run started.'
}

function Get-EligibleUpdates {
    $session = New-Object -ComObject Microsoft.Update.Session
    $session.ClientApplicationID = 'Win11-25H2-CurrentUpdates'
    $searcher = $session.CreateUpdateSearcher()
    $searcher.ServerSelection = 3
    $searcher.ServiceID = $ServiceId
    $searcher.Online = $true
    $searcher.IncludePotentiallySupersededUpdates = $false
    Write-Log 'Scanning the public Microsoft Update service for applicable non-preview software updates.'
    $result = $searcher.Search("IsInstalled=0 and IsHidden=0 and Type='Software'")
    $updates = New-Object -ComObject Microsoft.Update.UpdateColl
    for ($i=0; $i -lt $result.Updates.Count; $i++) {
        $update = $result.Updates.Item($i)
        $title = [string]$update.Title
        if ($title -match '(?i)\bpreview\b|feature update to windows|upgrade to windows') {
            Write-Log "Excluded from this maintenance run: $title"
            continue
        }
        try { $update.AcceptEula() } catch { Write-Log "EULA acceptance call for '$title' returned: $($_.Exception.Message)" }
        [void]$updates.Add($update)
        Write-Log "Selected: $title"
    }
    [pscustomobject]@{ Session=$session; Updates=$updates }
}

function Install-UpdatePass {
    $scan = Get-EligibleUpdates
    if ($scan.Updates.Count -eq 0) { return [pscustomobject]@{ Installed=0; Reboot=$false } }

    Save-State -Phase 'Downloading' -Detail "Downloading $($scan.Updates.Count) applicable updates."
    $downloader = $scan.Session.CreateUpdateDownloader()
    $downloader.Updates = $scan.Updates
    $downloadResult = $downloader.Download()
    Write-Log "Download result code=$($downloadResult.ResultCode)."

    $downloaded = New-Object -ComObject Microsoft.Update.UpdateColl
    for ($i=0; $i -lt $scan.Updates.Count; $i++) {
        $update = $scan.Updates.Item($i)
        if ([bool]$update.IsDownloaded) {
            [void]$downloaded.Add($update)
        } else {
            Write-Log "Not downloaded and will retry later: $($update.Title)"
        }
    }
    if ($downloaded.Count -eq 0) { throw 'No selected updates downloaded successfully.' }

    Save-State -Phase 'Installing' -Detail "Installing $($downloaded.Count) downloaded updates."
    $installer = $scan.Session.CreateUpdateInstaller()
    $installer.Updates = $downloaded
    try { $installer.ForceQuiet = $true } catch {}
    try { $installer.AllowSourcePrompts = $false } catch {}
    $installResult = $installer.Install()
    Write-Log "Install result code=$($installResult.ResultCode); reboot required=$($installResult.RebootRequired)."
    for ($i=0; $i -lt $downloaded.Count; $i++) {
        $item = $installResult.GetUpdateResult($i)
        Write-Log "Result=$($item.ResultCode), HRESULT=0x$('{0:X8}' -f ($item.HResult -band 0xffffffff)): $($downloaded.Item($i).Title)"
    }
    if ($installResult.ResultCode -notin 2,3) { throw "Windows Update installation failed with result code $($installResult.ResultCode)." }
    [pscustomobject]@{ Installed=$downloaded.Count; Reboot=[bool]$installResult.RebootRequired }
}

if ($Install) {
    Assert-25H2
    Install-Tasks
    Write-Output 'Windows 11 25H2 update task installed and started. Sophos may exit now.'
    exit 0
}

$mutex = New-Object Threading.Mutex($false,$MutexName)
$locked = $false
try {
    $locked = $mutex.WaitOne(0)
    if (-not $locked) { Write-Output 'Another update worker is already running.'; exit 0 }
    Ensure-Root
    Assert-25H2
    if (Test-RebootPending) {
        Save-State -Phase 'AwaitingRestart' -Detail 'A Windows servicing restart is required before continuing.'
        Notify-RestartRequired
        exit 0
    }

    for ($pass=1; $pass -le 3; $pass++) {
        Write-Log "Starting update pass $pass of 3."
        $result = Install-UpdatePass
        if ($result.Installed -eq 0) {
            Save-State -Phase 'Complete' -Detail 'No applicable non-preview software updates remain.'
            Write-Log 'No applicable non-preview software updates remain. Removing maintenance tasks.'
            Remove-Tasks
            break
        }
        if ($result.Reboot -or (Test-RebootPending)) {
            Save-State -Phase 'AwaitingRestart' -Detail "$($result.Installed) updates installed; restart required."
            Notify-RestartRequired
            break
        }
    }
} catch {
    $detail = $_.Exception.Message
    try { Save-State -Phase 'FailedWillRetry' -Detail $detail; Write-Log "ERROR: $detail" } catch {}
    Write-Error $_
    exit 1
} finally {
    if ($locked) { try { $mutex.ReleaseMutex() } catch {} }
    $mutex.Dispose()
}
