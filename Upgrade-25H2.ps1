#requires -Version 5.1
# Direct x64 24H2 -> 25H2 deployment. See README before using -AllowOfferBypass.
[CmdletBinding()]
param([switch]$Install,[switch]$AllowOfferBypass,[switch]$CheckOnly)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    $native=Join-Path $env:SystemRoot 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
    $arguments=@('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$PSCommandPath)
    if($Install){$arguments+='-Install'}; if($AllowOfferBypass){$arguments+='-AllowOfferBypass'}; if($CheckOnly){$arguments+='-CheckOnly'}
    & $native @arguments; exit $LASTEXITCODE
}
$Root='C:\ProgramData\Win11-25H2'
$Worker=Join-Path $Root 'Upgrade-25H2.ps1'
$LogPath=Join-Path $Root 'Upgrade-25H2.log'
$StatePath=Join-Path $Root 'direct-state.json'
$TaskNames=@('Win11-25H2-AtStartup','Win11-25H2-Retry','Win11-25H2-Startup')
$MutexNames=@('Global\Win11-25H2-Upgrade','Global\Win11_24H2_to_25H2_Upgrade')
$PackageUri='https://catalog.sf.dl.delivery.mp.microsoft.com/filestreamingservice/files/67731ce0-1988-426a-afa3-044a032eb6c6/public/windows11.0-kb5054156-x64_9fd13360d2c5af23ec4f591b86f1c1db37aada37.msu'
$PackageHash='59A2B315141DA42066183C11F6233D974DE050B41CBB760AAFB8C89B0C88C616'
$PackageIdentity='Package_for_KB5054156~31bf3856ad364e35~amd64~~26100.6717.1.4'
$State=@{Schema=1;Phase='Starting';Detail='';UpdatedUtc='';PendingBoot='';RestartBoot='';Reason='';InstallBoot='';Stages=0;Reboots=0;ManualAttention=$false}

