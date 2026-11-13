@echo off
chcp 65001 >nul
setlocal
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0辅助文件\Setup.ps1"
if errorlevel 1 (
  echo Setup could not start. Please check Windows PowerShell 5.1 and try again.
  pause
)
endlocal
