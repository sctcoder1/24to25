#requires -Version 5.1
# Worker SHA256: 55D985D1E3779BEBCB023378ED2AB253C87E9610EA1989077EE2AEF3930A40EF
$ErrorActionPreference='Stop'
$id=[Security.Principal.WindowsIdentity]::GetCurrent()
if(-not ([Security.Principal.WindowsPrincipal]::new($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Run this launcher elevated or as SYSTEM'}
$r=Join-Path $env:ProgramData 'Unified25H2'
$ancestor=[IO.Path]::GetFullPath($r)
while($ancestor){if(Test-Path -LiteralPath $ancestor){if((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Redirected deployment path'}}; $ancestor=[IO.Path]::GetDirectoryName($ancestor)}
New-Item -ItemType Directory -Path $r -Force|Out-Null
$acl=Get-Acl -LiteralPath $r
$acl.SetSecurityDescriptorSddlForm('O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)')
Set-Acl -LiteralPath $r -AclObject $acl
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
$ref=Invoke-RestMethod -Uri 'https://api.github.com/repos/sctcoder1/24to25/git/ref/heads/main' -Headers @{'User-Agent'='Unified25H2-Bootstrap'} -TimeoutSec 45
$commit=[string]$ref.object.sha
if($commit -notmatch '^[a-fA-F0-9]{40}$'){throw 'Invalid GitHub ref'}
$p=Join-Path $r ('Bootstrap-'+[guid]::NewGuid().ToString('N')+'.ps1')
try{
    $url='https://raw.githubusercontent.com/sctcoder1/24to25/'+$commit+'/upgrade25h2/Upgrade-Unified25H2.ps1'
    Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $p -TimeoutSec 90
    if((Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash -ne '55D985D1E3779BEBCB023378ED2AB253C87E9610EA1989077EE2AEF3930A40EF'){throw 'Worker SHA256 mismatch; no task or deployed worker changed'}
    $t=$null; $e=$null
    [void][Management.Automation.Language.Parser]::ParseFile($p,[ref]$t,[ref]$e)
    if($e.Count){throw 'Worker syntax invalid'}
    & $p -Install
    $rc=$LASTEXITCODE
}finally{Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue}
exit $rc
