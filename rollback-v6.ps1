$ErrorActionPreference='Stop'
$dest=$PSScriptRoot;$data=Join-Path $dest 'data';$taskName='Auto Reset NVIDIA on Monitor Disconnect'
$install=Get-Content (Join-Path $data 'upgrade-v6.json') -Raw | ConvertFrom-Json
$backup=[IO.Path]::GetFullPath([string]$install.Backup)
if(-not $backup.StartsWith(([IO.Path]::GetFullPath($dest)+'\backup-v5-'),[StringComparison]::OrdinalIgnoreCase)){throw 'Invalid backup path'}
Stop-ScheduledTask -TaskName $taskName
for($i=0;$i -lt 20;$i++){if([string](Get-ScheduledTask -TaskName $taskName).State -ne 'Running'){break};Start-Sleep -Milliseconds 500}
if([string](Get-ScheduledTask -TaskName $taskName).State -eq 'Running'){throw 'Manager has not stopped'}
$key='HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
$previous=@(Get-Content (Join-Path $backup 'preferences-v5.json') -Raw | ConvertFrom-Json)
$touched=@(Get-Content (Join-Path $data 'preferences-before.json') -Raw | ConvertFrom-Json)
foreach($entry in $touched){
 $saved=@($previous | Where-Object Path -eq $entry.Path)
 if($saved.Count){New-ItemProperty -Path $key -Name $entry.Path -Value $saved[0].Value -PropertyType String -Force | Out-Null}
 elseif($entry.Existed){New-ItemProperty -Path $key -Name $entry.Path -Value $entry.Value -PropertyType String -Force | Out-Null}
 else{Remove-ItemProperty -Path $key -Name $entry.Path -ErrorAction SilentlyContinue}
}
Get-ChildItem -LiteralPath $backup -File | Where-Object {$_.Name -notin @('task.xml','preferences-v5.json')} | Copy-Item -Destination $dest -Force
foreach($name in @('mode.json','manual-apps.json','assignments.json','preferences-before.json')){$old=Join-Path $backup ('data\'+$name);if(Test-Path $old){Copy-Item -LiteralPath $old -Destination (Join-Path $data $name) -Force}}
if(Test-Path (Join-Path $data 'command.json')){Remove-Item -LiteralPath (Join-Path $data 'command.json') -Force}
if(Test-Path (Join-Path $backup 'task.xml')){
 Register-ScheduledTask -TaskName $taskName -Xml (Get-Content (Join-Path $backup 'task.xml') -Raw) -Force | Out-Null
 Start-ScheduledTask -TaskName $taskName
 'Previous GPU Manager restored and started. Measurements and history retained.'
}else{
 Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
 $desktop=[Environment]::GetFolderPath('Desktop');$shell=New-Object -ComObject WScript.Shell
 foreach($name in @('GPU - Intel и NVIDIA.lnk','GPU - Инструкция.lnk')){
  $path=Join-Path $desktop $name
  if(Test-Path -LiteralPath $path){$link=$shell.CreateShortcut($path);if($link.TargetPath -eq (Join-Path $dest 'README.txt') -or $link.Arguments -like '*C:\NvidiaReset\GpuControl.ps1*'){Remove-Item -LiteralPath $path -Force}}
 }
 'GPU Manager task and shortcuts removed; preferences restored. Files retained.'
}
