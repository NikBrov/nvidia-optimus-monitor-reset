$ErrorActionPreference='Stop'
$dest='C:\NvidiaReset';$taskName='Auto Reset NVIDIA on Monitor Disconnect'
$result=Join-Path $PSScriptRoot 'deploy-v6-result.json';$backup=$null;$stopped=$false;$registered=$false
try{
 $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
 $principal=[Security.Principal.WindowsPrincipal]::new($identity)
 if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Administrator rights required'}
 $oldTask=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
 # Validate the source configuration and hardware before touching the live installation.
 . "$PSScriptRoot\GpuCommon.ps1"
 $devices=@(Get-PnpDevice -Class Display -PresentOnly | Where-Object {$_.InstanceId -like 'PCI\VEN_10DE*' -and $_.InstanceId -eq $Config.DeviceId})
 if($devices.Count -ne 1){throw 'Configured DeviceId is not a present NVIDIA display adapter'}
 [void](Get-NvidiaLuid)
 $resolvedConfig=$Config
 New-Item -ItemType Directory -Path $dest -Force | Out-Null
 $backup=Join-Path $dest ('backup-v5-'+(Get-Date -Format 'yyyyMMdd-HHmmss'))
 New-Item -ItemType Directory -Path $backup | Out-Null
 if($oldTask){Export-ScheduledTask -TaskName $taskName | Set-Content (Join-Path $backup 'task.xml') -Encoding Unicode}
 Get-ChildItem -LiteralPath $dest -File | Copy-Item -Destination $backup
 if(Test-Path (Join-Path $dest 'data')){Copy-Item -LiteralPath (Join-Path $dest 'data') -Destination (Join-Path $backup 'data') -Recurse}
 $key=Get-Item 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences' -ErrorAction SilentlyContinue
 $preferences=@();if($key){$preferences=@($key.GetValueNames() | ForEach-Object {[pscustomobject]@{Path=$_;Value=$key.GetValue($_)}})}
 ConvertTo-Json -InputObject $preferences -Depth 4 | Set-Content (Join-Path $backup 'preferences-v5.json') -Encoding UTF8
 if($oldTask){
  Stop-ScheduledTask -TaskName $taskName;$stopped=$true
  for($i=0;$i -lt 20;$i++){if([string](Get-ScheduledTask -TaskName $taskName).State -ne 'Running'){break};Start-Sleep -Milliseconds 500}
  if([string](Get-ScheduledTask -TaskName $taskName).State -eq 'Running'){throw 'Previous manager did not stop'}
 }
 foreach($file in @('GpuNative.cs','GpuCommon.ps1','GpuV6.ps1','GpuBattery.ps1','GpuManager.ps1','GpuControl.ps1','rollback-v6.ps1','README.txt')){Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination (Join-Path $dest $file) -Force}
 $configFile=Join-Path $dest 'config.json'
 if(Test-Path $configFile){$resolvedConfig=Get-Content $configFile -Raw | ConvertFrom-Json;$resolvedConfig.Version=6}
 $resolvedConfig | ConvertTo-Json -Depth 8 | Set-Content $configFile -Encoding UTF8
 $data=Join-Path $dest 'data';New-Item -ItemType Directory -Path $data -Force | Out-Null
 # Elevated code is read-only to ordinary users. Writable state never contains executable code.
 $acl=New-Object Security.AccessControl.DirectorySecurity;$acl.SetAccessRuleProtection($true,$false)
 foreach($sid in @('S-1-5-32-544','S-1-5-18')){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),'FullControl','ContainerInherit,ObjectInherit','None','Allow'))}
 $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-5-32-545'),'ReadAndExecute','ContainerInherit,ObjectInherit','None','Allow'));Set-Acl -LiteralPath $dest -AclObject $acl
 $stateAcl=Get-Acl $data;$stateAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($identity.User,'Modify','ContainerInherit,ObjectInherit','None','Allow'));Set-Acl -LiteralPath $data -AclObject $stateAcl
 @{Backup=$backup;Installed=(Get-Date).ToString('o');Version=6;Fresh=(-not [bool]$oldTask)} | ConvertTo-Json | Set-Content (Join-Path $data 'upgrade-v6.json') -Encoding UTF8
 if(-not(Test-Path (Join-Path $data 'mode.json'))){@{Mode='Auto';Until=$null} | ConvertTo-Json | Set-Content (Join-Path $data 'mode.json') -Encoding UTF8}
 if(-not(Test-Path (Join-Path $data 'options.json'))){@{ResetPolicy='Auto';ProtectedPaths=@()} | ConvertTo-Json | Set-Content (Join-Path $data 'options.json') -Encoding UTF8}
 if(Test-Path (Join-Path $data 'command.json')){Remove-Item -LiteralPath (Join-Path $data 'command.json') -Force}
 $queue=Join-Path $data 'commands';if(Test-Path $queue){Get-ChildItem -LiteralPath $queue -Filter '*.json' -File | Remove-Item -Force}
 $exe='C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
 $taskPrincipal=New-ScheduledTaskPrincipal -UserId $identity.User.Value -LogonType Interactive -RunLevel Highest
 $action=New-ScheduledTaskAction -Execute $exe -Argument '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\NvidiaReset\GpuManager.ps1"' -WorkingDirectory $dest
 $trigger=New-ScheduledTaskTrigger -AtLogOn -User $identity.User.Value
 $settings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([timespan]::Zero) -MultipleInstances IgnoreNew -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
 Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $taskPrincipal -Description 'GPU Manager v6: guarded NVIDIA restart, app preferences, history and battery measurements.' -Force | Out-Null;$registered=$true
 . (Join-Path $dest 'GpuCommon.ps1');$apps=@(Update-AppPreferences)
 $ws=New-Object -ComObject WScript.Shell;$desktop=[Environment]::GetFolderPath('Desktop')
 $link=$ws.CreateShortcut((Join-Path $desktop 'GPU - Intel и NVIDIA.lnk'));$link.TargetPath=$exe;$link.Arguments='-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\NvidiaReset\GpuControl.ps1"';$link.WorkingDirectory=$dest;$link.IconLocation="$env:windir\System32\shell32.dll,16";$link.Save()
 $link=$ws.CreateShortcut((Join-Path $desktop 'GPU - Инструкция.lnk'));$link.TargetPath=Join-Path $dest 'README.txt';$link.WorkingDirectory=$dest;$link.IconLocation="$env:windir\System32\notepad.exe,0";$link.Save()
 $safeBat='@echo off'+"`r`n"+'start "" "'+$exe+'" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\NvidiaReset\GpuControl.ps1" -Action Check'+"`r`n"
 foreach($name in @('Request_Reset_Now.bat','Reset_NVIDIA_GPU.bat')){[IO.File]::WriteAllText((Join-Path $dest $name),$safeBat,[Text.Encoding]::ASCII)}
 Start-ScheduledTask -TaskName $taskName;Start-Sleep -Seconds 4
 if([string](Get-ScheduledTask -TaskName $taskName).State -ne 'Running'){throw 'New task did not stay running'}
 @{Success=$true;Backup=$backup;Version=6;Assignments=$apps.Count} | ConvertTo-Json | Set-Content $result -Encoding UTF8
}catch{
 $message=$_.Exception.Message
 if($backup -and ($stopped -or $registered)){
  Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
  # Undo any preferences applied before a partial installation failure.
  $registry='HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
  $originalsFile=Join-Path $dest 'data\preferences-before.json'
  if(Test-Path $originalsFile){
   $snapshot=@(Get-Content (Join-Path $backup 'preferences-v5.json') -Raw | ConvertFrom-Json)
   foreach($entry in @(Get-Content $originalsFile -Raw | ConvertFrom-Json)){
    $saved=@($snapshot | Where-Object Path -eq $entry.Path)
    if($saved.Count){New-ItemProperty -Path $registry -Name $entry.Path -Value $saved[0].Value -PropertyType String -Force | Out-Null}
    elseif($entry.Existed){New-ItemProperty -Path $registry -Name $entry.Path -Value $entry.Value -PropertyType String -Force | Out-Null}
    else{Remove-ItemProperty -Path $registry -Name $entry.Path -ErrorAction SilentlyContinue}
   }
  }
  Get-ChildItem -LiteralPath $backup -File | Where-Object {$_.Name -notin @('task.xml','preferences-v5.json')} | Copy-Item -Destination $dest -Force
  if(Test-Path (Join-Path $backup 'task.xml')){Register-ScheduledTask -TaskName $taskName -Xml (Get-Content (Join-Path $backup 'task.xml') -Raw) -Force | Out-Null;Start-ScheduledTask -TaskName $taskName}
  elseif($registered){Unregister-ScheduledTask -TaskName $taskName -Confirm:$false}
 }
 @{Success=$false;Error=$message;Backup=$backup} | ConvertTo-Json | Set-Content $result -Encoding UTF8
 exit 1
}
