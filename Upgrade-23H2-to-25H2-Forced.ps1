#requires -Version 5.1
<#
Sophos/RMM-safe Windows 11 23H2 -> 25H2 in-place upgrade worker.

The Sophos bootstrap calls this script with -Install. That mode only copies the
worker, creates SYSTEM scheduled tasks, starts the retry task, and returns.
Long-running media acquisition and Windows Setup work happens in Task Scheduler.

Media acquisition uses a SHA256-pinned copy of Fido 1.70 to obtain a temporary
official Microsoft Windows 11 25H2 retail ISO URL. Fido is not redistributed.
#>

[CmdletBinding()]
param(
    [switch]$Install,
    [switch]$CheckOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    $nativePowerShell = Join-Path $env:SystemRoot 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
    $nativeArguments = @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$PSCommandPath)
    if ($Install) { $nativeArguments += '-Install' }
    if ($CheckOnly) { $nativeArguments += '-CheckOnly' }
    & $nativePowerShell @nativeArguments
    exit $LASTEXITCODE
}

$Root          = 'C:\ProgramData\Win11-23H2-Forced25H2'
$Worker        = Join-Path $Root 'Upgrade-23H2-to-25H2-Forced.ps1'
$Launcher      = Join-Path $Root 'Win11-23H2-Forced25H2-Launcher.bat'
$LogPath       = Join-Path $Root 'Upgrade-23H2-to-25H2-Forced.log'
$LauncherLog   = Join-Path $Root 'Launcher.log'
$StatePath     = Join-Path $Root 'state.json'
$IsoPath       = Join-Path $Root 'Win11-25H2-English-x64.iso'
$FidoPath      = Join-Path $Root 'Fido-1.70.ps1'
$CompatLogs    = Join-Path $Root 'CompatLogs.zip'
$SetupLogs     = Join-Path $Root 'SetupLogs.zip'
$TaskStart     = 'Win11-23H2-Forced25H2-AtStartup'
$TaskRetry     = 'Win11-23H2-Forced25H2-Retry'
$TaskNames     = @($TaskStart,$TaskRetry)
$LegacyTasks   = @('Win11-23H2-to-25H2-AtStartup','Win11-23H2-to-25H2-Retry')
$MutexName     = 'Global\Win11_23H2_Forced25H2'
$MinimumFreeGB = 35

$FidoCommit = '3d47260b8915385c58e20c73e24b36e9a9536f3f'
$FidoUri    = "https://raw.githubusercontent.com/pbatard/Fido/$FidoCommit/Fido.ps1"
$FidoHash   = '24C86067FA399D2FD75EF0693A2EC79CA8DB162827F808CAAC03541CBF640C13'

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

