#requires -Version 5.1
# All update/session/install/reboot operations below are mocks; never services Windows.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Upgrade-Unified25H2.ps1'),[ref]$tokens,[ref]$errors)
foreach($name in @('Test-PrerequisiteCandidate','Install-Prerequisite','Msu-Upgrade')){
    $functionAst=$ast.Find({param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq $name},$true)
    Invoke-Expression $functionAst.Extent.Text
}
function Log([string]$Text){}
function Save([string]$Phase,[string]$Detail){$script:State.Phase=$Phase; $script:State.Detail=$Detail}
function Busy {return $false}
function Pending {return $false}
function Snapshot {return $script:Os}
function Restart([string]$Reason){$script:Restarts++}
function Disable-OwnedTasks {$script:Disabled=$true}
function Get-CimInstance {param($ClassName,$Filter) return [pscustomobject]@{FreeSpace=32GB}}
function New-Object {
    param([string]$ComObject)
    switch($ComObject){
        'Microsoft.Update.Session' {return $script:Mocks.Session}
        'Microsoft.Update.UpdateColl' {return $script:Mocks.Collection}
        default {throw "Unexpected COM creation: $ComObject"}
    }
}
function Invoke-PrerequisiteOperation {
    param($Owner,[string]$Kind,[string]$Criteria='')
    $script:Operations+=,$Kind
    if($Kind -eq 'Install' -and $script:CrashInstall){throw 'Simulated interrupted install'}
    return $script:Mocks[$Kind]
}
function Reset-Fixture {
    $script:Restarts=0; $script:Disabled=$false; $script:CrashInstall=$false; $script:Operations=@()
    $script:State=@{PrereqAttempts=0;PrereqBoot='';PrereqTitle='';PrereqInFlight=$false;NativeRequiresRestart=$false;Phase='Ready'}
    $script:Os=[pscustomobject]@{Build=26100;UBR=4000;Boot='boot-a'}
    $script:Candidate=[pscustomobject]@{Title='2026-09 Cumulative Update for Windows 11 Version 24H2 for x64-based Systems (KB9999999) (26100.9000)';BrowseOnly=$false;InstallationBehavior=[pscustomobject]@{CanRequestUserInput=$false};LastDeploymentChangeTime=[datetime]'2026-09-08';EulaAccepted=$true;Identity=[pscustomobject]@{UpdateID='mock-id'};IsDownloaded=$true}
    $updates=[pscustomobject]@{Count=1}
    $updates|Add-Member ScriptMethod Item {param($i) return $script:Candidate}
    $collection=[pscustomobject]@{}
    $collection|Add-Member ScriptMethod Add {param($u) return 0}
    $session=[pscustomobject]@{ClientApplicationID='';UserLocale=0}
    $session|Add-Member ScriptMethod CreateUpdateSearcher {return $script:Mocks.Searcher}
    $session|Add-Member ScriptMethod CreateUpdateDownloader {return $script:Mocks.Downloader}
    $session|Add-Member ScriptMethod CreateUpdateInstaller {return $script:Mocks.Installer}
    $download=[pscustomobject]@{ResultCode=2}
    $download|Add-Member ScriptMethod GetUpdateResult {param($i) return $script:Mocks.DownloadItem}
    $install=[pscustomobject]@{ResultCode=2;RebootRequired=$true}
    $install|Add-Member ScriptMethod GetUpdateResult {param($i) return $script:Mocks.InstallItem}
    $script:Mocks=@{
        Session=$session;Collection=$collection
        Searcher=[pscustomobject]@{ServerSelection=-1;Online=$false}
        Downloader=[pscustomobject]@{Updates=$null}
        Installer=[pscustomobject]@{Updates=$null;ForceQuiet=$false;AllowSourcePrompts=$true;IsBusy=$false;RebootRequiredBeforeInstallation=$false}
        Search=[pscustomobject]@{ResultCode=2;Updates=$updates}
        Download=$download; DownloadItem=[pscustomobject]@{ResultCode=2;HResult=0}
        Install=$install; InstallItem=[pscustomobject]@{ResultCode=2;HResult=0;RebootRequired=$true}
    }
}
function Assert([bool]$Condition,[string]$Detail){if(-not $Condition){throw $Detail}}
Reset-Fixture
Assert (Test-PrerequisiteCandidate $script:Candidate) 'Eligible cumulative update rejected'
foreach($title in @('Cumulative Update Preview for Windows 11 Version 24H2 for x64','Cumulative Update for .NET for Windows 11 Version 24H2 for x64','Cumulative Update for Windows 11 Version 25H2 for x64','Cumulative Update for Windows 11 Version 24H2 for ARM64','Cumulative Update for Windows 11 Version 24H2 for x64 (26100.4946)','Hotpatch Cumulative Update for Windows 11 Version 24H2 for x64')){
    $script:Candidate.Title=$title; Assert (-not (Test-PrerequisiteCandidate $script:Candidate)) "Unsafe candidate accepted: $title"
}
Reset-Fixture
$script:Candidate.BrowseOnly=$true; Assert (-not (Test-PrerequisiteCandidate $script:Candidate)) 'Optional update accepted'
$script:Candidate.BrowseOnly=$false; $script:Candidate.InstallationBehavior.CanRequestUserInput=$true; Assert (-not (Test-PrerequisiteCandidate $script:Candidate)) 'Interactive update accepted'
Reset-Fixture
Msu-Upgrade $script:Os
Assert (($script:Operations -join ',') -eq 'Search,Download,Install') 'Missing baseline did not trigger automatic prerequisite chain'
Assert ($script:Restarts -eq 1 -and $script:State.PrereqAttempts -eq 1 -and -not $script:State.PrereqInFlight) 'Successful prerequisite did not safely stage restart'
Assert ($script:Mocks.Searcher.ServerSelection -eq 0) 'Configured Windows Update/WSUS source was not respected'
Assert ($script:Mocks.Installer.ForceQuiet -and -not $script:Mocks.Installer.AllowSourcePrompts) 'Install not noninteractive'
Reset-Fixture
$script:Mocks.Search.Updates.Count=0
$failed=$false; try{Install-Prerequisite $script:Os}catch{$failed=$true}
Assert ($failed -and $script:Restarts -eq 0 -and $script:State.PrereqAttempts -eq 0) 'No-offer must stop before install/restart'
Reset-Fixture
$script:Mocks.DownloadItem.ResultCode=4
$failed=$false; try{Install-Prerequisite $script:Os}catch{$failed=$true}
Assert ($failed -and $script:Restarts -eq 0 -and $script:Operations.Count -eq 2) 'Failed download must not install/restart'
Reset-Fixture
$script:Mocks.InstallItem.ResultCode=3
$failed=$false; try{Install-Prerequisite $script:Os}catch{$failed=$true}
Assert ($failed -and $script:State.PrereqInFlight -and $script:Restarts -eq 0) 'Partial install must retain review flag, without reboot'
Reset-Fixture
$script:CrashInstall=$true
$failed=$false; try{Install-Prerequisite $script:Os}catch{$failed=$true}
Assert ($failed -and $script:State.PrereqInFlight -and $script:Restarts -eq 0) 'Interrupted install lost durable recovery flag'
Reset-Fixture
$script:Mocks.Install.RebootRequired=$false; $script:Mocks.InstallItem.RebootRequired=$false
Install-Prerequisite $script:Os
Assert ($script:Disabled -and $script:State.Phase -eq 'ManualAttention' -and $script:Restarts -eq 0) 'Successful install without required build or restart must stop for review'
Reset-Fixture
$script:State.PrereqAttempts=3
Install-Prerequisite $script:Os
Assert ($script:Disabled -and $script:Operations.Count -eq 0) 'Prerequisite install budget not enforced'
Reset-Fixture
$script:Os.UBR=5074
Install-Prerequisite $script:Os
Assert ($script:Operations.Count -eq 0 -and $script:Restarts -eq 0) 'Satisfied baseline must not install extra updates'
Write-Output 'PASS: prerequisite candidate filtering, automatic CU chain, managed-source policy, quiet install, no offer, download failure, partial/interrupted install recovery, unmet postcondition, attempt budget and satisfied-baseline no-op (all mocked).'
