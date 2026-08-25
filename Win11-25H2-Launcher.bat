@echo off
setlocal
set "ROOT=C:\ProgramData\Win11-25H2"
if not exist "%ROOT%" mkdir "%ROOT%"
echo [%date% %time%] Launcher started.>>"%ROOT%\Launcher.log"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%ROOT%\Upgrade-25H2.ps1" >>"%ROOT%\Launcher.log" 2>&1
set "RC=%ERRORLEVEL%"
echo [%date% %time%] Launcher finished with exit code %RC%.>>"%ROOT%\Launcher.log"
exit /b %RC%