function Protect-File([string]$Path) {
    $acl = Get-Acl -LiteralPath $Path
    $acl.SetSecurityDescriptorSddlForm('O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)')
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Write-Log([string]$Message) {
    Ensure-Root
    $line = '{0} [ForcedMedia25H2] {1}' -f [datetime]::UtcNow.ToString('o'),$Message
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    Write-Host $line
}

function Get-BootStamp {
    (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
}

function Get-OsSnapshot {
    $cv = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $os = Get-CimInstance Win32_OperatingSystem
    $systemLocale = Get-WinSystemLocale
    [pscustomobject]@{
        InstallationType = [string]$cv.InstallationType
        DisplayVersion   = [string]$cv.DisplayVersion
        Build            = [int]$cv.CurrentBuildNumber
        UBR              = [int]$cv.UBR
        RunningBuild     = [int]$os.BuildNumber
        Edition          = [string]$cv.EditionID
        Architecture     = $env:PROCESSOR_ARCHITECTURE
        SystemLocale     = [string]$systemLocale.Name
        BootStamp        = Get-BootStamp
    }
}

function Get-Disposition([object]$Os) {
    if ($Os.InstallationType -ne 'Client' -or $Os.Architecture -ne 'AMD64') { return 'Unsupported' }
    if ($Os.DisplayVersion -eq '25H2' -and $Os.Build -eq 26200 -and $Os.RunningBuild -eq 26200) { return 'Complete' }
    if ($Os.DisplayVersion -eq '25H2' -and $Os.Build -eq 26200 -and $Os.RunningBuild -ne 26200) { return 'Staged' }
    if ($Os.DisplayVersion -eq '24H2' -and $Os.Build -eq 26100 -and $Os.RunningBuild -eq 26100) { return 'Already24H2' }
    if ($Os.DisplayVersion -eq '23H2' -and $Os.Build -eq 22631 -and $Os.RunningBuild -eq 22631) { return 'Upgrade23H2' }
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
        IsoBytes      = 0
    }
}

function Load-State {
    $state = New-DefaultState
    if (Test-Path -LiteralPath $StatePath) {
        try {
            $loaded = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
            if ([int]$loaded.Schema -ne 1) { throw 'Unsupported state schema.' }
            foreach ($property in $loaded.PSObject.Properties) { $state[$property.Name] = $property.Value }
        } catch {
            Write-Log "State file could not be read and will be recreated: $($_.Exception.Message)"
        }
    }
    return $state
}

function Save-State([hashtable]$State,[string]$Phase,[string]$Detail) {
    Ensure-Root
    $State.Phase = $Phase
    $State.Detail = $Detail
    $State.UpdatedUtc = [datetime]::UtcNow.ToString('o')
    $temporary = Join-Path $Root ('state-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $State | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $temporary -Encoding UTF8
        Move-Item -LiteralPath $temporary -Destination $StatePath -Force
        Protect-File $StatePath
    } finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    }
}

