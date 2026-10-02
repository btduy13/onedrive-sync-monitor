@echo off
setlocal
cd /d "%~dp0"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0OneClick-Setup.ps1"
set "SETUP_EXIT=%ERRORLEVEL%"
echo.
if not "%SETUP_EXIT%"=="0" echo Installation did not finish. Please send the error shown above to IT.
echo Press any key to close this window.
pause >nul
exit /b %SETUP_EXIT%
