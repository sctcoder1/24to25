#requires -Version 5.1
[CmdletBinding()]
param([switch]$Install,[switch]$CheckOnly)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if(-not [Environment]::Is64BitProcess -and [Environment]::Is64BitOperatingSystem){
    $a=@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$PSCommandPath)
    if($Install){$a+='-Install'}; if($CheckOnly){$a+='-CheckOnly'}
    & "$env:SystemRoot\Sysnative\WindowsPowerShell\v1.0\powershell.exe" @a; exit $LASTEXITCODE
}
$Root=Join-Path $env:ProgramData 'Unified25H2'
$Worker=Join-Path $Root 'Upgrade-Unified25H2.ps1'
$StatePath=Join-Path $Root 'state.json'
$Tasks=@('Unified25H2-Startup','Unified25H2-Retry')
$Iso=Join-Path $Root 'Win11-25H2.iso'
$IsoHash='768984706B909479417B2368438909440F2967FF05C6A9195ED2667254E465E3'
$FidoUrl='https://raw.githubusercontent.com/pbatard/Fido/3d47260b8915385c58e20c73e24b36e9a9536f3f/Fido.ps1'
$FidoHash='24C86067FA399D2FD75EF0693A2EC79CA8DB162827F808CAAC03541CBF640C13'
$Fallback='https://mscourts.sharepoint.com/:u:/s/ITDeployment/IQDiLcM8rZuBR61thr1zSOUOAY588lXS9JaviggFRN22WJg?e=TFvCQk&download=1'
$MsuUrl='https://catalog.sf.dl.delivery.mp.microsoft.com/filestreamingservice/files/67731ce0-1988-426a-afa3-044a032eb6c6/public/windows11.0-kb5054156-x64_9fd13360d2c5af23ec4f591b86f1c1db37aada37.msu'
$MsuHash='59A2B315141DA42066183C11F6233D974DE050B41CBB760AAFB8C89B0C88C616'
$Package='Package_for_KB5054156~31bf3856ad364e35~amd64~~26100.6717.1.4'
function Assert-Path([string]$Path){
    $p=[IO.Path]::GetFullPath($Path)
    while($p){
        if(Test-Path -LiteralPath $p){if((Get-Item -LiteralPath $p -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw "Redirected path: $p"}}
        $p=[IO.Path]::GetDirectoryName($p)
    }
}
function Ensure-Root {
    Assert-Path $Root
    New-Item -ItemType Directory -Path $Root -Force|Out-Null
    $acl=Get-Acl -LiteralPath $Root
    $acl.SetSecurityDescriptorSddlForm('O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)')
    Set-Acl -LiteralPath $Root -AclObject $acl
    foreach($f in Get-ChildItem -LiteralPath $Root -Force){Assert-Path $f.FullName}
}
function Log([string]$Text){
    $line=([datetime]::UtcNow.ToString('o')+' '+$Text)
    Add-Content -LiteralPath (Join-Path $Root 'worker.log') -Value $line -Encoding UTF8
    Write-Host $line
}
function Start-StayAwake {
    # Keep the computer in the working state while the local SYSTEM worker is
    # downloading or running Setup. A dedicated helper process owns the power
    # request so it remains active while this runspace waits for child programs.
    # The display is intentionally allowed to turn off.
    $helperTemplate = @'
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class Win10UpgradePowerRequest {
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern uint SetThreadExecutionState(uint esFlags);
}
"@
try {
    $result = [Win10UpgradePowerRequest]::SetThreadExecutionState([uint32]2147483649)
    if ($result -eq 0) { throw 'SetThreadExecutionState failed.' }
    Wait-Process -Id __PARENT_PROCESS_ID__ -ErrorAction SilentlyContinue
} finally {
    [void][Win10UpgradePowerRequest]::SetThreadExecutionState([uint32]2147483648)
}
'@
    $helperCode = $helperTemplate.Replace('__PARENT_PROCESS_ID__',[string]$PID)
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($helperCode))
    $powerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $process = Start-Process -FilePath $powerShell -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded) -WindowStyle Hidden -PassThru
    Start-Sleep -Seconds 1
    if ($process.HasExited) { throw "Native stay-awake helper exited unexpectedly with code $($process.ExitCode)." }
    Log "Native stay-awake request enabled (helper PID $($process.Id)); the display may turn off."
    return $process
}