function Test-RebootPending {
    try {
        $systemInfo = New-Object -ComObject Microsoft.Update.SystemInfo
        if ($systemInfo.RebootRequired) { return $true }
    } catch {}

    return (
        (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
        (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
    )
}

function Assert-OwnedTask([string]$Name,[string]$AllowedPattern) {
    $task = Get-ScheduledTask -TaskPath '\' -TaskName $Name -ErrorAction SilentlyContinue
    if (-not $task) { return }
    foreach ($action in @($task.Actions)) {
        if (($action.Execute + ' ' + $action.Arguments) -notmatch $AllowedPattern) {
            throw "Task name collision detected for $Name; refusing to modify it."
        }
    }
}

function Remove-TaskSet([string[]]$Names,[string]$AllowedPattern) {
    foreach ($name in $Names) {
        Assert-OwnedTask -Name $name -AllowedPattern $AllowedPattern
        $task = Get-ScheduledTask -TaskPath '\' -TaskName $name -ErrorAction SilentlyContinue
        if ($task) {
            Unregister-ScheduledTask -InputObject $task -Confirm:$false
            Write-Log "Removed scheduled task $name."
        }
    }
}

function Remove-DeploymentTasks {
    Remove-TaskSet -Names $TaskNames -AllowedPattern '(?i)C:\\ProgramData\\Win11-23H2-Forced25H2\\Win11-23H2-Forced25H2-Launcher\.bat'
}

function Remove-LegacyTasks {
    Remove-TaskSet -Names $LegacyTasks -AllowedPattern '(?i)C:\\ProgramData\\Win11-23H2-to-25H2\\Win11-23H2-Launcher\.bat'
}

function Write-Launcher {
    $launcherText = @'
@echo off
setlocal
set "ROOT=C:\ProgramData\Win11-23H2-Forced25H2"
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
echo [%date% %time%] Forced-media launcher started.>>"%ROOT%\Launcher.log"
"%PS%" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%ROOT%\Upgrade-23H2-to-25H2-Forced.ps1" >>"%ROOT%\Launcher.log" 2>&1
set "RC=%ERRORLEVEL%"
echo [%date% %time%] Launcher finished with exit code %RC%.>>"%ROOT%\Launcher.log"
exit /b %RC%
'@
    [IO.File]::WriteAllText($Launcher,($launcherText -replace '\r?\n',"`r`n"),[Text.Encoding]::ASCII)
}

function Install-Tasks([string]$SourceFile) {
    Ensure-Root
    foreach ($name in $TaskNames) {
        Assert-OwnedTask -Name $name -AllowedPattern '(?i)C:\\ProgramData\\Win11-23H2-Forced25H2\\Win11-23H2-Forced25H2-Launcher\.bat'
    }
    foreach ($name in $LegacyTasks) {
        Assert-OwnedTask -Name $name -AllowedPattern '(?i)C:\\ProgramData\\Win11-23H2-to-25H2\\Win11-23H2-Launcher\.bat'
    }

    if ([IO.Path]::GetFullPath($SourceFile) -ne [IO.Path]::GetFullPath($Worker)) {
        Copy-Item -LiteralPath $SourceFile -Destination $Worker -Force
    }
    Write-Launcher
    Protect-File $Worker
    Protect-File $Launcher

    $action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\cmd.exe" -Argument '/d /c C:\ProgramData\Win11-23H2-Forced25H2\Win11-23H2-Forced25H2-Launcher.bat'
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([timespan]::Zero)

    Register-ScheduledTask -TaskPath '\' -TaskName $TaskStart -Action $action -Principal $principal -Settings $settings -Trigger (New-ScheduledTaskTrigger -AtStartup) -Force | Out-Null
    $retryTrigger = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(1)) -RepetitionInterval (New-TimeSpan -Hours 3)
    Register-ScheduledTask -TaskPath '\' -TaskName $TaskRetry -Action $action -Principal $principal -Settings $settings -Trigger $retryTrigger -Force | Out-Null

    Remove-LegacyTasks
    $state = Load-State
    Save-State -State $state -Phase 'Installed' -Detail 'SYSTEM startup and three-hour retry tasks installed.'
    Write-Log 'Forced-media SYSTEM tasks installed. The old public-Windows-Update-only 23H2 tasks were removed.'
    Start-ScheduledTask -TaskPath '\' -TaskName $TaskRetry
    Write-Output 'Forced-media SYSTEM tasks installed and first run started.'
}

function Request-Restart([hashtable]$State,[string]$Reason) {
    $State.BootStamp = Get-BootStamp
    Save-State -State $State -Phase 'AwaitingRestart' -Detail $Reason
    $message = "Windows 11 25H2 is ready to continue installing. This computer will restart in 10 minutes. Save your work; applications will close. $Reason"

    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        try { & "$env:SystemRoot\System32\msg.exe" '*' /TIME:600 $message 2>&1 | Out-Null } catch {}
        $output = & "$env:SystemRoot\System32\shutdown.exe" /r /t 600 /d p:2:3 /c $message 2>&1
        $code = $LASTEXITCODE
        if ($code -notin 0,1190) { throw "Restart scheduling failed ($code): $($output | Out-String)" }
        Write-Log "Restart requested in 10 minutes. Reason: $Reason"
    } finally {
        $ErrorActionPreference = $oldPreference
    }
}

function Assert-Preflight([object]$Os) {
    if ((Get-Disposition $Os) -ne 'Upgrade23H2') {
        throw "This media worker requires x64 Windows 11 23H2 build 22631. Detected $($Os.DisplayVersion), build $($Os.Build), running $($Os.RunningBuild), edition $($Os.Edition)."
    }
    if ($Os.Edition -notin @('Professional','Core','Education')) {
        throw "The Microsoft consumer ISO does not safely cover edition '$($Os.Edition)' in this worker."
    }
    if ($Os.SystemLocale -ne 'en-US') {
        throw "This reviewed worker is limited to en-US installations. Detected system locale $($Os.SystemLocale)."
    }
    $systemDrive = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
    $freeGB = [math]::Round(([double]$systemDrive.FreeSpace / 1GB),1)
    if ($freeGB -lt $MinimumFreeGB) { throw "Insufficient free space: $freeGB GB available; $MinimumFreeGB GB required." }
    Write-Log "Preflight passed: edition=$($Os.Edition), locale=$($Os.SystemLocale), free=${freeGB}GB."
}

