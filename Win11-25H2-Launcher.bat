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
