@echo off
REM Double-click to install aip for PowerShell. Add "-Uninstall" to remove.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
echo.
pause
