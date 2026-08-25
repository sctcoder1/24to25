#requires -version 5.1

$ErrorActionPreference = 'Stop'

# ============================================================
# Windows 11 24H2 -> 25H2 Self-Healing Upgrade
# ============================================================

$BaseDir     = 'C:\ProgramData\Win11-25H2'
$ScriptPath  = Join-Path $BaseDir 'Upgrade-24H2-to-25H2.ps1'
$LogFile     = Join-Path $BaseDir 'Upgrade.log'

$StartupTask = 'Win11-25H2-Startup'
$RetryTask   = 'Win11-25H2-Retry'

$MinimumUBR  = 5074

New-Item -ItemType Directory -Path $BaseDir -Force | Out-Null


# ============================================================
# Logging
# ============================================================

function Write-Log {
    param([string]$Message)

    $Line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Message"

    try {
        Add-Content -Path $LogFile -Value $Line
    }
    catch {}

    Write-Host $Line
}


# ============================================================
# Determine if this process is running interactively
# ============================================================

function Test-InteractiveSession {

    try {
        $Process = Get-Process -Id $PID
        return ($Process.SessionId -ne 0)
    }
    catch {
        return $false
    }
}


# ============================================================
# Notify / Prompt User For Reboot
# ============================================================

function Request-Reboot {

    param(
        [string]$Reason
    )

    Write-Log "Restart required: $Reason"

    # --------------------------------------------------------
    # If manually running in logged-in user's session,
    # give them an actual Yes / No dialog.
    # --------------------------------------------------------

    if (Test-InteractiveSession) {

        try {

            Add-Type -AssemblyName PresentationFramework

            $Message = @"
Windows needs to restart to continue the Windows 11 25H2 upgrade.

$Reason

Would you like to restart now?

If you choose No, you can restart later. The upgrade will automatically continue after the computer restarts.
"@

            $Result = [System.Windows.MessageBox]::Show(
                $Message,
                'Windows 11 25H2 Upgrade',
                [System.Windows.MessageBoxButton]::YesNo,
                [System.Windows.MessageBoxImage]::Information
            )

            if ($Result -eq [System.Windows.MessageBoxResult]::Yes) {

                Write-Log 'User chose to restart now.'

                shutdown.exe /r /t 60 /d p:2:4 /c `
                    "Windows 11 upgrade is continuing. This computer will restart in 60 seconds."

                return
            }

            Write-Log 'User chose to restart later.'
            return
        }
        catch {
            Write-Log "Interactive reboot prompt failed: $($_.Exception.Message)"
        }
    }


    # --------------------------------------------------------
    # SYSTEM tasks run in Session 0 and cannot display normal
    # MessageBox UI directly.
    #
    # msg.exe can display to the currently logged-in session.
    # --------------------------------------------------------

    try {

        $Message = @"
Windows needs to restart to continue the Windows 11 25H2 upgrade.

$Reason

Please save your work and restart this computer when convenient.

The upgrade will automatically continue after the restart.
"@

        & msg.exe * $Message

        Write-Log 'Sent restart notification to logged-in user.'
    }
    catch {

        Write-Log "Could not notify logged-in user: $($_.Exception.Message)"
    }
}


# ============================================================
# Pending Reboot Detection
# ============================================================

function Test-PendingReboot {

    $Checks = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    )

    foreach ($Check in $Checks) {

        if (Test-Path $Check) {
            return $true
        }
    }

    try {

        $PendingRename = Get-ItemProperty `
            'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' `
            -Name PendingFileRenameOperations `
            -ErrorAction SilentlyContinue

        if ($PendingRename.PendingFileRenameOperations) {
            return $true
        }
    }
    catch {}

    return $false
}


# ============================================================
# Scheduled Tasks
# ============================================================

function Install-SelfHealingTasks {

    Write-Log 'Ensuring self-healing scheduled tasks exist.'

    $TaskCommand = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`""

    # Startup task
    & schtasks.exe /Create `
        /TN $StartupTask `
        /SC ONSTART `
        /DELAY 0001:00 `
        /RU SYSTEM `
        /RL HIGHEST `
        /TR $TaskCommand `
        /F | Out-Null

    # Retry every 3 hours
    & schtasks.exe /Create `
        /TN $RetryTask `
        /SC HOURLY `
        /MO 3 `
        /RU SYSTEM `
        /RL HIGHEST `
        /TR $TaskCommand `
        /F | Out-Null

    Write-Log 'Startup and 3-hour retry tasks are installed.'
}


function Remove-SelfHealingTasks {

    Write-Log 'Removing upgrade scheduled tasks.'

    & schtasks.exe /Delete /TN $StartupTask /F 2>$null | Out-Null
    & schtasks.exe /Delete /TN $RetryTask /F 2>$null | Out-Null
}


# ============================================================
# Install One Windows Update
# ============================================================

function Install-WindowsUpdate {

    param(
        [Parameter(Mandatory)]
        $Update,

        [Parameter(Mandatory)]
        $Session
    )

    Write-Log "Selected update: $($Update.Title)"

    if (-not $Update.EulaAccepted) {

        Write-Log 'Accepting update EULA.'
        $Update.AcceptEula()
    }

    $Collection = New-Object -ComObject Microsoft.Update.UpdateColl

    [void]$Collection.Add($Update)

    # --------------------------------------------------------
    # Download
    # --------------------------------------------------------

    Write-Log 'Starting download.'

    $Downloader = $Session.CreateUpdateDownloader()
    $Downloader.Updates = $Collection

    $DownloadResult = $Downloader.Download()

    Write-Log "Download result code: $($DownloadResult.ResultCode)"

    # 2 = Succeeded
    # 3 = Succeeded with errors

    if ($DownloadResult.ResultCode -notin 2,3) {

        throw "Update download failed with result code $($DownloadResult.ResultCode)"
    }

    # --------------------------------------------------------
    # Install
    # --------------------------------------------------------

    Write-Log 'Starting silent installation.'

    $Installer = $Session.CreateUpdateInstaller()

    $Installer.Updates = $Collection
    $Installer.ForceQuiet = $true

    $InstallResult = $Installer.Install()

    Write-Log "Install result code: $($InstallResult.ResultCode)"
    Write-Log "Reboot required: $($InstallResult.RebootRequired)"

    if ($InstallResult.ResultCode -notin 2,3) {

        throw "Update installation failed with result code $($InstallResult.ResultCode)"
    }

    return $InstallResult
}


# ============================================================
# Begin
# ============================================================

$Mutex = $null

try {

    # --------------------------------------------------------
    # Prevent simultaneous runs
    # --------------------------------------------------------

    $Mutex = New-Object System.Threading.Mutex(
        $false,
        'Global\Win11_24H2_to_25H2_Upgrade'
    )

    if (-not $Mutex.WaitOne(0, $false)) {

        Write-Log 'Another upgrade process is already running. Exiting.'
        exit 0
    }


    Write-Log '================================================='
    Write-Log 'Windows 11 25H2 upgrade process starting.'
    Write-Log '================================================='


    # --------------------------------------------------------
    # Must be Administrator / SYSTEM
    # --------------------------------------------------------

    $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()

    $Principal = New-Object `
        Security.Principal.WindowsPrincipal($Identity)

    if (-not $Principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )) {

        throw 'Script must be run as Administrator.'
    }


    # --------------------------------------------------------
    # Copy ourselves into ProgramData
    # --------------------------------------------------------

    $CurrentScript = $MyInvocation.MyCommand.Path

    if ($CurrentScript -and
        ((Resolve-Path $CurrentScript).Path -ne $ScriptPath)) {

        Write-Log "Copying script to $ScriptPath"

        Copy-Item `
            -Path $CurrentScript `
            -Destination $ScriptPath `
            -Force
    }


    # --------------------------------------------------------
    # Install persistence immediately
    # --------------------------------------------------------

    Install-SelfHealingTasks


    # --------------------------------------------------------
    # Read Windows version
    # --------------------------------------------------------

    $CV = Get-ItemProperty `
        'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'

    $Version = $CV.DisplayVersion
    $Build   = [int]$CV.CurrentBuild
    $UBR     = [int]$CV.UBR

    Write-Log "Detected Windows $Version build $Build.$UBR"


    # ========================================================
    # SUCCESS
    # ========================================================

    if ($Version -eq '25H2') {

        Write-Log 'SUCCESS: Windows 11 25H2 detected.'

        Remove-SelfHealingTasks

        Write-Log 'Upgrade lifecycle completed successfully.'

        exit 0
    }


    # ========================================================
    # Safety check
    # ========================================================

    if ($Version -ne '24H2') {

        Write-Log "Unsupported Windows release detected: $Version"
        Write-Log 'Automatic upgrade stopped.'

        # Keep tasks so transient detection issues can retry,
        # but do not attempt to modify another release.

        exit 10
    }


    if ($Build -ne 26100) {

        Write-Log "Unexpected 24H2 build number: $Build"
        exit 11
    }


    # ========================================================
    # Pending reboot
    # ========================================================

    if (Test-PendingReboot) {

        Write-Log 'A pending Windows reboot was detected.'

        Request-Reboot `
            'Windows has already installed updates that must finish during a restart.'

        exit 3010
    }


    # ========================================================
    # Create Windows Update session
    # ========================================================

    Write-Log 'Creating Microsoft Windows Update session.'

    $Session = New-Object -ComObject Microsoft.Update.Session

    $Session.ClientApplicationID = `
        'Windows 11 24H2 to 25H2 Upgrade'

    $Searcher = $Session.CreateUpdateSearcher()


    # 2 = Microsoft's public Windows Update service
    # Bypasses configured WSUS search source.
    $Searcher.ServerSelection = 2


    # ========================================================
    # PREREQUISITE CU
    # ========================================================

    if ($UBR -lt $MinimumUBR) {

        Write-Log `
            "Current build 26100.$UBR is below required 26100.$MinimumUBR."

        Write-Log `
            'Searching Microsoft Update for an applicable Windows 11 24H2 cumulative update.'

        $Result = $Searcher.Search(
            "IsInstalled=0 and Type='Software' and IsHidden=0"
        )

        Write-Log `
            "Microsoft Update returned $($Result.Updates.Count) applicable update(s)."

        $CU = $null

        for ($i = 0; $i -lt $Result.Updates.Count; $i++) {

            $Update = $Result.Updates.Item($i)

            Write-Log "Available: $($Update.Title)"

            if (
                $Update.Title -match `
                    'Cumulative Update for Windows 11 Version 24H2' `
                -and
                $Update.Title -notmatch 'Preview' `
                -and
                $Update.Title -notmatch '\.NET'
            ) {

                $CU = $Update
                break
            }
        }


        if ($null -eq $CU) {

            throw `
                'No applicable non-preview Windows 11 24H2 cumulative update was offered by Microsoft Update.'
        }


        Write-Log `
            "Installing prerequisite cumulative update: $($CU.Title)"

        $InstallResult = Install-WindowsUpdate `
            -Update $CU `
            -Session $Session


        # A cumulative update will normally require this reboot.

        if ($InstallResult.RebootRequired -or
            (Test-PendingReboot)) {

            Write-Log `
                'Prerequisite cumulative update installed successfully.'

            Request-Reboot `
                'A Windows 11 prerequisite update was installed. Windows must restart before the 25H2 upgrade can continue.'

            exit 3010
        }


        # Refresh version data in unusual case no reboot required.

        $CV = Get-ItemProperty `
            'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'

        $UBR = [int]$CV.UBR

        Write-Log "Build after prerequisite update: 26100.$UBR"

        if ($UBR -lt $MinimumUBR) {

            Write-Log `
                'Build still below prerequisite level. A restart is likely required.'

            Request-Reboot `
                'Windows installed prerequisite updates and needs to restart before continuing.'

            exit 3010
        }
    }


    # ========================================================
    # SEARCH FOR 25H2
    # ========================================================

    Write-Log `
        'Prerequisite build requirement satisfied.'

    Write-Log `
        'Searching Microsoft Windows Update for Windows 11, version 25H2.'

    $Result = $Searcher.Search(
        "IsInstalled=0 and Type='Software' and IsHidden=0"
    )

    Write-Log `
        "Microsoft Update returned $($Result.Updates.Count) applicable update(s)."

    $FeatureUpdate = $null

    for ($i = 0; $i -lt $Result.Updates.Count; $i++) {

        $Update = $Result.Updates.Item($i)

        Write-Log "Available: $($Update.Title)"

        if ($Update.Title -match '^Windows 11, version 25H2') {

            $FeatureUpdate = $Update
            break
        }
    }


    # ========================================================
    # 25H2 not currently offered
    # ========================================================

    if ($null -eq $FeatureUpdate) {

        Write-Log `
            'Windows 11, version 25H2 is not currently being offered by Microsoft Update.'

        Write-Log `
            'No changes made. The automatic retry task will try again in 3 hours.'

        exit 30
    }


    # ========================================================
    # INSTALL 25H2
    # ========================================================

    Write-Log `
        "Installing feature update: $($FeatureUpdate.Title)"

    $InstallResult = Install-WindowsUpdate `
        -Update $FeatureUpdate `
        -Session $Session


    if ($InstallResult.RebootRequired -or
        (Test-PendingReboot)) {

        Write-Log `
            'Windows 11 25H2 installation completed and requires restart.'

        Request-Reboot `
            'Windows 11 25H2 has been installed. Restart Windows to complete the upgrade.'

        exit 3010
    }


    Write-Log `
        '25H2 installation completed without Windows reporting an immediate reboot requirement.'

    Write-Log `
        'The script will verify the installed version during the next scheduled run.'

}
catch {

    Write-Log "ERROR: $($_.Exception.Message)"

    Write-Log `
        'The upgrade tasks have been left in place and will retry automatically.'

    exit 99
}
finally {

    if ($Mutex) {

        try {
            $Mutex.ReleaseMutex()
        }
        catch {}

        $Mutex.Dispose()
    }
}
