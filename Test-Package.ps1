#requires -Version 5.1
$ErrorActionPreference='Stop'
$worker=Join-Path $PSScriptRoot 'Upgrade-Unified25H2.ps1'
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($worker,[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors|Out-String)}
# Load only the pure routing function, never execute worker entry point.
$route=$ast.Find({param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq 'Route'},$true)
Invoke-Expression $route.Extent.Text
$cases=@(
    @(19045,'22H2','ISO'),@(22631,'23H2','ISO'),@(26100,'24H2','MSU'),@(26200,'25H2','Complete'),
    @(22621,'22H2','Unsupported'),@(19044,'21H2','Unsupported'),@(26200,'24H2','Unsupported')
)
foreach($c in $cases){$o=[pscustomobject]@{Build=$c[0];Running=$c[0];Release=$c[1];Type='Client';Architecture='AMD64'}; if((Route $o) -ne $c[2]){throw "Route failed: $c"}}
$o=[pscustomobject]@{Build=26200;Running=26100;Release='25H2';Type='Client';Architecture='AMD64'}
if((Route $o) -ne 'Inconsistent'){throw 'Staged/kernel mismatch test failed'}
$o.Running=26200; $o.Architecture='ARM64'; if((Route $o) -ne 'Unsupported'){throw 'ARM64 must be rejected'}
$o.Architecture='AMD64'; $o.Type='Server'; if((Route $o) -ne 'Unsupported'){throw 'Server must be rejected'}
# Regression: logging must not turn a native integer exit code into a pipeline array.
$native=$ast.Find({param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq 'Native'},$true)
Invoke-Expression $native.Extent.Text
function Log([string]$Text){Write-Host $Text}
function Start-Process {
    param($FilePath,$ArgumentList,$WindowStyle,[switch]$PassThru)
    $p=[pscustomobject]@{Id=123;ExitCode=3010}
    $p|Add-Member ScriptMethod WaitForExit {param($timeout) return $true}
    $p|Add-Member ScriptMethod Dispose {}
    return $p
}
$result=Native 'unused' 'unused'
if($result -is [array] -or $result -ne 3010){throw 'Native must return exactly one exit code'}
Remove-Item Function:\Start-Process
foreach($f in Get-ChildItem $PSScriptRoot -Filter '*.ps1'){
    $errors=$null; [void][Management.Automation.Language.Parser]::ParseFile($f.FullName,[ref]$tokens,[ref]$errors)
    if($errors.Count){throw ($errors|Out-String)}
}
if(Test-Path (Join-Path $PSScriptRoot 'SHA256SUMS.txt')){
    foreach($line in Get-Content (Join-Path $PSScriptRoot 'SHA256SUMS.txt')){
        $hash,$name=$line -split '  ',2
        if((Get-FileHash (Join-Path $PSScriptRoot $name) -Algorithm SHA256).Hash -ne $hash){throw "Hash mismatch: $name"}
    }
}
$tv=Join-Path $PSScriptRoot 'TeamViewer-Deploy25H2.ps1'
if(Test-Path $tv){
    $expected=(Get-FileHash $worker -Algorithm SHA256).Hash
    if((Get-Content $tv -Raw) -notmatch $expected){throw 'TeamViewer worker pin stale'}
    $line=(Get-Content (Join-Path $PSScriptRoot 'Sophos-Deploy25H2.txt') -Raw).Trim()
    if($line.Length -gt 8191 -or $line -match '[\r\n]'){throw 'Invalid CMD launcher length/lines'}
    $body=[Text.Encoding]::Unicode.GetString([Convert]::FromBase64String(($line -split ' ')[-1]))
    if($body -notmatch $expected){throw 'Sophos worker pin stale'}
    $errors=$null; [void][Management.Automation.Language.Parser]::ParseInput($body,[ref]$tokens,[ref]$errors)
    if($errors.Count){throw 'Decoded Sophos bootstrap syntax errors'}
}
& (Join-Path $PSScriptRoot 'Test-Prerequisites.ps1')
Write-Output 'PASS: PowerShell syntax, 10 routing cases, native exit-code regression, launcher pins/decoded syntax/CMD length, package hashes, prerequisite regression suite. No real tasks, servicing, downloads or restarts executed.'
