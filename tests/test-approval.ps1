$ProjectRoot=Split-Path $PSScriptRoot -Parent
$ErrorActionPreference='Stop'
$fixture=Join-Path $ProjectRoot ('approval-test-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
$data=Join-Path $fixture 'data';New-Item -ItemType Directory -Path $data | Out-Null
foreach($name in @('GpuCommon.ps1','GpuV6.ps1','GpuBattery.ps1','GpuNative.cs','config.json')){Copy-Item -LiteralPath (Join-Path $ProjectRoot $name) -Destination (Join-Path $fixture $name)}
$cfg=Get-Content (Join-Path $fixture 'config.json') -Raw | ConvertFrom-Json;$cfg.SettleSeconds=1;$cfg | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $fixture 'config.json') -Encoding UTF8
@{ResetPolicy='Notify';ProtectedPaths=@()} | ConvertTo-Json | Set-Content (Join-Path $data 'options.json') -Encoding UTF8
42 | Set-Content (Join-Path $data 'fixture-client.txt')
$mocks=@'
function Get-FixturePower {return [pscustomobject]@{Present=$true;Problem=0;Power='D0'}}
function Get-Topology {return @([pscustomobject]@{Key='fixture';Internal=$true;Nvidia=$false})}
function Get-NvidiaLuid {return 'fixture'}
function Get-DefaultAssignments {return @()}
function Get-ProtectedProcesses {return @()}
function Get-GpuClients {return @([pscustomobject]@{Id=[int](Get-Content (Join-Path $Data 'fixture-client.txt'));Name='fixture-dwm';Path="$env:windir\System32\dwm.exe"})}
function Invoke-CheckedGpuRestart {throw 'TEST SAFETY: real device restart is forbidden'}
'@
Add-Content -LiteralPath (Join-Path $fixture 'GpuCommon.ps1') -Value $mocks -Encoding UTF8
$source=Get-Content (Join-Path $ProjectRoot 'GpuManager.ps1') -Raw
$source=$source.Replace('[GpuNative]::ReadPower($Config.DeviceId)','(Get-FixturePower)')
[IO.File]::WriteAllText((Join-Path $fixture 'GpuManager.ps1'),$source,[Text.UTF8Encoding]::new($true))
$queue=Join-Path $data 'commands';New-Item -ItemType Directory -Path $queue | Out-Null
function Command([string]$Action,[string]$Value=''){@{Action=$Action;Value=$Value} | ConvertTo-Json | Set-Content (Join-Path $queue ([guid]::NewGuid().ToString('N')+'.json')) -Encoding UTF8}
function Snapshot {return (Get-Content (Join-Path $data 'status.json') -Raw | ConvertFrom-Json)}
$exe='C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
$p=Start-Process $exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',('"'+(Join-Path $fixture 'GpuManager.ps1')+'"'),'-ObserveOnly','-ExitAfterSeconds','40') -WindowStyle Hidden -PassThru
try{
 Start-Sleep -Seconds 4;Command 'Mode' 'Auto';Start-Sleep -Seconds 7
 $s=Snapshot;if($s.Pending -or $s.Approval -or $s.Status -notmatch 'Только уведомление'){throw 'Notify policy failed'}
 'PASS: Notify finishes without approving or restarting'
 Command 'Check';Start-Sleep -Seconds 7
 $s=Snapshot;if(-not $s.Approval){throw 'Manual approval was not requested'};$old=$s.Approval.Id
 'PASS: Manual request asks even under Notify policy'
 43 | Set-Content (Join-Path $data 'fixture-client.txt');Command 'Approve' $old;Start-Sleep -Seconds 4
 $s=Snapshot;if(-not $s.Approval -or $s.Approval.Id -eq $old -or $s.Status -match 'DRY_RUN'){throw 'Changed clients did not invalidate approval'}
 'PASS: Changed GPU clients require a fresh approval'
 Command 'Approve' $s.Approval.Id;Start-Sleep -Seconds 4
 $s=Snapshot;if($s.Pending -or $s.Approval -or $s.Status -notmatch 'DRY_RUN'){throw 'Approved dry-run did not complete'}
 'PASS: Fresh approval passes repeated gates; ObserveOnly still prevents a real restart'
}finally{if(-not $p.HasExited){Stop-Process -Id $p.Id};Remove-Item -LiteralPath $fixture -Recurse -Force}
