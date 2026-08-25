#requires -version 5.1
[CmdletBinding()]
param(
    [switch]$Install
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Root = Join-Path $env:ProgramData 'Win11-25H2'
$ScriptPath = Join-Path $Root 'Upgrade-25H2.ps1'
$LogPath = Join-Path $Root 'Upgrade-25H2.log'
$StatePath = Join-Path $Root 'state.json'
$StartupTask = 'Win11-25H2-AtStartup'
$RetryTask = 'Win11-25H2-Retry'
$MicrosoftUpdateServiceId = '7971f918-a847-4430-9279-4a52d1efe18d'
$MinimumPrerequisiteBuild = 5074 # KB5064081 (26100.5074) or any later CU

New-Item -Path $Root -ItemType Directory -Force | Out-Null

function Write-Log {
    param([Parameter(Mandatory)][string]$Message, [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO')
    $line = '{0:u} [{1}] {2}' -f (Get-Date), $Level, $Message
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    Write-Output $line
}

function Get-OsInfo {
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    [pscustomobject]@{
        ProductName    = [string]$cv.ProductName
        DisplayVersion = [string]$cv.DisplayVersion
        CurrentBuild   = [int]$cv.CurrentBuild
        UBR            = [int]$cv.UBR
    }
}

function Test-IsSystem {
    return [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq 'S-1-5-18'
}

function Install-ScheduledTasks {
    if (-not (Test-IsSystem)) { throw 'Installation must run as LocalSystem (SYSTEM).' }

    if ($PSCommandPath -ne $ScriptPath) {
        Copy-Item -LiteralPath $PSCommandPath -Destination $ScriptPath -Force
    }

    $action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$ScriptPath`""
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 2) -RestartCount 2 -RestartInterval (New-TimeSpan -Minutes 15)

    Register-ScheduledTask -TaskName $StartupTask -Action $action -Trigger (New-ScheduledTaskTrigger -AtStartup) -Principal $principal -Settings $settings -Description 'Continue and verify the Windows 11 25H2 upgrade after startup.' -Force | Out-Null
    $retryTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Hours 3) -RepetitionDuration (New-TimeSpan -Days 3650)
    Register-ScheduledTask -TaskName $RetryTask -Action $action -Trigger $retryTrigger -Principal $principal -Settings $settings -Description 'Retry the Windows 11 25H2 upgrade every three hours until verified.' -Force | Out-Null
    Write-Log 'Scheduled SYSTEM startup and three-hour retry tasks.'
    Start-ScheduledTask -TaskName $RetryTask
}

function Remove-UpgradeTasks {
    foreach ($name in @($StartupTask, $RetryTask)) {
        if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $name -Confirm:$false
            Write-Log "Removed completed task: $name"
        }
    }
}

function Save-State {
    param([Parameter(Mandatory)][string]$Phase, [string]$Detail = '')
    [pscustomobject]@{ Phase=$Phase; Detail=$Detail; Updated=(Get-Date).ToUniversalTime().ToString('o') } |
        ConvertTo-Json | Set-Content -LiteralPath $StatePath -Encoding UTF8
}

function Request-DelayedRestart {
    param([Parameter(Mandatory)][string]$Reason)
    Save-State -Phase 'RestartPending' -Detail $Reason
    $message = "Windows 11 maintenance has installed required updates. This computer will restart in 60 minutes to continue the Windows 11 25H2 upgrade. Save your work now. Reason: $Reason"
    & "$env:SystemRoot\System32\msg.exe" * /TIME:3600 $message 2>&1 | ForEach-Object { Write-Log ([string]$_) }
    $p = Start-Process -FilePath "$env:SystemRoot\System32\shutdown.exe" -ArgumentList @('/r','/t','3600','/d','p:2:17','/c',"`"$message`"") -Wait -PassThru -WindowStyle Hidden
    if ($p.ExitCode -eq 0) {
        Write-Log "Scheduled restart in 60 minutes: $Reason"
    } else {
        Write-Log "Restart request returned exit code $($p.ExitCode), usually because a restart is already scheduled." 'WARN'
    }
}

function New-MicrosoftUpdateSearcher {
    $manager = New-Object -ComObject Microsoft.Update.ServiceManager
    $manager.ClientApplicationID = 'Win11-25H2-Sophos'
    try { $null = $manager.AddService2($MicrosoftUpdateServiceId, 7, '') } catch { Write-Log "Microsoft Update registration note: $($_.Exception.Message)" 'WARN' }
    $session = New-Object -ComObject Microsoft.Update.Session
    $session.ClientApplicationID = 'Win11-25H2-Sophos'
    $searcher = $session.CreateUpdateSearcher()
    $searcher.ServerSelection = 3 # ssOthers; explicitly bypasses the managed WSUS source
    $searcher.ServiceID = $MicrosoftUpdateServiceId
    return [pscustomobject]@{ Session=$session; Searcher=$searcher }
}

function Find-Updates {
    param([Parameter(Mandatory)]$Searcher, [Parameter(Mandatory)][scriptblock]$Predicate)
    Write-Log 'Scanning the public Microsoft Update service.'
    $result = $Searcher.Search("IsInstalled=0 and IsHidden=0 and Type='Software'")
    $matches = @()
    for ($i=0; $i -lt $result.Updates.Count; $i++) {
        $update = $result.Updates.Item($i)
        if (& $Predicate $update) { $matches += $update }
    }
    return $matches
}

function Install-Updates {
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)][object[]]$Updates)
    if ($Updates.Count -eq 0) { throw 'No applicable update was supplied to Install-Updates.' }
    $collection = New-Object -ComObject Microsoft.Update.UpdateColl
    foreach ($update in $Updates) {
        if (-not $update.EulaAccepted) { $update.AcceptEula() }
        $null = $collection.Add($update)
        Write-Log "Selected update: $($update.Title)"
    }
    $downloader = $Session.CreateUpdateDownloader()
    $downloader.Updates = $collection
    $download = $downloader.Download()
    if ($download.ResultCode -notin 2,3) { throw "Update download failed with WUA result code $($download.ResultCode), HRESULT 0x{0:X8}." -f ($download.HResult -band 0xffffffff) }
    $installer = $Session.CreateUpdateInstaller()
    $installer.Updates = $collection
    $installResult = $installer.Install()
    Write-Log "Install completed with WUA result code $($installResult.ResultCode), HRESULT 0x$('{0:X8}' -f ($installResult.HResult -band 0xffffffff)), reboot required: $($installResult.RebootRequired)."
    if ($installResult.ResultCode -notin 2,3) { throw "Update installation failed with WUA result code $($installResult.ResultCode)." }
    return $installResult
}

if ($Install) {
    Install-ScheduledTasks
    exit 0
}

$createdMutex = $false
$mutex = New-Object Threading.Mutex($false, 'Global\Win11-25H2-Upgrade', [ref]$createdMutex)
if (-not $mutex.WaitOne(0)) {
    Write-Log 'Another upgrade instance is already running; this invocation will exit.' 'WARN'
    exit 0
}

try {
    if (-not (Test-IsSystem)) { throw 'Upgrade execution must run as LocalSystem (SYSTEM).' }
    $os = Get-OsInfo
    Write-Log "Detected $($os.ProductName), version $($os.DisplayVersion), build $($os.CurrentBuild).$($os.UBR)."

    if ($os.ProductName -notlike '*Windows 11*') { throw 'This script only supports Windows 11.' }
    if ($os.DisplayVersion -eq '25H2' -and $os.CurrentBuild -ge 26200) {
        Save-State -Phase 'Complete' -Detail "Verified Windows 11 25H2 build $($os.CurrentBuild).$($os.UBR)"
        Write-Log 'Windows 11 25H2 is verified. Upgrade workflow is complete.'
        Remove-UpgradeTasks
        exit 0
    }
    if ($os.DisplayVersion -ne '24H2' -or $os.CurrentBuild -ne 26100) {
        throw "Out of scope: only Windows 11 24H2 (build 26100) is targeted; detected $($os.DisplayVersion) build $($os.CurrentBuild)."
    }

    $wu = New-MicrosoftUpdateSearcher
    if ($os.UBR -lt $MinimumPrerequisiteBuild) {
        Save-State -Phase 'InstallingPrerequisite' -Detail "Build is below 26100.$MinimumPrerequisiteBuild"
        $cus = @(Find-Updates -Searcher $wu.Searcher -Predicate {
            param($u)
            $u.Title -match '(?i)Cumulative Update for Windows 11 Version 24H2' -and
            $u.Title -notmatch '(?i)Preview|Dynamic Update|\.NET Framework'
        })
        if ($cus.Count -eq 0) { throw 'No applicable non-preview Windows 11 24H2 cumulative update was offered by Microsoft Update.' }
        $chosen = @($cus | Sort-Object LastDeploymentChangeTime -Descending | Select-Object -First 1)
        $result = Install-Updates -Session $wu.Session -Updates $chosen
        Request-DelayedRestart -Reason '24H2 cumulative update prerequisite installed'
        exit 0
    }

    Save-State -Phase 'Installing25H2' -Detail 'Prerequisite build verified'
    $featureUpdates = @(Find-Updates -Searcher $wu.Searcher -Predicate {
        param($u)
        $u.Title -match '(?i)^Windows 11,? version 25H2$|Feature update to Windows 11,? version 25H2'
    })
    if ($featureUpdates.Count -eq 0) { throw 'Microsoft Update did not offer Windows 11 version 25H2. The device may be under a safeguard hold or not yet eligible; the task will retry.' }
    $feature = @($featureUpdates | Sort-Object LastDeploymentChangeTime -Descending | Select-Object -First 1)
    $result = Install-Updates -Session $wu.Session -Updates $feature
    Request-DelayedRestart -Reason 'Windows 11 version 25H2 installed'
}
catch {
    $detail = $_ | Out-String
    Save-State -Phase 'FailedWillRetry' -Detail $_.Exception.Message
    Write-Log $detail.Trim() 'ERROR'
    exit 1
}
finally {
    if ($mutex) { try { $mutex.ReleaseMutex() } catch {}; $mutex.Dispose() }
}
