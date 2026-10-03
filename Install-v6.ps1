$ErrorActionPreference='Stop'
$script=Join-Path $PSScriptRoot 'deploy-v6.ps1'
$p=Start-Process C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -Verb RunAs -WindowStyle Hidden -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$script+'"')) -PassThru -Wait
$r=Get-Content (Join-Path $PSScriptRoot 'deploy-v6-result.json') -Raw | ConvertFrom-Json
Add-Type -AssemblyName System.Windows.Forms
if($p.ExitCode -ne 0 -or -not $r.Success){[Windows.Forms.MessageBox]::Show('Обновление не выполнено: '+$r.Error,'GPU Manager') | Out-Null;exit 1}
[Windows.Forms.MessageBox]::Show('GPU Manager v6 установлен. Повторная установка не требуется. Откройте ярлык GPU - Intel и NVIDIA.','GPU Manager') | Out-Null
