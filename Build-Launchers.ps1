#requires -Version 5.1
# Re-run only after deliberately reviewing changes to the worker. Pins exact file bytes.
$ErrorActionPreference='Stop'
$hash=(Get-FileHash (Join-Path $PSScriptRoot 'Upgrade-Unified25H2.ps1') -Algorithm SHA256).Hash
$bootstrap=@'
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
    if((Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash -ne '__WORKER_HASH__'){throw 'Worker SHA256 mismatch; no task or deployed worker changed'}
    $t=$null; $e=$null
    [void][Management.Automation.Language.Parser]::ParseFile($p,[ref]$t,[ref]$e)
    if($e.Count){throw 'Worker syntax invalid'}
    & $p -Install
    $rc=$LASTEXITCODE
}finally{Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue}
exit $rc
'@
$bootstrap=$bootstrap.Replace('__WORKER_HASH__',$hash)
$bootstrap=$bootstrap -replace '\r?\n',"`r`n"
$utf8=[Text.UTF8Encoding]::new($false)
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'TeamViewer-Deploy25H2.ps1'),("#requires -Version 5.1`r`n# Worker SHA256: $hash`r`n"+$bootstrap+"`r`n"),$utf8)
# EncodedCommand uses UTF-16LE. No CMD metacharacters, variable expansion or fragile quoting.
$encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap))
$line='powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand '+$encoded
if($line.Length -gt 8191){throw 'Sophos command exceeds CMD line limit'}
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'Sophos-Deploy25H2.txt'),($line+"`r`n"),[Text.Encoding]::ASCII)
$manifest=Get-ChildItem $PSScriptRoot -File|Where-Object {$_.Name -ne 'SHA256SUMS.txt'}|Sort-Object Name|ForEach-Object {((Get-FileHash $_.FullName -Algorithm SHA256).Hash+'  '+$_.Name)}
[IO.File]::WriteAllLines((Join-Path $PSScriptRoot 'SHA256SUMS.txt'),[string[]]$manifest,$utf8)
Write-Output "Worker SHA256: $hash; Sophos CMD length: $($line.Length)"
