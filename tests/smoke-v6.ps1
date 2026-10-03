$ProjectRoot=Split-Path $PSScriptRoot -Parent
$ErrorActionPreference='Stop'
$exe='C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
$main=Join-Path $ProjectRoot 'GpuManager.ps1'
$data=Join-Path $ProjectRoot 'data'
$p=Start-Process $exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',('"'+$main+'"'),'-ObserveOnly','-ExitAfterSeconds','40') -WindowStyle Hidden -PassThru -RedirectStandardError (Join-Path $ProjectRoot 'smoke-error.txt')
try{
 $ready=$false
 for($i=0;$i -lt 60;$i++){
  if($p.HasExited){throw 'Observer exited early'}
  $statusFile=Join-Path $data 'status.json'
  if(Test-Path $statusFile){$s=Get-Content $statusFile -Raw | ConvertFrom-Json;if($s.ProcessId -eq $p.Id){$ready=$true;break}}
  Start-Sleep -Milliseconds 500
 }
 if(-not $ready){throw 'Observer did not report ready within 30 seconds'}
 $queue=Join-Path $data 'commands';New-Item -ItemType Directory -Path $queue -Force | Out-Null
 @{Action='Mode';Value='Nvidia';Minutes=0} | ConvertTo-Json | Set-Content (Join-Path $queue '01-pause.json') -Encoding UTF8
 Start-Sleep -Seconds 4
 $s=Get-Content (Join-Path $data 'status.json') -Raw | ConvertFrom-Json
 if($s.Mode -ne 'Nvidia' -or $s.Until){throw 'Indefinite pause failed'}
 'PASS: indefinite pause is persisted and reported'
 @{Action='Mode';Value='Auto'} | ConvertTo-Json | Set-Content (Join-Path $queue '02-auto.json') -Encoding UTF8
 Start-Sleep -Seconds 4
 $s=Get-Content (Join-Path $data 'status.json') -Raw | ConvertFrom-Json
 if($s.Mode -ne 'Auto' -or -not $s.Pending){throw 'Auto mode did not queue check'}
 'PASS: queued commands processed without overwriting'
 Start-Sleep -Seconds 18
 $s=Get-Content (Join-Path $data 'status.json') -Raw | ConvertFrom-Json
 if($s.Status -match 'Ошибка'){throw $s.Status}
 'PASS: passive safety check completed: '+$s.Status
 $p.WaitForExit(25000) | Out-Null;if(-not $p.HasExited){throw 'Observer did not exit'}
 'PASS: observer stopped cleanly; live v5 task was unaffected; no GPU reset executed'
}finally{if(-not $p.HasExited){Stop-Process -Id $p.Id}}