function Enable-SupportedSetupBypass {
    $moSetup = 'HKLM:\SYSTEM\Setup\MoSetup'
    if (-not (Test-Path -LiteralPath $moSetup)) { New-Item -Path $moSetup -Force | Out-Null }
    New-ItemProperty -Path $moSetup -Name AllowUpgradesWithUnsupportedTPMOrCPU -PropertyType DWord -Value 1 -Force | Out-Null
    Write-Log 'Enabled the Microsoft-documented MoSetup TPM/CPU allowance. No Microsoft binaries or reboot flags were modified.'
}

function Get-PinnedFido {
    Ensure-Root
    $valid = $false
    if (Test-Path -LiteralPath $FidoPath) {
        $valid = ((Get-FileHash -LiteralPath $FidoPath -Algorithm SHA256).Hash -eq $FidoHash)
    }
    if (-not $valid) {
        Remove-Item -LiteralPath $FidoPath -Force -ErrorAction SilentlyContinue
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -UseBasicParsing -Uri $FidoUri -OutFile $FidoPath -TimeoutSec 60
    }

    $actualHash = (Get-FileHash -LiteralPath $FidoPath -Algorithm SHA256).Hash
    if ($actualHash -ne $FidoHash) {
        Remove-Item -LiteralPath $FidoPath -Force -ErrorAction SilentlyContinue
        throw "Pinned Fido SHA256 mismatch. Expected $FidoHash, received $actualHash."
    }
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($FidoPath,[ref]$tokens,[ref]$errors)
    if ($errors.Count) { throw 'Pinned Fido script contains PowerShell syntax errors.' }
    $header = Get-Content -LiteralPath $FidoPath -TotalCount 5 | Out-String
    if ($header -notmatch 'Fido v1\.70') { throw 'Pinned Fido header was not recognized.' }
    Protect-File $FidoPath
    return $FidoPath
}

