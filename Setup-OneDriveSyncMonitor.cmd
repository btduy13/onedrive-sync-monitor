@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-OneDriveSyncMonitor.ps1" -PromptForWebhook
set "MONITOR_EXIT=%ERRORLEVEL%"
echo.
if not "%MONITOR_EXIT%"=="0" echo Installation failed. Please copy the error above and contact IT.
pause
exit /b %MONITOR_EXIT%
