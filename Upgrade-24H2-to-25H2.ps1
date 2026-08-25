$ErrorActionPreference = 'Stop'

$LogDir  = 'C:\ProgramData\Win11-25H2'
$LogFile = Join-Path $LogDir 'Upgrade-Test.log'

New-Item -ItemType Directory -Path $LogDir -Force | Out-Null

function Write-Log {
    param([string]$Message)

    $Line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Message"
    Add-Content -Path $LogFile -Value $Line
    Write-Host $Line
}

function Show-RebootPrompt {
    Add-Type -AssemblyName PresentationFramework

    $Result = [System.Windows.MessageBox]::Show(
        "Windows 11 25H2 has been installed and requires a restart.`n`nWould you like to restart this computer now?",
        "Windows 11 25H2 Upgrade",
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Information
    )

    if ($Result -eq [System.Windows.MessageBoxResult]::Yes) {
        Write-Log 'User chose to restart now.'
        shutdown.exe /r /t 0
    }
    else {
        Write-Log 'User chose to restart later.'
    }
}

try {

    # Must be administrator
    $Identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $Principal = New-Object Security.Principal.WindowsPrincipal($Identity)

    if (-not $Principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )) {
        throw 'This script must be run as Administrator.'
    }

    $CV = Get-ItemProperty `
        'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'

    Write-Log "Detected Windows version $($CV.DisplayVersion), build $($CV.CurrentBuild).$($CV.UBR)"

    if ($CV.DisplayVersion -eq '25H2') {
        Write-Log 'Windows 11 25H2 is already installed.'
        Write-Host ''
        Write-Host '25H2 is already installed.' -ForegroundColor Green
        exit 0
    }

    if ($CV.DisplayVersion -ne '24H2') {
        throw "This test only supports Windows 11 24H2. Detected $($CV.DisplayVersion)."
    }

    if ([int]$CV.CurrentBuild -ne 26100) {
        throw "Unexpected Windows build $($CV.CurrentBuild). Expected Windows 11 24H2 build 26100."
    }

    if ([int]$CV.UBR -lt 5074) {
        throw "The machine is below the minimum 25H2 prerequisite build. Current build is 26100.$($CV.UBR); 26100.5074 or newer is required."
    }

    Write-Log 'Creating Windows Update session.'

    $Session = New-Object -ComObject Microsoft.Update.Session
    $Session.ClientApplicationID = 'Manual Win11 25H2 Upgrade Test'

    $Searcher = $Session.CreateUpdateSearcher()

    # 2 = Microsoft's public Windows Update service
    $Searcher.ServerSelection = 2

    Write-Log 'Searching Microsoft Windows Update directly for applicable software updates.'

    $SearchResult = $Searcher.Search(
        "IsInstalled=0 and Type='Software' and IsHidden=0"
    )

    Write-Log "Windows Update returned $($SearchResult.Updates.Count) applicable software update(s)."

    $Target = $null

    for ($i = 0; $i -lt $SearchResult.Updates.Count; $i++) {

        $Update = $SearchResult.Updates.Item($i)

        Write-Log "Found: $($Update.Title)"

        if ($Update.Title -match '^Windows 11, version 25H2') {
            $Target = $Update
            break
        }
    }

    if ($null -eq $Target) {
        throw 'Windows 11, version 25H2 was not offered by Microsoft Windows Update.'
    }

    Write-Log "Selected update: $($Target.Title)"

    if (-not $Target.EulaAccepted) {
        Write-Log 'Accepting update license agreement.'
        $Target.AcceptEula()
    }

    $Updates = New-Object -ComObject Microsoft.Update.UpdateColl
    [void]$Updates.Add($Target)

    Write-Log 'Starting silent 25H2 download.'

    $Downloader = $Session.CreateUpdateDownloader()
    $Downloader.Updates = $Updates

    $DownloadResult = $Downloader.Download()

    Write-Log "Download result code: $($DownloadResult.ResultCode)"

    # WUA result code 2 = succeeded
    if ($DownloadResult.ResultCode -ne 2) {
        throw "25H2 download failed. Windows Update result code: $($DownloadResult.ResultCode)"
    }

    Write-Log 'Download completed successfully.'
    Write-Log 'Starting silent 25H2 installation.'

    $Installer = $Session.CreateUpdateInstaller()
    $Installer.Updates = $Updates
    $Installer.ForceQuiet = $true

    $InstallResult = $Installer.Install()

    Write-Log "Install result code: $($InstallResult.ResultCode)"
    Write-Log "Reboot required: $($InstallResult.RebootRequired)"

    # 2 = succeeded, 3 = succeeded with errors
    if ($InstallResult.ResultCode -notin 2,3) {
        throw "25H2 installation failed. Windows Update result code: $($InstallResult.ResultCode)"
    }

    Write-Host ''
    Write-Host 'Windows 11 25H2 installation completed.' -ForegroundColor Green

    if ($InstallResult.RebootRequired) {
        Write-Log '25H2 installation completed and Windows reports a restart is required.'
        Show-RebootPrompt
    }
    else {
        Write-Log 'Installation completed and Windows did not report a required restart.'
    }

}
catch {

    Write-Log "ERROR: $($_.Exception.Message)"

    Write-Host ''
    Write-Host 'Upgrade failed.' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host ''
    Write-Host "Log: $LogFile"

    Read-Host 'Press Enter to close'
    exit 1
}
