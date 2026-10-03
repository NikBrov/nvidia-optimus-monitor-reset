@echo off
if exist "%~dp0GpuManager.Agent.exe" (
 powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-v7.ps1"
) else (
 if exist "%~dp0artifacts\package\GpuManager.Agent.exe" (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0artifacts\package\Install-v7.ps1"
 ) else (
  echo Build the package first: powershell -File scripts\Build.ps1
  pause
 )
)
