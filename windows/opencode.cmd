@echo off
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0opencode-smart.ps1" %*
exit /b %ERRORLEVEL%