function Get-Snapshot {
    $cv=Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $os=Get-CimInstance Win32_OperatingSystem
    [pscustomobject]@{Type=[string]$cv.InstallationType;Release=[string]$cv.DisplayVersion;Build=[int]$cv.CurrentBuildNumber;UBR=[int]$cv.UBR;Running=[int]$os.BuildNumber;Boot=$os.LastBootUpTime.ToUniversalTime().ToString('o');Arch=$env:PROCESSOR_ARCHITECTURE;Edition=[string]$cv.EditionID}
}
function Get-Disposition($os) {
    if($os.Type -ne 'Client' -or $os.Arch -ne 'AMD64' -or $os.Edition -match '^(EnterpriseS|IoTEnterpriseS)'){return 'Unsupported'}
    if($os.Release -eq '25H2' -and $os.Build -eq 26200 -and $os.Running -eq 26200){return 'Complete'}
    if($os.Release -eq '25H2' -and $os.Build -eq 26200 -and $os.Running -eq 26100){return 'Staged'}
    if($os.Release -eq '24H2' -and $os.Build -eq 26100 -and $os.Running -eq 26100){return 'Eligible'}
    return 'Unsupported'
}
function Assert-Path($path) {
    if(Test-Path -LiteralPath $path){if((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw "Refusing redirected path: $path"}}
}
function Protect-Path($path) {
    Assert-Path $path
    $acl=Get-Acl -LiteralPath $path
    $acl.SetSecurityDescriptorSddlForm('O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)')
    Set-Acl -LiteralPath $path -AclObject $acl
}
function Write-Log([string]$message) {
    $line=('{0} [Direct25H2] {1}' -f [datetime]::UtcNow.ToString('o'),$message)
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    Write-Host $line
}
function Save-State([string]$phase,[string]$detail) {
    $script:State.Phase=$phase; $script:State.Detail=$detail; $script:State.UpdatedUtc=[datetime]::UtcNow.ToString('o')
    $temp=Join-Path $Root ('state-'+[guid]::NewGuid().ToString('N')+'.tmp')
    [IO.File]::WriteAllText($temp,($script:State | ConvertTo-Json),(New-Object Text.UTF8Encoding($false)))
    if(Test-Path -LiteralPath $StatePath){[IO.File]::Replace($temp,$StatePath,$null)}else{[IO.File]::Move($temp,$StatePath)}
}
function Get-OwnedTasks {
    @(Get-ScheduledTask -ErrorAction Stop | Where-Object {$_.TaskPath -eq '\' -and $_.TaskName -in $TaskNames})
}
function Assert-OwnedTaskActions($tasks) {
    foreach($task in $tasks){
        if(@($task.Actions).Count -eq 0){throw "Task name collision with no recognizable action: $($task.TaskName). Nothing will be deleted."}
        foreach($action in $task.Actions){
            if(($action.Execute+' '+$action.Arguments) -notmatch '(?i)C:\\ProgramData\\Win11-25H2\\(Upgrade-25H2\.ps1|Upgrade-24H2-to-25H2\.ps1|Win11-25H2-Launcher\.bat)(?=["\s]|$)'){
                throw "Task name collision with an unrecognized action: $($task.TaskName). Nothing will be deleted."
            }
        }
    }
}
function Test-RebootPending {
    $info=New-Object -ComObject Microsoft.Update.SystemInfo
    return ($info.RebootRequired -or (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'))
}
function Invoke-Notice($message) {
    try{$ErrorActionPreference='Continue'; & "$env:SystemRoot\System32\msg.exe" '*' /TIME:3600 $message 2>&1 | Out-Null; Write-Log "User message attempted; exit=$LASTEXITCODE"}catch{Write-Log 'User message unavailable; native restart notification still applies.'}
}
function Invoke-Countdown($message) {
    $ErrorActionPreference='Continue'
    $output=& "$env:SystemRoot\System32\shutdown.exe" /r /t 3600 /d p:2:3 /c $message 2>&1
    [pscustomobject]@{Code=$LASTEXITCODE;Text=($output | Out-String)}
}
function Request-Reboot($reason,$boot) {
    $script:State.PendingBoot=$boot; $script:State.Reason=$reason
    if($script:State.RestartBoot -eq $boot){Save-State 'AwaitingRestart' $reason; Write-Log 'Restart already requested this boot; not extending or re-arming it. If cancelled, restart manually.'; return}
    if($script:State.Reboots -ge 3){throw 'Three automatic restart cycles reached. Review servicing logs; further restarts require administrator action.'}
    Save-State 'RebootNeeded' $reason
    $message="Windows 11 maintenance: this computer will restart in 60 minutes. Save your work; applications will close. $reason"
    $result=Invoke-Countdown $message
    if($result.Code -notin 0,1190){throw "Restart scheduling failed ($($result.Code)): $($result.Text)"}
    $script:State.RestartBoot=$boot; $script:State.Reboots=[int]$script:State.Reboots+1; Save-State 'AwaitingRestart' $reason
    if($result.Code -eq 0){Invoke-Notice $message; Write-Log 'Restart scheduled in 60 minutes.'}else{Write-Log 'Another restart is already scheduled; its deadline was not changed.'}
}
function Get-LauncherText {
    @'
@echo off
setlocal
set "ROOT=C:\ProgramData\Win11-25H2"
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
echo [%date% %time%] Direct25H2 launcher started.>>"%ROOT%\Launcher.log"
"%PS%" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%ROOT%\Upgrade-25H2.ps1" -AllowOfferBypass >>"%ROOT%\Launcher.log" 2>&1
set "RC=%ERRORLEVEL%"
echo [%date% %time%] Direct25H2 launcher finished with exit code %RC%.>>"%ROOT%\Launcher.log"
exit /b %RC%
'@
}
function Install-Tasks([string]$sourceFile) {
    $tasks=@(Get-OwnedTasks); Assert-OwnedTaskActions $tasks
    if(@($tasks | Where-Object {$_.State -eq 'Running'}).Count){throw 'An old task is running. Wait for it to finish; do not kill servicing.'}
    $history=Join-Path $Root ('history-'+[guid]::NewGuid().ToString('N')); $null=New-Item -ItemType Directory -Path $history
    foreach($name in @('Upgrade-25H2.ps1','Win11-25H2-Launcher.bat')){
        $path=Join-Path $Root $name; Assert-Path $path
        if(Test-Path -LiteralPath $path){Copy-Item -LiteralPath $path -Destination (Join-Path $history $name)}
    }
    if([IO.Path]::GetFullPath($sourceFile) -ne $Worker){Copy-Item -LiteralPath $sourceFile -Destination $Worker -Force}
    $bat=Join-Path $Root 'Win11-25H2-Launcher.bat'
    Write-LauncherFile $bat
    Protect-Path $Worker; Protect-Path $bat
    $action=New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\cmd.exe" -Argument '/d /c C:\ProgramData\Win11-25H2\Win11-25H2-Launcher.bat'
    $principal=New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings=New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([timespan]::Zero)
    $retry=New-ScheduledTaskTrigger -Once -At ((Get-Date).AddHours(3)) -RepetitionInterval (New-TimeSpan -Hours 3)
    $null=Register-ScheduledTask -TaskPath '\' -TaskName $TaskNames[0] -Action $action -Principal $principal -Settings $settings -Trigger (New-ScheduledTaskTrigger -AtStartup) -Force
    $null=Register-ScheduledTask -TaskPath '\' -TaskName $TaskNames[1] -Action $action -Principal $principal -Settings $settings -Trigger $retry -Force
    foreach($old in @($tasks | Where-Object {$_.TaskName -eq 'Win11-25H2-Startup'})){
        Unregister-ScheduledTask -InputObject $old -Confirm:$false
        Write-Log 'Removed superseded Win11-25H2-Startup task; its script and logs were retained.'
    }
    Write-Log 'Direct mode installed: SYSTEM BAT tasks at startup and every 3 hours. Offer and safeguard gating bypass authorized; signatures and applicability remain enforced.'
}
function Write-LauncherFile($path) {
    [IO.File]::WriteAllText($path,((Get-LauncherText) -replace '\r?\n',"`r`n"),[Text.Encoding]::ASCII)
}
function Test-Candidate($update) {
    return (-not $update.BrowseOnly -and -not $update.InstallationBehavior.CanRequestUserInput -and $update.Title -match '(?i)Cumulative Update.*Windows 11.*24H2' -and $update.Title -notmatch '(?i)Preview|Insider|Dynamic|Safe OS|\.NET')
}
function Invoke-Wua($owner,[string]$kind,[string]$criteria='') {
    if(-not ('Direct25H2.Callback' -as [type])){Add-Type 'using System.Runtime.InteropServices; namespace Direct25H2 { [ComVisible(true),ClassInterface(ClassInterfaceType.AutoDispatch)] public class Callback { [DispId(0)] public void Invoke(object job,object args){} } }'}
    $callback=New-Object Direct25H2.Callback
    Save-State $kind 'Prerequisite update operation'; Write-Log "Prerequisite $kind started."
    switch($kind){Search{$job=$owner.BeginSearch($criteria,$callback,$null)} Download{$job=$owner.BeginDownload($callback,$callback,$null)} Install{$job=$owner.BeginInstall($callback,$callback,$null)}}
    $watch=[Diagnostics.Stopwatch]::StartNew(); $last=-60; $aborted=$false
    while(-not $job.IsCompleted){
        if($watch.Elapsed.TotalSeconds-$last -ge 60){$progress=''; if($kind -ne 'Search'){$progress=" $($job.GetProgress().PercentComplete)%"}; Write-Log "$kind still active.$progress"; $last=$watch.Elapsed.TotalSeconds}
        if(-not $aborted -and $watch.Elapsed.TotalMinutes -ge 180){$job.RequestAbort(); $aborted=$true; Write-Log 'Requested soft cancellation after 3 hours; waiting, never killing servicing.'}
        Start-Sleep -Seconds 5
    }
    switch($kind){Search{$result=$owner.EndSearch($job)} Download{$result=$owner.EndDownload($job)} Install{$result=$owner.EndInstall($job)}}
    $watch.Stop(); return $result
}
function Install-Prerequisite($boot) {
    $session=New-Object -ComObject Microsoft.Update.Session; $session.ClientApplicationID='Direct25H2'; $session.UserLocale=1033
    $searcher=$session.CreateUpdateSearcher(); $searcher.ServerSelection=2; $searcher.Online=$true
    $result=Invoke-Wua $searcher Search "IsInstalled=0 and IsHidden=0 and Type='Software'"
    if($result.ResultCode -ne 2){throw "Incomplete prerequisite scan: $($result.ResultCode)"}
    $updates=@(for($i=0;$i -lt $result.Updates.Count;$i++){$u=$result.Updates.Item($i); if(Test-Candidate $u){$u}})
    if(-not $updates.Count){throw 'No applicable non-preview 24H2 cumulative update offered. Minimum 26100.5074 is not bypassed.'}
    $chosen=$updates | Sort-Object LastDeploymentChangeTime -Descending | Select-Object -First 1
    Write-Log "Prerequisite selected: $($chosen.Title)"
    if(-not $chosen.EulaAccepted){$chosen.AcceptEula()}
    $collection=New-Object -ComObject Microsoft.Update.UpdateColl; $null=$collection.Add($chosen)
    $downloader=$session.CreateUpdateDownloader(); $downloader.Updates=$collection
    $download=Invoke-Wua $downloader Download; $item=$download.GetUpdateResult(0)
    if($download.ResultCode -ne 2 -or $item.ResultCode -ne 2 -or -not $chosen.IsDownloaded){throw "Prerequisite download failed. HRESULT=$($item.HResult)"}
    $installer=$session.CreateUpdateInstaller(); $installer.Updates=$collection; $installer.ForceQuiet=$true; $installer.AllowSourcePrompts=$false
    if($installer.IsBusy -or $installer.RebootRequiredBeforeInstallation){throw 'Servicing is busy or now requires a restart. Retry later.'}
    $installed=Invoke-Wua $installer Install; $item=$installed.GetUpdateResult(0)
    if($installed.ResultCode -ne 2 -or $item.ResultCode -ne 2){
        if($installed.RebootRequired -or $item.RebootRequired){$script:State.ManualAttention=$true}
        throw "Prerequisite installation incomplete. HRESULT=$($item.HResult); no restart requested for a partial result."
    }
    if($installed.RebootRequired -or $item.RebootRequired -or (Test-RebootPending)){Request-Reboot '24H2 prerequisite installed; upgrade resumes after restart.' $boot}
    else{Save-State 'PrerequisiteInstalled' 'Recheck build on next retry.'}
}
function Assert-Package($path) {
    Assert-Path $path
    if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $PackageHash){throw 'KB5054156 SHA256 mismatch; refusing installation.'}
    $signature=Get-AuthenticodeSignature -LiteralPath $path
    if($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(^|,\s*)O=Microsoft Corporation(,|$)'){throw 'KB5054156 signature is not valid and Microsoft-signed; refusing installation.'}
}
function Get-EnablementPackage {
    $cache=Join-Path $Root 'Payload'; Assert-Path $cache; $null=New-Item -ItemType Directory -Path $cache -Force; Protect-Path $cache
    $path=Join-Path $cache 'Windows11.0-KB5054156-x64.msu'; Assert-Path $path
    if(Test-Path -LiteralPath $path){
        try{Assert-Package $path; Write-Log 'Using verified cached KB5054156.'; return $path}
        catch{Move-Item -LiteralPath $path -Destination ($path+'.rejected-'+[guid]::NewGuid().ToString('N')); Write-Log 'Cached payload rejected and retained for audit; downloading again.'}
    }
    $temp=Join-Path $cache ([guid]::NewGuid().ToString('N')+'.partial.msu')
    [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
    Write-Log 'Downloading released KB5054156 directly from Microsoft (175575 bytes); no feature-update offer required.'
    Invoke-WebRequest -UseBasicParsing -Uri $PackageUri -OutFile $temp -TimeoutSec 120
    Assert-Package $temp
    Move-Item -LiteralPath $temp -Destination $path
    Protect-Path $path; Write-Log 'KB5054156 hash and Microsoft signature verified.'; return $path
}
function Invoke-Dism($path) {
    $dismLog=Join-Path $Root ('DISM-'+[guid]::NewGuid().ToString('N')+'.log')
    $arguments='/Online /Add-Package /PackagePath:"{0}" /Quiet /NoRestart /English /LogPath:"{1}"' -f $path,$dismLog
    Write-Log "DISM installing enablement package; log=$dismLog"
    $process=Start-Process -FilePath "$env:SystemRoot\System32\dism.exe" -ArgumentList $arguments -PassThru -WindowStyle Hidden
    while(-not $process.WaitForExit(60000)){Write-Log "DISM PID=$($process.Id) still running; do not interrupt servicing."}
    $process.WaitForExit(); $code=$process.ExitCode; $process.Dispose()
    Write-Log "DISM exit=$code"; return $code
}
function Get-EnablementState {
    @(Get-WindowsPackage -Online -ErrorAction Stop | Where-Object {$_.PackageName -eq $PackageIdentity -and [string]$_.PackageState -in 'Installed','InstallPending'})
}
function Invoke-Worker($snapshot,$disposition) {
    if($disposition -eq 'Complete' -and $State.InstallBoot -ne $snapshot.Boot -and -not (Test-RebootPending)){
        Save-State 'Complete' 'Windows 11 25H2 verified after reboot.'; Remove-CompletedTasks; Write-Log 'COMPLETE: 25H2 verified; scripts, state, package and logs retained.'
    }
    else {
        if($State.ManualAttention){throw 'Previous partial installation needs administrator review. See logs; no automatic install/restart attempted.'}
        if($State.PendingBoot -eq $snapshot.Boot){Request-Reboot $State.Reason $snapshot.Boot}
        else {
            $State.PendingBoot=''; $State.RestartBoot=''
            $busy=New-Object -ComObject Microsoft.Update.Installer
            if($busy.IsBusy){throw 'Windows Update installation is active; waiting for next retry.'}
            if(@(Get-Process -Name dism,wusa,SetupHost -ErrorAction SilentlyContinue).Count){throw 'Another native servicing process is active; wait for it to finish. No process will be killed.'}
            if($State.InstallBoot -eq $snapshot.Boot -and $disposition -eq 'Eligible' -and -not (Test-RebootPending)){
                if(-not @(Get-EnablementState).Count){$State.InstallBoot=''; Write-Log 'Interrupted attempt has no installed/pending enablement package; retrying without inferring a successful install.'}
            }
            if(Test-RebootPending){Request-Reboot 'Windows has pending update servicing; direct upgrade continues after restart.' $snapshot.Boot}
            elseif($disposition -in 'Staged','Complete' -or $State.InstallBoot -eq $snapshot.Boot){Request-Reboot '25H2 servicing needs post-reboot verification.' $snapshot.Boot}
            elseif($snapshot.UBR -lt 5074){Install-Prerequisite $snapshot.Boot}
            else {
                if($State.Stages -ge 2){throw 'Two successful staging cycles did not reach 25H2. Investigate rollback; automatic reboot loop stopped.'}
                if((Get-PSDrive C).Free -lt 5GB){throw 'At least 5 GB free on C: is required by this deployment.'}
                $path=Get-EnablementPackage
                $State.InstallBoot=$snapshot.Boot; Save-State 'InstallingEnablement' 'Offer/safeguard gating bypass; native package applicability retained.'
                $code=Invoke-Dism $path
                if($code -notin 0,3010){$State.InstallBoot=''; if(Test-RebootPending){$State.ManualAttention=$true}; throw "DISM failed ($code); see DISM log. No success/restart inferred. Native applicability checks were not bypassed."}
                $package=@(Get-EnablementState)
                if(-not $package.Count){$State.ManualAttention=$true; throw 'DISM returned success but the expected package is not Installed/InstallPending. Review required; no success/restart inferred.'}
                $State.Stages=[int]$State.Stages+1
                Request-Reboot 'Windows 11 25H2 enablement installed; restart completes the upgrade.' $snapshot.Boot
            }
        }
    }
}
function Remove-CompletedTasks {
    $tasks=@(Get-OwnedTasks); Assert-OwnedTaskActions $tasks
    foreach($task in $tasks){Unregister-ScheduledTask -InputObject $task -Confirm:$false; Write-Log "Removed completed task $($task.TaskName)."}
}

$snapshot=Get-Snapshot; $disposition=Get-Disposition $snapshot
if($CheckOnly){$snapshot | Format-List | Out-Host; Write-Host "Disposition=$disposition; minimum=26100.5074; mode=direct enablement"; Get-OwnedTasks | Select-Object TaskName,State | Format-Table | Out-Host; exit 0}
if($disposition -eq 'Unsupported'){throw 'Only x64 Windows 11 24H2 clients (not LTSC) or completed 25H2 targets are supported. No bypass of release/architecture restrictions.'}
if(-not $AllowOfferBypass){throw 'Direct installation bypasses Windows Update offer/safeguard gating. Explicit -AllowOfferBypass is required. See README.'}
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
$principal=New-Object Security.Principal.WindowsPrincipal($identity)
if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Run installation elevated or via Sophos SYSTEM.'}
if(-not $Install -and $identity.User.Value -ne 'S-1-5-18'){throw 'Use -Install to register SYSTEM tasks; do not launch the worker interactively.'}
$locks=@(); $startFirst=$false; $exitCode=0; $initialized=$false
try {
    foreach($name in $MutexNames){
        $mutex=New-Object Threading.Mutex($false,$name); $owned=$false
        try{$owned=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$owned=$true}
        if(-not $owned){$mutex.Dispose(); throw 'Another old/new upgrade worker is active. No worker was stopped; wait and retry.'}
        $locks+=,$mutex
    }
    Assert-Path $Root; $null=New-Item -ItemType Directory -Path $Root -Force; Protect-Path $Root
    foreach($name in @('Upgrade-25H2.log','Launcher.log','direct-state.json')){$path=Join-Path $Root $name; Assert-Path $path; if(Test-Path -LiteralPath $path){Protect-Path $path}}
    if(Test-Path -LiteralPath $StatePath){
        $loaded=Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
        if($loaded.Schema -ne 1){throw 'Unrecognized direct-state schema; review state before continuing.'}
        foreach($property in $loaded.PSObject.Properties){$State[$property.Name]=$property.Value}
    }
    $initialized=$true
    Write-Log "Mode=direct; $($snapshot.Release) $($snapshot.Build).$($snapshot.UBR); running=$($snapshot.Running); bypass authorized."
    if($Install){Install-Tasks $PSCommandPath; $startFirst=$true}
    else { Invoke-Worker $snapshot $disposition }
}catch{
    $exitCode=1; $detail=$_.Exception.Message
    if($initialized){try{Write-Log "ERROR: $detail"; Save-State 'FailedWillRetry' $detail}catch{Write-Error $detail -ErrorAction Continue}}else{Write-Error $detail -ErrorAction Continue}
}finally{
    foreach($mutex in $locks){try{$mutex.ReleaseMutex()}finally{$mutex.Dispose()}}
}
if($startFirst -and $exitCode -eq 0){Start-ScheduledTask -TaskPath '\' -TaskName 'Win11-25H2-Retry' -ErrorAction Stop; Write-Host 'Direct25H2 SYSTEM tasks registered; first run requested. Read Upgrade-25H2.log and direct-state.json.'}
exit $exitCode