function Get-MicrosoftIsoUrl {
    $fido = Get-PinnedFido
    $powerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    Write-Log 'Requesting a temporary official Microsoft Windows 11 25H2 x64 English ISO URL through pinned Fido 1.70.'
    $output = & $powerShell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $fido -Win 11 -Rel Latest -Ed Pro -Lang English -Arch x64 -GetUrl 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Fido URL request failed with exit code $LASTEXITCODE`: $($output | Out-String)" }
    $urls = @($output | ForEach-Object { [string]$_ } | Where-Object { $_ -match '^https://' })
    if ($urls.Count -ne 1) { throw "Fido returned $($urls.Count) candidate URLs instead of one." }

    $uri = [uri]$urls[0]
    $allowedHosts = @('software.download.prss.microsoft.com','software-download.microsoft.com')
    if ($uri.Scheme -ne 'https' -or $uri.Host -notin $allowedHosts) { throw "Refusing non-Microsoft media URL host: $($uri.Host)" }
    if ($uri.AbsolutePath -notmatch '(?i)Win11_25H2_English_x64.*\.iso$') { throw "Unexpected Microsoft media filename: $($uri.AbsolutePath)" }
    return $uri.AbsoluteUri
}

function Download-Iso([string]$Url,[hashtable]$State) {
    $partial = "$IsoPath.partial"
    Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
    Write-Log 'Downloading the official Microsoft 25H2 ISO with BITS. This continues inside the SYSTEM scheduled task, not Sophos Live Action.'
    Import-Module BitsTransfer -ErrorAction Stop
    Start-BitsTransfer -Source $Url -Destination $partial -DisplayName 'Win11-25H2-ForcedMedia' -Description 'Official Microsoft Windows 11 25H2 ISO' -Priority Foreground -RetryInterval 60 -RetryTimeout 86400
    $bytes = (Get-Item -LiteralPath $partial).Length
    if ($bytes -lt 5GB -or $bytes -gt 12GB) {
        Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
        throw "Downloaded ISO size $bytes bytes is outside the expected range."
    }
    Move-Item -LiteralPath $partial -Destination $IsoPath -Force
    Protect-File $IsoPath
    $State.IsoBytes = $bytes
    Save-State -State $State -Phase 'MediaDownloaded' -Detail "Official Microsoft ISO downloaded: $bytes bytes."
    Write-Log "Microsoft ISO download completed: $bytes bytes."
}

function Test-MicrosoftSignature([string]$Path) {
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne 'Valid' -or -not $signature.SignerCertificate -or $signature.SignerCertificate.Subject -notmatch '(?i)Microsoft') {
        throw "Microsoft signature validation failed for $Path. Status=$($signature.Status)."
    }
}

function Mount-AndValidateIso {
    if (-not (Test-Path -LiteralPath $IsoPath)) { throw 'ISO is not present.' }
    $bytes = (Get-Item -LiteralPath $IsoPath).Length
    if ($bytes -lt 5GB -or $bytes -gt 12GB) { throw "Cached ISO size $bytes bytes is outside the expected range." }

    $disk = Get-DiskImage -ImagePath $IsoPath -ErrorAction SilentlyContinue
    if (-not $disk -or -not $disk.Attached) { $disk = Mount-DiskImage -ImagePath $IsoPath -PassThru -ErrorAction Stop }
    Start-Sleep -Seconds 3
    $volume = $disk | Get-Volume | Where-Object DriveLetter | Select-Object -First 1
    if (-not $volume) { throw 'Mounted ISO has no drive letter.' }
    $drive = "$($volume.DriveLetter):"
    $setup = Join-Path $drive 'setup.exe'
    $setupPrep = Join-Path $drive 'sources\setupprep.exe'
    if (-not (Test-Path -LiteralPath $setup) -or -not (Test-Path -LiteralPath $setupPrep)) { throw 'Mounted media is missing Windows Setup executables.' }
    Test-MicrosoftSignature $setup
    Test-MicrosoftSignature $setupPrep
    $setupVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($setup).ProductVersion

    $imagePath = @(
        (Join-Path $drive 'sources\install.wim'),
        (Join-Path $drive 'sources\install.esd')
    ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $imagePath) { throw 'Mounted media is missing install.wim/install.esd.' }
    $images = @(Get-WindowsImage -ImagePath $imagePath -ErrorAction Stop)
    $editionPattern = switch ((Get-OsSnapshot).Edition) {
        'Professional' { '^Windows 11 Pro$' }
        'Core'         { '^Windows 11 Home$' }
        'Education'    { '^Windows 11 Education$' }
        default        { '^$' }
    }
    # The list form of Get-WindowsImage returns summary objects on some Windows
    # builds. Those objects have ImageName/ImageIndex but no Version property.
    # Query matching editions by index to obtain their detailed version data.
    $editionImages = @($images | Where-Object { $_.ImageName -match $editionPattern })
    $matchingImages = @()
    $inspected = @()
    foreach ($candidate in $editionImages) {
        $detail = Get-WindowsImage -ImagePath $imagePath -Index ([uint32]$candidate.ImageIndex) -ErrorAction Stop
        $versionProperty = $detail.PSObject.Properties['Version']
        if (-not $versionProperty -or -not $versionProperty.Value) {
            throw "Detailed image metadata for index $($candidate.ImageIndex) does not include a Version value."
        }
        $imageVersion = [version][string]$versionProperty.Value
        $inspected += "$($candidate.ImageName) [$imageVersion]"
        if ($imageVersion.Build -eq 26200) { $matchingImages += $detail }
    }
    if (-not $matchingImages.Count) {
        $available = if ($inspected.Count) {
            $inspected -join '; '
        } else {
            ($images | ForEach-Object { "$($_.ImageName) [index $($_.ImageIndex)]" }) -join '; '
        }
        throw "Media does not contain the required Windows 11 25H2 build-26200 edition. Available: $available"
    }
    Write-Log "Mounted official Microsoft media at $drive; setup.exe version=$setupVersion, build-26200 edition image found, and Setup signatures are valid."
    [pscustomobject]@{ Disk=$disk; Drive=$drive; Setup=$setup; Version=$setupVersion; ImagePath=$imagePath }
}

function Dismount-IsoSafely {
    try {
        $disk = Get-DiskImage -ImagePath $IsoPath -ErrorAction SilentlyContinue
        if ($disk -and $disk.Attached) { Dismount-DiskImage -ImagePath $IsoPath -ErrorAction Stop }
    } catch {
        Write-Log "ISO dismount warning: $($_.Exception.Message)"
    }
}

function Get-ExitHex([int]$Code) {
    '{0:X8}' -f ($Code -band 0xffffffff)
}

function Invoke-CompatibilityScan([string]$Setup,[hashtable]$State) {
    Remove-Item -LiteralPath $CompatLogs -Force -ErrorAction SilentlyContinue
    $arguments = @('/auto','upgrade','/quiet','/eula','accept','/dynamicupdate','enable','/compat','scanonly','/copylogs',$CompatLogs)
    Save-State -State $State -Phase 'CompatibilityScan' -Detail 'Running Windows Setup compatibility scan.'
    Write-Log "Starting Windows Setup compatibility scan: $($arguments -join ' ')"
    $process = Start-Process -FilePath $Setup -ArgumentList $arguments -PassThru -Wait -WindowStyle Hidden
    $hex = Get-ExitHex $process.ExitCode
    Write-Log "Compatibility scan exit code=$($process.ExitCode) (0x$hex)."
    if ($hex -ne 'C1900210') {
        $meaning = switch ($hex) {
            'C1900200' { 'hardware/system-requirement block' }
            'C1900204' { 'requested migration choice is unavailable' }
            'C1900208' { 'incompatible application or driver block' }
            'C190020E' { 'insufficient disk space' }
            default { 'unrecognized compatibility result' }
        }
        throw "Windows Setup compatibility scan did not approve the upgrade: 0x$hex ($meaning). Review $CompatLogs and Panther logs."
    }
}

function Invoke-InPlaceUpgrade([string]$Setup,[hashtable]$State) {
    Remove-Item -LiteralPath $SetupLogs -Force -ErrorAction SilentlyContinue
    $arguments = @('/auto','upgrade','/quiet','/eula','accept','/dynamicupdate','enable','/compat','ignorewarning','/showoobe','none','/bitlocker','alwayssuspend','/priority','low','/noreboot','/copylogs',$SetupLogs)
    $State.Attempts = [int]$State.Attempts + 1
    Save-State -State $State -Phase 'Installing25H2' -Detail 'Windows Setup is running silently in the SYSTEM scheduled task.'
    Write-Log "Launching Windows Setup attempt $($State.Attempts): $($arguments -join ' ')"
    $process = Start-Process -FilePath $Setup -ArgumentList $arguments -PassThru -Wait -WindowStyle Hidden
    $hex = Get-ExitHex $process.ExitCode
    $State.SetupExitCode = "0x$hex"
    Write-Log "Windows Setup exit code=$($process.ExitCode) (0x$hex)."
    if ($process.ExitCode -notin 0,1641,3010) {
        throw "Windows Setup did not return a success/restart-required code: 0x$hex. Review $SetupLogs and C:\`$WINDOWS.~BT\Sources\Panther."
    }
    Request-Restart -State $State -Reason 'Windows Setup completed the online phase successfully.'
}

function Show-Check {
    $os = Get-OsSnapshot
    $stateText = if (Test-Path -LiteralPath $StatePath) { Get-Content -LiteralPath $StatePath -Raw } else { 'No state file.' }
    [pscustomobject]@{
        Computer       = $env:COMPUTERNAME
        DisplayVersion = $os.DisplayVersion
        InstalledBuild = ('{0}.{1}' -f $os.Build,$os.UBR)
        RunningBuild   = $os.RunningBuild
        Edition        = $os.Edition
        SystemLocale   = $os.SystemLocale
        Disposition    = Get-Disposition $os
    } | Format-List | Out-String -Width 220 | Write-Output
    Write-Output $stateText
}

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
        Write-Output 'This device is already 24H2. Use the existing normal 24H2-to-25H2 Sophos command.'
        exit 0
    }
    if ($initialDisposition -ne 'Upgrade23H2') {
        throw "This bootstrap targets x64 Windows 11 23H2 build 22631. Detected $($initial.DisplayVersion), build $($initial.Build), running $($initial.RunningBuild)."
    }
    Install-Tasks -SourceFile $PSCommandPath
    exit 0
}

$mutex = New-Object Threading.Mutex($false,$MutexName)
$locked = $false
$state = $null
try {
    $locked = $mutex.WaitOne(0)
    if (-not $locked) {
        Write-Output 'Another forced-media worker is already running. Exiting without overlap.'
        exit 0
    }

    Ensure-Root
    $state = Load-State
    $os = Get-OsSnapshot
    switch (Get-Disposition $os) {
        'Complete' {
            Save-State -State $state -Phase 'Complete' -Detail "Windows 11 25H2 build 26200.$($os.UBR) verified after reboot."
            Write-Log "Windows 11 25H2 build 26200.$($os.UBR) verified. Cleaning tasks and cached ISO."
            Dismount-IsoSafely
            Remove-Item -LiteralPath $IsoPath,"$IsoPath.partial" -Force -ErrorAction SilentlyContinue
            Remove-DeploymentTasks
            Remove-LegacyTasks
        }
        'Staged' {
            Request-Restart -State $state -Reason 'Windows 11 25H2 is staged but the running kernel has not changed.'
        }
        'Already24H2' {
            Save-State -State $state -Phase 'Reached24H2' -Detail '24H2 detected. Use the existing normal 24H2-to-25H2 Sophos command.'
            Write-Log '24H2 detected. Removing forced-media tasks; the existing normal 24H2-to-25H2 command is now applicable.'
            Remove-DeploymentTasks
            Remove-LegacyTasks
        }
        'Upgrade23H2' {
            if ($state.Phase -eq 'AwaitingRestart' -and $state.BootStamp -eq $os.BootStamp) {
                Request-Restart -State $state -Reason 'The prepared 25H2 upgrade is still awaiting its first restart.'
                break
            }
            if (Test-RebootPending) {
                Request-Restart -State $state -Reason 'Windows servicing requires a restart before the media upgrade can start.'
                break
            }

            Assert-Preflight $os
            Enable-SupportedSetupBypass
            $media = $null
            try {
                if (Test-Path -LiteralPath $IsoPath) {
                    try { $media = Mount-AndValidateIso } catch {
                        Dismount-IsoSafely
                        Remove-Item -LiteralPath $IsoPath -Force -ErrorAction SilentlyContinue
                        Write-Log "Cached ISO validation failed and it was removed: $($_.Exception.Message)"
                    }
                }
                if (-not $media) {
                    $url = Get-MicrosoftIsoUrl
                    Download-Iso -Url $url -State $state
                    $media = Mount-AndValidateIso
                }
                Invoke-CompatibilityScan -Setup $media.Setup -State $state
                Invoke-InPlaceUpgrade -Setup $media.Setup -State $state
            } finally {
                Dismount-IsoSafely
            }
        }
        default {
            throw "Unsupported or inconsistent OS state: $($os.DisplayVersion), build $($os.Build), running $($os.RunningBuild), edition $($os.Edition)."
        }
    }
} catch {
    $detail = $_.Exception.Message
    try {
        if (-not $state) { $state = Load-State }
        Save-State -State $state -Phase 'FailedWillRetry' -Detail $detail
        Write-Log "ERROR: $detail"
    } catch {}
    Write-Error $_
    exit 1
} finally {
    if ($locked) { try { $mutex.ReleaseMutex() } catch {} }
    $mutex.Dispose()
}

exit 0
