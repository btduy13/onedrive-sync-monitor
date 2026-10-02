@echo off
setlocal
echo OneDrive Sync Monitor - one-click uninstall
echo This removes the app and its auto-start entries for your Windows account.
echo Config, cloud backup state, logs, and your certificate will be kept.
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Uninstall-OneDriveSyncMonitor.ps1" -RemoveProgramFiles
if errorlevel 1 (
  echo.
  echo Uninstall did not finish. Send the error above to IT.
  pause
  exit /b 1
)
echo.
echo Uninstall completed. You may now delete this extracted installer folder.
pause
exit /b 0
