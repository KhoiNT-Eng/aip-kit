@echo off
REM Double-click to run the aip test suite. Uses a temporary sandbox; your real logins are not touched.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run-tests.ps1" %*
echo.
pause