function Stop-StayAwake([Diagnostics.Process]$Process) {
    if (-not $Process) { return }
    try {
        if (-not $Process.HasExited) {
            Stop-Process -Id $Process.Id -Force -ErrorAction Stop
            $Process.WaitForExit(5000) | Out-Null
        }
        Log 'Native stay-awake request released.'
    } catch {
        Log "Stay-awake helper cleanup warning: $($_.Exception.Message)"
    } finally {
        $Process.Dispose()
    }
}
function Snapshot {
    $cv=Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $os=Get-CimInstance Win32_OperatingSystem
    [pscustomobject]@{Build=[int]$cv.CurrentBuildNumber; Running=[int]$os.BuildNumber; UBR=[int]$cv.UBR; Release=[string]$cv.DisplayVersion; Edition=[string]$cv.EditionID; Type=[string]$cv.InstallationType; Boot=$os.LastBootUpTime.ToUniversalTime().ToString('o'); Architecture=$env:PROCESSOR_ARCHITECTURE}
}
function Route($o){
    if($o.Type -ne 'Client' -or $o.Architecture -ne 'AMD64'){return 'Unsupported'}
    if($o.Build -ne $o.Running){return 'Inconsistent'}
    if($o.Build -eq 26200 -and $o.Release -eq '25H2'){return 'Complete'}
    if(($o.Build -eq 19045 -and $o.Release -eq '22H2') -or ($o.Build -eq 22631 -and $o.Release -eq '23H2')){return 'ISO'}
    if($o.Build -eq 26100 -and $o.Release -eq '24H2'){return 'MSU'}
    return 'Unsupported'
}
function Save([string]$Phase,[string]$Detail){
    $script:State.Phase=$Phase; $script:State.Detail=$Detail; $script:State.UpdatedUtc=[datetime]::UtcNow.ToString('o')
    $temp=Join-Path $Root 'state.tmp'; Assert-Path $temp; Assert-Path $StatePath
    [IO.File]::WriteAllText($temp,($script:State|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temp -Destination $StatePath -Force
    Log "$Phase : $Detail"
}
function Pending {
    if(Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'){return $true}
    if(Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'){return $true}
    return [bool](New-Object -ComObject Microsoft.Update.SystemInfo).RebootRequired
}
function Busy {
    if((New-Object -ComObject Microsoft.Update.Installer).IsBusy){return $true}
    if(@(Get-Process -Name setup,SetupHost,SetupPrep,dism,wusa,TiWorker -ErrorAction SilentlyContinue).Count){return $true}
    $s=Get-ItemProperty 'HKLM:\SYSTEM\Setup'
    foreach($name in @('SystemSetupInProgress','OOBEInProgress')){if($s.PSObject.Properties[$name] -and [int]$s.$name -ne 0){return $true}}
    # Cooperate with all older workers, even during their downloads.
    $others=@(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'"|Where-Object {$_.ProcessId -ne $PID -and $_.CommandLine -match '(?i)(Upgrade-(Win10|23H2|25H2)|Update-Windows25H2|Win10UpgradePowerRequest)'})
    return ($others.Count -gt 0)
}
function Assert-Task($Name){
    $t=Get-ScheduledTask -TaskName $Name -TaskPath '\' -ErrorAction SilentlyContinue
    if($t){
        if(@($t.Actions).Count -ne 1 -or $t.Actions[0].Arguments -ne ('-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$Worker+'"') -or $t.Actions[0].Execute -ne "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"){throw "Task collision: $Name"}
    }
}
function Disable-OwnedTasks {foreach($n in $Tasks){Assert-Task $n; if(Get-ScheduledTask -TaskName $n -TaskPath '\' -ErrorAction SilentlyContinue){Disable-ScheduledTask -TaskName $n -TaskPath '\'|Out-Null}}}
function Download([string]$Url,[string]$Path,[string]$Hash){
    Assert-Path $Path
    if((Test-Path -LiteralPath $Path) -and (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -eq $Hash){return}
    Import-Module BitsTransfer
    $jobName='Unified25H2-'+[IO.Path]::GetFileName($Path)
    # Clean up only this deployment's interrupted download jobs, never servicing.
    Get-BitsTransfer -ErrorAction SilentlyContinue|Where-Object {$_.DisplayName -eq $jobName}|Remove-BitsTransfer
    $part=$Path+'.partial'; Assert-Path $part
    Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
    Start-BitsTransfer -Source $Url -Destination $part -DisplayName $jobName -Priority Foreground -RetryInterval 60 -RetryTimeout 3600
    if((Get-FileHash -LiteralPath $part -Algorithm SHA256).Hash -ne $Hash){Remove-Item -LiteralPath $part -Force; throw 'Downloaded bytes do not match SHA256 pin'}
    Move-Item -LiteralPath $part -Destination $Path -Force
}
function Signature([string]$Path){
    $sig=Get-AuthenticodeSignature -LiteralPath $Path
    if($sig.Status -ne 'Valid' -or -not $sig.SignerCertificate -or $sig.SignerCertificate.Subject -notmatch '(^|,\s*)O=Microsoft Corporation(,|$)'){throw "Microsoft signature invalid: $Path"}
}
function Native([string]$Exe,[string]$Arguments){
    $p=Start-Process -FilePath $Exe -ArgumentList $Arguments -WindowStyle Hidden -PassThru
    while(-not $p.WaitForExit(30000)){Log "Waiting for native PID $($p.Id); no timeout or termination"}
    $null=$p.WaitForExit(); $code=$p.ExitCode; $p.Dispose(); Log "Native exit: $code"; return $code
}
function Restart([string]$Reason){
    if(Busy){throw 'Deferred: servicing/Setup/older worker active; no restart'}
    $boot=(Snapshot).Boot
    if($script:State.RebootBoot -eq $boot){Save 'AwaitingRestart' 'Restart already requested this boot; operator review if cancelled'; return}
    if($script:State.Reboots -ge 3){Save 'ManualAttention' 'Three-restart budget exhausted'; Disable-OwnedTasks; return}
    if(-not (Pending) -and -not $script:State.NativeRequiresRestart){throw 'No confirmed reboot requirement'}
    Save 'RestartWarning' $Reason
    $message='Windows 11 upgrade requires a restart in 2 minutes. Save your work now; applications will be forcibly closed.'
    try{& "$env:SystemRoot\System32\msg.exe" '*' /TIME:120 $message 2>&1|Out-Null}catch{Log 'msg notification unavailable; shutdown notification will be used'}
    # Native shutdown shows the countdown. Continuously cancel it if servicing starts.
    & "$env:SystemRoot\System32\shutdown.exe" /r /f /t 120 /d p:2:3 /c $message
    if($LASTEXITCODE -ne 0){throw 'Could not schedule restart (existing external shutdown is left alone)'}
    $script:State.RebootBoot=$boot; $script:State.Reboots++; Save 'AwaitingRestart' $Reason
    try{
        for($i=0;$i -lt 24;$i++){
            Start-Sleep -Seconds 5
            if(Busy){
                & "$env:SystemRoot\System32\shutdown.exe" /a|Out-Null
                if($LASTEXITCODE -ne 0){throw 'Restart cancellation failed; immediate operator attention required'}
                $script:State.RebootBoot=''; Save 'AwaitingRestart' 'Servicing started during countdown; cancelled our restart'; return
            }
        }
    }catch{
        & "$env:SystemRoot\System32\shutdown.exe" /a|Out-Null
        $script:State.RebootBoot=''; Save 'ManualAttention' ('Countdown guard failed: '+$_.Exception.Message); Disable-OwnedTasks
        throw
    }
}
function Acquire-Iso {
    if((Test-Path -LiteralPath $Iso) -and (Get-FileHash -LiteralPath $Iso -Algorithm SHA256).Hash -eq $IsoHash){return}
    try{
        $f=Join-Path $Root 'Fido.ps1'; Download $FidoUrl $f $FidoHash
        $out=& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $f -Win 11 -Rel Latest -Ed Pro -Lang English -Arch x64 -GetUrl 2>&1
        if($LASTEXITCODE -ne 0){throw 'Fido failed'}
        $urls=@($out|ForEach-Object {[string]$_}|Where-Object {$_ -match '^https://'})
        if($urls.Count -ne 1){throw 'Unexpected Fido URL result'}
        $u=[uri]$urls[0]
        if($u.Host -notin @('software.download.prss.microsoft.com','software-static.download.prss.microsoft.com','software-download.microsoft.com') -or $u.AbsolutePath -notmatch '(?i)Win11_25H2_English_x64.*\.iso$'){throw 'Unexpected Microsoft ISO URL'}
        Download $u.AbsoluteUri $Iso $IsoHash
    }catch{Log ('Primary ISO failed: '+$_.Exception.Message); Download $Fallback $Iso $IsoHash}
}
function Iso-Upgrade($o){
    $bypass=Get-ItemProperty 'HKLM:\SYSTEM\Setup\MoSetup' -ErrorAction SilentlyContinue
    if($bypass -and $bypass.PSObject.Properties['AllowUpgradesWithUnsupportedTPMOrCPU'] -and $bypass.AllowUpgradesWithUnsupportedTPMOrCPU -ne 0){throw 'Existing unsupported TPM/CPU allowance detected; remove through an approved remediation before deployment'}
    if(Test-Path 'HKLM:\SYSTEM\Setup\LabConfig'){throw 'Existing LabConfig bypass configuration; operator review required'}
    if($o.Edition -notin @('Professional','Core','Education')){throw 'Consumer ISO edition unsupported'}
    # Installed UI language, not keyboard/system locale, must match media.
    $lang=(Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\Language').InstallLanguage
    if($lang -ne '0409'){throw 'ISO requires en-US installed UI language'}
    if((Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'").FreeSpace -lt 35GB){throw '35 GB free space required'}
    Acquire-Iso
    $disk=Mount-DiskImage -ImagePath $Iso -PassThru
    try{
        $vol=$disk|Get-Volume|Where-Object DriveLetter|Select-Object -First 1
        if(-not $vol){throw 'ISO has no drive letter'}
        $drive=$vol.DriveLetter+':'; $setup=Join-Path $drive 'setup.exe'
        Signature $setup; Signature (Join-Path $drive 'sources\setupprep.exe')
        $image=Join-Path $drive 'sources\install.wim'; if(-not(Test-Path $image)){$image=Join-Path $drive 'sources\install.esd'}
        $valid=@(Get-WindowsImage -ImagePath $image|ForEach-Object {Get-WindowsImage -ImagePath $image -Index $_.ImageIndex}|Where-Object {$_.EditionId -eq $o.Edition -and ([version]$_.Version).Build -eq 26200 -and [string]$_.Architecture -in @('9','x64','amd64') -and @($_.Languages) -contains 'en-US'})
        if($valid.Count -ne 1){throw 'Expected exactly one matching x64/en-US edition at build 26200'}
        if(Busy){throw 'Deferred: native servicing active'}
        Save 'Scanning' 'Windows Setup compatibility scan'
        $base='/auto upgrade /quiet /eula accept /dynamicupdate enable /noreboot /imageindex '+$valid[0].ImageIndex
        $code=Native $setup ($base+' /compat scanonly /copylogs "'+(Join-Path $Root 'CompatLogs.zip')+'"')
        $hex=[BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$code),0).ToString('X8')
        if($hex -ne 'C1900210'){throw "Compatibility not approved: 0x$hex"}
        if(Busy){throw 'Deferred: native servicing active after scan'}
        $script:State.Attempts++; $script:State.InstallBoot=$o.Boot; Save 'InstallingISO' 'Online Setup started; interrupted execution requires review'
        $code=Native $setup ($base+' /showoobe none /copylogs "'+(Join-Path $Root 'SetupLogs.zip')+'"')
        if($code -notin 0,3010){throw "Setup failed/unexpected exit $code; do not infer restart readiness"}
        $script:State.NativeRequiresRestart=($code -eq 3010)
        Save 'OnlineComplete' 'Setup exited successfully with /noreboot'
        if(Busy){throw 'Setup/servicing still active after parent exited; restart deferred'}
        if((Pending) -or $script:State.NativeRequiresRestart){Restart 'Windows Setup online phase finished'}else{Save 'ManualAttention' 'Setup returned 0 but no confirmed reboot marker; inspect Panther before restarting'; Disable-OwnedTasks}
    }finally{
        if(-not (Busy)){Dismount-DiskImage -ImagePath $Iso -ErrorAction SilentlyContinue}
    }
}
function Test-PrerequisiteCandidate($Update){
    if($Update.BrowseOnly -or $Update.InstallationBehavior.CanRequestUserInput){return $false}
    if($Update.Title -notmatch '(?i)Cumulative Update.*Windows 11.*24H2.*x64'){return $false}
    if($Update.Title -match '(?i)Preview|Insider|Dynamic|Safe OS|\.NET|Hotpatch'){return $false}
    # Older approved CUs cannot satisfy the required baseline.
    if([datetime]$Update.LastDeploymentChangeTime -lt [datetime]'2025-08-29'){return $false}
    $build=[regex]::Match([string]$Update.Title,'26100\.(\d+)')
    if($build.Success -and [int]$build.Groups[1].Value -lt 5074){return $false}
    return $true
}
function Invoke-PrerequisiteOperation($Owner,[string]$Kind,[string]$Criteria=''){
    if(-not ('Unified25H2.UpdateCallback' -as [type])){
        Add-Type 'using System.Runtime.InteropServices; namespace Unified25H2 { [ComVisible(true),ClassInterface(ClassInterfaceType.AutoDispatch)] public class UpdateCallback { [DispId(0)] public void Invoke(object job,object args){} } }'
    }
    $callback=New-Object Unified25H2.UpdateCallback
    switch($Kind){
        'Search' {$job=$Owner.BeginSearch($Criteria,$callback,$null)}
        'Download' {$job=$Owner.BeginDownload($callback,$callback,$null)}
        'Install' {$job=$Owner.BeginInstall($callback,$callback,$null)}
        default {throw 'Unknown Windows Update operation'}
    }
    # Never abort or kill a servicing operation because of an arbitrary timeout.
    $watch=[Diagnostics.Stopwatch]::StartNew(); $nextLog=0
    while(-not $job.IsCompleted){
        if($watch.Elapsed.TotalSeconds -ge $nextLog){Log "Prerequisite $Kind active ($([int]$watch.Elapsed.TotalSeconds) seconds)"; $nextLog=$watch.Elapsed.TotalSeconds+30}
        Start-Sleep -Seconds 5
    }
    switch($Kind){
        'Search' {$result=$Owner.EndSearch($job)}
        'Download' {$result=$Owner.EndDownload($job)}
        'Install' {$result=$Owner.EndInstall($job)}
    }
    $watch.Stop(); return $result
}
function Install-Prerequisite($o){
    if($o.UBR -ge 5074){return}
    if($script:State.PrereqAttempts -ge 3){Save 'ManualAttention' 'Three prerequisite installation attempts exhausted'; Disable-OwnedTasks; return}
    if((Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'").FreeSpace -lt 15GB){throw '15 GB free space required for cumulative-update prerequisite servicing'}
    $session=New-Object -ComObject Microsoft.Update.Session
    $session.ClientApplicationID='Unified25H2-Prerequisite'; $session.UserLocale=1033
    $searcher=$session.CreateUpdateSearcher()
    $searcher.ServerSelection=0; $searcher.Online=$true
    Save 'PrerequisiteSearch' 'Searching configured Windows Update/WSUS source for applicable non-preview 24H2 cumulative update'
    $scan=Invoke-PrerequisiteOperation $searcher Search "IsInstalled=0 and IsHidden=0 and Type='Software'"
    if($scan.ResultCode -ne 2){throw "Prerequisite scan incomplete: result=$($scan.ResultCode)"}
    $candidates=@(for($i=0;$i -lt $scan.Updates.Count;$i++){$u=$scan.Updates.Item($i); if(Test-PrerequisiteCandidate $u){$u}})
    if(-not $candidates.Count){throw 'No qualifying 24H2 cumulative update offered by configured update source. Check WSUS approvals, update policy, network and scan logs; baseline is not bypassed'}
    $chosen=$candidates|Sort-Object LastDeploymentChangeTime -Descending|Select-Object -First 1
    $script:State.PrereqTitle=[string]$chosen.Title
    Log ('Selected prerequisite: '+$script:State.PrereqTitle+'; update ID='+$chosen.Identity.UpdateID)
    if(-not $chosen.EulaAccepted){$chosen.AcceptEula()}
    $collection=New-Object -ComObject Microsoft.Update.UpdateColl; $null=$collection.Add($chosen)
    $downloader=$session.CreateUpdateDownloader(); $downloader.Updates=$collection
    Save 'PrerequisiteDownload' $script:State.PrereqTitle
    $download=Invoke-PrerequisiteOperation $downloader Download
    $item=$download.GetUpdateResult(0)
    if($download.ResultCode -ne 2 -or $item.ResultCode -ne 2 -or -not $chosen.IsDownloaded){throw "Prerequisite download failed: HRESULT=$($item.HResult)"}
    if(Busy){throw 'Servicing became busy before prerequisite installation; will retry without overlap'}
    $installer=$session.CreateUpdateInstaller(); $installer.Updates=$collection
    $installer.ForceQuiet=$true; $installer.AllowSourcePrompts=$false
    if($installer.IsBusy){throw 'Windows Update installer busy; prerequisite deferred'}
    if($installer.RebootRequiredBeforeInstallation){Restart 'Windows Update requires restart before cumulative update'; return}
    $script:State.PrereqAttempts++; $script:State.PrereqBoot=$o.Boot; $script:State.PrereqInFlight=$true
    Save 'InstallingPrerequisite' $script:State.PrereqTitle
    $installed=Invoke-PrerequisiteOperation $installer Install
    $item=$installed.GetUpdateResult(0)
    Log "Prerequisite result=$($installed.ResultCode); item=$($item.ResultCode); HRESULT=$($item.HResult)"
    if($installed.ResultCode -ne 2 -or $item.ResultCode -ne 2){throw "Prerequisite install failed/partial: HRESULT=$($item.HResult); no reboot inferred"}
    $script:State.PrereqInFlight=$false
    $script:State.NativeRequiresRestart=[bool]($installed.RebootRequired -or $item.RebootRequired)
    Save 'PrerequisiteComplete' 'Cumulative update installer returned complete success; verifying baseline before enablement'
    if($script:State.NativeRequiresRestart -or (Pending)){Restart '24H2 cumulative update installed; 25H2 continues after restart'; return}
    if((Snapshot).UBR -lt 5074){Save 'ManualAttention' 'Successful prerequisite install did not reach 26100.5074 and requested no restart'; Disable-OwnedTasks}
}
function Msu-Upgrade($o){
    if($o.UBR -lt 5074){Install-Prerequisite $o; return}
    $pk=@(Get-WindowsPackage -Online|Where-Object {$_.PackageName -eq $Package})
    if(@($pk|Where-Object {[string]$_.PackageState -in 'Installed','InstallPending'}).Count){
        $script:State.NativeRequiresRestart=$true; Save 'OnlineComplete' 'Pinned KB5054156 already installed/pending'; Restart 'Enablement package awaiting restart'; return
    }
    $path=Join-Path $Root 'KB5054156.msu'; Download $MsuUrl $path $MsuHash; Signature $path
    if(Busy){throw 'Deferred: native servicing active'}
    $script:State.Attempts++; $script:State.InstallBoot=$o.Boot; Save 'InstallingMSU' 'DISM native applicability checks retained'
    $code=Native "$env:SystemRoot\System32\dism.exe" ('/Online /Add-Package /PackagePath:"'+$path+'" /Quiet /NoRestart /English /LogPath:"'+(Join-Path $Root 'DISM.log')+'"')
    if($code -notin 0,3010){throw "DISM failed: $code"}
    $pk=@(Get-WindowsPackage -Online|Where-Object {$_.PackageName -eq $Package -and [string]$_.PackageState -in 'Installed','InstallPending'})
    if($pk.Count -ne 1){throw 'DISM success without expected package identity/state'}
    $script:State.NativeRequiresRestart=($code -eq 3010 -or [string]$pk[0].PackageState -eq 'InstallPending')
    Save 'OnlineComplete' 'Expected enablement package confirmed'
    Restart 'Windows 11 enablement servicing finished'
}
if($CheckOnly){Snapshot|Format-List; if(Test-Path -LiteralPath $StatePath){Get-Content -LiteralPath $StatePath}; exit 0}
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
if(-not ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Elevation required'}
if(-not $Install -and $identity.User.Value -ne 'S-1-5-18'){throw 'Worker must run as SYSTEM; use -Install'}
$mutex=[Threading.Mutex]::new($false,'Global\Unified25H2-v1')
$locked=$false
$script:State=$null
$stateValid=$false
$awake=$null
try{
    try{$locked=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$locked=$true}
    if(-not $locked){Write-Output 'Worker already active; deployment unchanged'; exit 0}
    Ensure-Root
    $script:State=@{Schema=1;Phase='New';Detail='';UpdatedUtc='';Attempts=0;Runs=0;Reboots=0;RebootBoot='';InstallBoot='';OriginalEdition='';NativeRequiresRestart=$false;CreatedUtc=[datetime]::UtcNow.ToString('o');PrereqAttempts=0;PrereqBoot='';PrereqTitle='';PrereqInFlight=$false}
    if(Test-Path -LiteralPath $StatePath){
        $loaded=Get-Content -LiteralPath $StatePath -Raw|ConvertFrom-Json
        if($loaded.Schema -ne 1){throw 'State schema invalid; no automatic reset'}
        foreach($key in @($script:State.Keys)){
            if(-not $loaded.PSObject.Properties[$key]){if($key -in 'PrereqAttempts','PrereqBoot','PrereqTitle','PrereqInFlight'){continue}; throw "State field missing: $key"}
            $script:State[$key]=$loaded.$key
        }
    }
    foreach($key in @('Attempts','Runs','Reboots','PrereqAttempts')){if($script:State[$key] -isnot [int] -and $script:State[$key] -isnot [long]){throw "Invalid state counter: $key"}; if($script:State[$key] -lt 0){throw "Negative state counter: $key"}}
    if($script:State.PrereqInFlight -isnot [bool]){throw 'Invalid prerequisite recovery flag'}
    $null=[datetime]::Parse($script:State.CreatedUtc)
    $stateValid=$true
    $o=Snapshot; $route=Route $o
    if($route -eq 'Complete'){
        if($script:State.OriginalEdition -and $script:State.OriginalEdition -ne $o.Edition){Save 'ManualAttention' 'Target build reached but edition changed'; Disable-OwnedTasks; exit 1}
        Save 'Complete' 'Installed release, running kernel and preserved edition verify Windows 11 25H2'; Disable-OwnedTasks; exit 0
    }
    if($route -eq 'Inconsistent' -and -not $Install -and $script:State.InstallBoot -eq $o.Boot -and $script:State.Phase -in 'OnlineComplete','AwaitingRestart','RestartWarning'){
        Restart 'Owned completed online phase has staged a kernel transition'; exit 0
    }
    if($route -in 'Unsupported','Inconsistent'){throw "Unsupported/inconsistent OS: $($o|ConvertTo-Json -Compress)"}
    if(-not $script:State.OriginalEdition){$script:State.OriginalEdition=$o.Edition}
    if($Install){
        if(Busy){throw 'Existing upgrade/servicing active; tasks and worker left unchanged'}
        foreach($n in $Tasks){Assert-Task $n}
        if(Test-Path -LiteralPath $Worker){
            $deployedHash=(Get-FileHash $Worker).Hash; $newHash=(Get-FileHash $PSCommandPath).Hash
            if($deployedHash -ne $newHash){
                # Allow only the exact previous delivered version, at a safe pre-install stage.
                if($deployedHash -ne '12EE62AD6E44156BFA4C28A629344255B00194F7B0AC2B24F90882E7E508CFD5' -or $script:State.InstallBoot -or $script:State.PrereqInFlight -or $script:State.Phase -notin 'New','Installed','Deferred','Ready' -or (Pending)){throw 'Different deployed worker exists outside the reviewed safe migration path'}
                foreach($n in $Tasks){$existing=Get-ScheduledTask -TaskName $n -TaskPath '\' -ErrorAction SilentlyContinue; if($existing -and $existing.State -eq 'Running'){throw 'Prior task running; replacement deferred'}}
                Copy-Item -LiteralPath $PSCommandPath -Destination $Worker -Force
                Log 'Migrated exact previous delivered worker; existing state and loop budgets retained'
            }
        }else{Copy-Item -LiteralPath $PSCommandPath -Destination $Worker}
        $action=New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument ('-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$Worker+'"')
        $principal=New-ScheduledTaskPrincipal -UserId SYSTEM -LogonType ServiceAccount -RunLevel Highest
        $settings=New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable -ExecutionTimeLimit ([timespan]::Zero) -DontStopIfGoingOnBatteries
        $triggers=@((New-ScheduledTaskTrigger -AtStartup),(New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 30)))
        for($i=0;$i -lt 2;$i++){Register-ScheduledTask -TaskName $Tasks[$i] -TaskPath '\' -Action $action -Principal $principal -Settings $settings -Trigger $triggers[$i] -Force|Out-Null}
        if($script:State.Phase -eq 'New'){Save 'Installed' 'SYSTEM tasks installed'}
        Start-ScheduledTask -TaskName $Tasks[1]; Write-Output 'Local SYSTEM worker queued; media downloads occur outside this session'; exit 0
    }
    if($script:State.Phase -in 'Complete','ManualAttention'){exit 0}
    if($script:State.Runs -ge 48 -or $script:State.Attempts -ge 2 -or ([datetime]::UtcNow-[datetime]$script:State.CreatedUtc).TotalDays -gt 7){Save 'ManualAttention' 'Run/attempt/age budget exhausted'; Disable-OwnedTasks; exit 1}
    $script:State.Runs++; Save $script:State.Phase 'Worker entered'
    if(Busy){Save $script:State.Phase 'Another worker/native servicing active; retained recovery phase'; exit 0}
    if($script:State.PrereqInFlight){Save 'ManualAttention' 'Interrupted/partial cumulative-update install; review Windows Update/CBS before resuming'; Disable-OwnedTasks; exit 1}
    # Do not re-run a possibly completed Setup after crash, external reboot, or rollback.
    if($script:State.InstallBoot -and $script:State.InstallBoot -ne $o.Boot){Save 'ManualAttention' 'Upgrade attempt crossed reboot without target verification; possible rollback'; Disable-OwnedTasks; exit 1}
    if(-not $script:State.InstallBoot -and $script:State.RebootBoot -and $script:State.RebootBoot -ne $o.Boot){
        $script:State.NativeRequiresRestart=$false
        Save 'Ready' 'Prerequisite restart completed; rechecking upgrade applicability'
    }
    if($script:State.Phase -in 'InstallingISO','InstallingMSU','Scanning'){Save 'ManualAttention' 'Interrupted native operation; review logs before resuming'; Disable-OwnedTasks; exit 1}
    if($script:State.Phase -eq 'PrerequisiteComplete'){
        if($script:State.NativeRequiresRestart -or (Pending)){Restart 'Completed cumulative update requires restart'; exit 0}
        Save 'Ready' 'Cumulative update complete; rechecking running build threshold'
    }
    if($script:State.Phase -in 'OnlineComplete','AwaitingRestart','RestartWarning'){
        Restart 'Previously completed online phase'; exit 0
    }
    if(Pending){Restart 'Existing Windows servicing requires restart before upgrade'; exit 0}
    $awake=Start-StayAwake
    if($route -eq 'ISO'){Iso-Upgrade $o}else{Msu-Upgrade $o}
}catch{
    $failure=$_.Exception.Message
    if($locked -and $stateValid){
        # Failure after native install may have left servicing staged. Never retry/reboot on speculation.
        try{if($script:State.PrereqInFlight -or $script:State.Phase -in 'InstallingISO','InstallingMSU','Scanning'){Save 'ManualAttention' $failure; Disable-OwnedTasks}elseif($script:State.Phase -in 'OnlineComplete','AwaitingRestart','RestartWarning','PrerequisiteComplete','ManualAttention'){Save $script:State.Phase $failure}else{Save 'Deferred' $failure}}catch{}
    }
    Write-Error $failure -ErrorAction Continue; exit 1
}finally{if($awake){Stop-StayAwake $awake}; if($locked){$mutex.ReleaseMutex()}; $mutex.Dispose()}
