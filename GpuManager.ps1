param([switch]$AuditOnly,[switch]$ObserveOnly,[int]$ExitAfterSeconds=0)
$ErrorActionPreference='Stop'
. "$PSScriptRoot\GpuCommon.ps1"
. "$PSScriptRoot\GpuBattery.ps1"
New-Item -ItemType Directory -Path $Data -Force | Out-Null
if($AuditOnly) {
 $paths=@(Get-Topology);$power=[GpuNative]::ReadPower($Config.DeviceId);$luid=Get-NvidiaLuid
 $apps=@(Get-AppAssignments);$clients=@(Get-GpuClients $luid);$blocked=@(Get-ProtectedProcesses)
 @{Paths=$paths;Power=$power;Clients=$clients;Protected=$blocked;Decision=(Get-ResetDecision 'Auto' $paths $power $blocked $clients (Get-SafeClientPaths $apps) 9999)} | ConvertTo-Json -Depth 6
 exit
}
$new=$false
$mutexName=if($ObserveOnly){'Local\AcerGpuManagerV6Test'}else{'Local\AcerGpuManagerV6'}
$mutex=New-Object Threading.Mutex($true,$mutexName,[ref]$new)
if(-not $new){$mutex.Dispose();exit}
$script:Tray=$null;$script:Timer=$null;$script:Events=$null
try {
 $identity=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
 if(-not $ObserveOnly -and -not $identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Run GPU Manager using its scheduled task; administrator rights are required for device restart.'}
 $script:Apps=if($ObserveOnly){@(Get-AppAssignments)}else{@(Update-AppPreferences)}
 $script:SafePaths=@(Get-SafeClientPaths $Apps)
 $script:Paths=@(Get-Topology)
 $script:Luid=Get-NvidiaLuid
 $script:PowerLine=[string][Windows.Forms.SystemInformation]::PowerStatus.PowerLineStatus
 $script:Mode='Auto';$script:PinUntil=$null
 $saved=Read-Json (Join-Path $Data 'mode.json') $null
 if($saved -and $saved.Mode -in @('Auto','Battery','Nvidia')){
  $script:Mode=$saved.Mode
  if($Mode -eq 'Nvidia'){
   if($saved.Forever){$script:PinUntil=$null}else{
    try{$script:PinUntil=[datetime]$saved.Until}catch{$script:PinUntil=Get-Date}
    if($PinUntil -le (Get-Date) -or $PinUntil -gt (Get-Date).AddHours(24)){$script:Mode='Auto';$script:PinUntil=$null}
   }
  }
 }
 $script:Pending=$null;$script:Due=Get-Date;$script:Reason='';$script:VerifiedAt=$null;$script:SecondVerifyAt=$null
 $script:Started=Get-Date;$script:LastTopology=Get-Date;$script:LastTick=Get-Date;$script:LastPreferences=Get-Date
 $script:LastStatus='';$script:Busy=$false;$script:SuppressedUntil=Get-Date
 $script:PendingClients=@();$script:PendingBlockers=@();$script:ObservedPower='Unknown'
 $script:Approval=$null;$script:Approved=$null;$script:ManualCheck=$false;$script:BatterySession=$null
 $script:LastAwake=[GpuNative]::AwakeSeconds()
 $staleBattery=Read-Json (Join-Path $Data 'battery-current.json') $null
 if($staleBattery -and -not $staleBattery.Complete){$staleBattery.Complete=$true;$staleBattery.Valid=$false;$staleBattery.EndReason='Наблюдатель был перезапущен; замер прерван';Save-Json $staleBattery (Join-Path $Data 'battery-current.json')}
 $script:Tray=New-Object Windows.Forms.NotifyIcon
 $Tray.Icon=[Drawing.SystemIcons]::Application;$Tray.Text='GPU Manager: '+$Mode;$Tray.Visible=$true
 $menu=New-Object Windows.Forms.ContextMenuStrip
 function Notify([string]$Text){$Tray.BalloonTipTitle='GPU Manager';$Tray.BalloonTipText=$Text;$Tray.ShowBalloonTip(7000)}
 function Set-Status([string]$Text,[bool]$Inform=$false){
  if($script:LastStatus -ne $Text){$script:LastStatus=$Text;Write-GpuLog $Text;if($Inform){Notify $Text}}
  $snapshot=[ordered]@{Time=(Get-Date).ToString('o');Version=6;Mode=$script:Mode;Until=$script:PinUntil;PowerLine=$script:PowerLine;Status=$Text;Pending=$script:Pending;Reason=$script:Reason;GpuPower=$script:ObservedPower;Clients=$script:PendingClients;Blockers=$script:PendingBlockers;Displays=$script:Paths;ProcessId=$PID;Approval=$script:Approval;ResetPolicy=(Get-Options).ResetPolicy}
  Save-Json $snapshot (Join-Path $Data 'status.json')
 }
 function Queue-Check([string]$Reason){
  if($script:Mode -eq 'Nvidia'){return}
  if($script:Pending){return}
  if((Get-Date) -lt $script:SuppressedUntil){return}
  $script:Pending=Get-Date;$script:Reason=$Reason;$script:Due=(Get-Date).AddSeconds($Config.SettleSeconds)
  $script:ManualCheck=$Reason -in @('manual request','legacy manual request');$script:Approval=$null;$script:Approved=$null
  $script:PendingClients=@();$script:PendingBlockers=@();Set-Status ('Проверка после события: '+$Reason)
 }
 function Set-Mode([string]$Value,[int]$Minutes=120){
  if($Value -notin @('Auto','Battery','Nvidia')){return}
  $script:Mode=$Value;$script:PinUntil=$null
  if($Value -eq 'Nvidia'){$script:PinUntil=if($Minutes -eq 0){$null}else{(Get-Date).AddMinutes($Minutes)};$script:Pending=$null}
  $script:Approval=$null;$script:Approved=$null
  Save-Json @{Mode=$Value;Until=$script:PinUntil;Forever=($Value -eq 'Nvidia' -and $Minutes -eq 0)} (Join-Path $Data 'mode.json')
  $Tray.Text='GPU Manager: '+$Value
  Set-Status ('Режим: '+$Value) $true
  if($Value -ne 'Nvidia'){Queue-Check 'mode change'}
 }
 function Add-Menu([string]$Label,[scriptblock]$Action){$item=New-Object Windows.Forms.ToolStripMenuItem($Label);$item.Add_Click($Action);[void]$menu.Items.Add($item)}
 Add-Menu 'Авто' {Set-Mode 'Auto'}
 Add-Menu 'Экономия энергии' {Set-Mode 'Battery'}
 Add-Menu 'Приостановить автосброс: 30 минут' {Set-Mode 'Nvidia' 30}
 Add-Menu 'Приостановить автосброс: 2 часа' {Set-Mode 'Nvidia' 120}
 Add-Menu 'Приостановить до ручного отключения' {Set-Mode 'Nvidia' 0}
 Add-Menu 'Проверить и безопасно освободить GPU' {Queue-Check 'manual request'}
 Add-Menu 'Статус' {Notify $script:LastStatus}
 $Tray.ContextMenuStrip=$menu
 $script:Events=New-Object GpuNative+WatchWindow
 Write-GpuLog ('START v6; mode='+$Mode+'; passive Windows monitoring; no nvidia-smi polling')
 Set-Status 'Наблюдение запущено. При запуске GPU не сбрасывается.'
 $script:Timer=New-Object Windows.Forms.Timer
 $Timer.Interval=3000
 $Timer.Add_Tick({
  if($script:Busy){return};$script:Busy=$true
  try{
   $now=Get-Date
   if($ExitAfterSeconds -gt 0 -and ($now-$script:Started).TotalSeconds -ge $ExitAfterSeconds){[Windows.Forms.Application]::ExitThread();return}
   if($Mode -eq 'Nvidia' -and $PinUntil -and $now -ge $PinUntil){Set-Mode 'Auto'}
   $commandFiles=@();$commandFile=Join-Path $Data 'command.json'
   if(Test-Path $commandFile){$commandFiles += Get-Item -LiteralPath $commandFile}
   $queue=Join-Path $Data 'commands';if(Test-Path $queue){$commandFiles += @(Get-ChildItem -LiteralPath $queue -Filter '*.json' -File | Sort-Object Name | Select-Object -First 20)}
   foreach($file in $commandFiles){
    try{$cmd=Read-Json $file.FullName $null}catch{Write-GpuLog 'Invalid command JSON ignored';continue}finally{Remove-Item -LiteralPath $file.FullName -Force}
    if($cmd.Action -eq 'Mode'){$minutes=120;if($null -ne $cmd.Minutes -and [string]$cmd.Minutes -in @('0','30','120')){$minutes=[int]$cmd.Minutes};Set-Mode ([string]$cmd.Value) $minutes}
    elseif($cmd.Action -eq 'Check'){Queue-Check 'manual request'}
    elseif($cmd.Action -eq 'RefreshPreferences' -and -not $ObserveOnly){$script:Apps=@(Update-AppPreferences);$script:SafePaths=@(Get-SafeClientPaths $Apps);$script:LastPreferences=$now}
    elseif($cmd.Action -eq 'Approve' -and $script:Approval -and $cmd.Value -eq $script:Approval.Id -and $now -lt [datetime]$script:Approval.Expires){$script:Approved=$script:Approval;$script:Approval=$null;$script:Due=$now}
    elseif($cmd.Action -eq 'Dismiss' -and $script:Approval -and $cmd.Value -eq $script:Approval.Id){$script:Pending=$null;$script:Approval=$null;Set-Status 'Перезапуск отменён пользователем.'}
    elseif($cmd.Action -eq 'Options'){Set-Status 'Настройки защиты обновлены.'}
    elseif($cmd.Action -eq 'BatteryStart'){if([string]$cmd.Minutes -in @('5','10')){Start-BatterySession ([int]$cmd.Minutes) ([string]$cmd.Label)}}
    elseif($cmd.Action -eq 'BatteryStop'){Stop-BatterySession 'Остановлено пользователем' $false}
   }
   # Legacy safe request file remains accepted; no direct/unchecked BAT reset.
   if(Test-Path (Join-Path $Root 'RequestReset.flag')){Remove-Item -LiteralPath (Join-Path $Root 'RequestReset.flag') -Force;Queue-Check 'legacy manual request'}
   $powerNow=[string][Windows.Forms.SystemInformation]::PowerStatus.PowerLineStatus
   if($powerNow -ne $script:PowerLine){$script:PowerLine=$powerNow;if($powerNow -eq 'Offline'){Queue-Check 'battery power'}}
   $resumed=$Events.Resumed -or (($now-$script:LastTick).TotalSeconds -gt 30)
   $awakeNow=[GpuNative]::AwakeSeconds();$gap=[math]::Max(0,($now-$script:LastTick).TotalSeconds-($awakeNow-$script:LastAwake));$script:LastAwake=$awakeNow
   if($resumed -or $Events.Suspended){
    Write-GpuLog ('RESUME/suspend gap_seconds='+[math]::Round($gap,1)+'; old pending request cancelled')
    $script:Pending=$null;$script:Approval=$null;$script:Approved=$null;$script:Due=$now.AddSeconds($Config.SettleSeconds)
    if($script:BatterySession){Stop-BatterySession 'Сон или длительный перерыв в измерении; результат не сравнивать' $false}
    $Events.Suspended=$false
   }
   $script:LastTick=$now
   if($Events.DisplayChanged -or $resumed -or ($now-$script:LastTopology).TotalSeconds -ge 30){
    $old=@($script:Paths);$fresh=@(Get-Topology)
    $changed=(@($old | ForEach-Object Key | Sort-Object) -join ',') -ne (@($fresh | ForEach-Object Key | Sort-Object) -join ',')
    $script:Paths=$fresh;$script:LastTopology=$now;$Events.DisplayChanged=$false;$Events.Resumed=$false
    if($changed){
     $script:Luid=Get-NvidiaLuid
     Write-GpuLog ('DISPLAY '+($fresh | ConvertTo-Json -Compress))
     if(@($fresh | Where-Object {-not $_.Internal -or $_.Nvidia}).Count -gt 0){$script:Pending=$null;Set-Status 'Подключён внешний экран: автосброс запрещён.'}
     elseif(@($old | Where-Object {-not $_.Internal}).Count -gt 0){Queue-Check 'external display disconnected'}
     elseif($script:Pending){$script:Due=$now.AddSeconds($Config.SettleSeconds)}
    }
    if($resumed){$script:Luid=Get-NvidiaLuid;if($PowerLine -eq 'Offline' -or $Mode -eq 'Battery'){Queue-Check 'resume'}}
   }
   if(-not $ObserveOnly -and ($now-$script:LastPreferences).TotalHours -ge 24){$script:Apps=@(Update-AppPreferences);$script:SafePaths=@(Get-SafeClientPaths $Apps);$script:LastPreferences=$now}
   Update-BatterySession
   if($script:Approval -and $now -ge [datetime]$script:Approval.Expires){$script:Approval=$null;$script:Pending=$null;Set-Status 'Подтверждение истекло; повторите ручную проверку.'}
   if(($script:VerifiedAt -and $now -ge $script:VerifiedAt) -or ($script:SecondVerifyAt -and $now -ge $script:SecondVerifyAt)){
    $state=[GpuNative]::ReadPower($Config.DeviceId);$script:ObservedPower=$state.Power
    Write-GpuLog "VERIFY passive power=$($state.Power) problem=$($state.Problem); not a watt measurement"
    if($script:VerifiedAt -and $now -ge $script:VerifiedAt){$script:VerifiedAt=$null}else{$script:SecondVerifyAt=$null}
    if($state.Power -eq 'D3'){Set-Status 'Windows сообщает D3: NVIDIA перешла в энергосбережение.' $true}
    elseif(-not $script:SecondVerifyAt){Set-Status 'GPU перезапущена, но Windows сообщает D0. Повторного сброса не будет; нужна диагностика удерживающих программ.' $true}
   }
   if($script:Pending -and $now -ge $script:Due){
    if($script:BatterySession){$script:Due=$now.AddSeconds(30);Set-Status 'Замер батареи: автоматический сброс приостановлен.';return}
    if($script:Approval){return}
    if(($now-$script:Pending).TotalMinutes -ge $Config.PendingLifetimeMinutes){$script:Pending=$null;Set-Status 'Проверка истекла через 30 минут. Можно повторить вручную.' $true;return}
    $paths=@(Get-Topology);$script:Paths=$paths;$state=[GpuNative]::ReadPower($Config.DeviceId);$script:ObservedPower=$state.Power
    $script:SafePaths=@(Get-SafeClientPaths $Apps)
    $protected=@(Get-ProtectedProcesses);$script:PendingBlockers=@($protected | ForEach-Object ProcessName | Sort-Object -Unique)
    $last=Read-Json (Join-Path $Data 'last-reset.json') $null;$seconds=999999
    if($last){$seconds=($now-[datetime]$last.At).TotalSeconds}
    # Evaluate cheap gates first. Read Windows GPU clients only when eligible.
    $decision=Get-ResetDecision $Mode $paths $state $protected @() $SafePaths $seconds
    $clients=@()
    if($decision -eq 'AllowReset'){$script:Luid=Get-NvidiaLuid;$clients=@(Get-GpuClients $script:Luid);$script:PendingClients=$clients;$decision=Get-ResetDecision $Mode $paths $state $protected $clients $SafePaths $seconds}
    $script:Due=$now.AddSeconds(30)
    switch($decision){
     'AllowReset' {
      $signature=Get-ClientSignature $clients
      $approved=$script:Approved -and $now -lt [datetime]$script:Approved.Expires -and $script:Approved.Signature -eq $signature
      $authorization=Get-ResetAuthorization (Get-Options).ResetPolicy $script:ManualCheck ([bool]$approved)
      if($authorization -eq 'Notify'){$script:Pending=$null;Set-Status 'NVIDIA активна. Только уведомление: откройте панель и запросите проверку вручную.' $true;break}
      if($authorization -eq 'Ask'){
       $script:Approval=[pscustomobject]@{Id=[guid]::NewGuid().ToString('N');Expires=$now.AddSeconds(90).ToString('o');Signature=$signature;Clients=$clients}
       Set-Status 'Нужно подтверждение перезапуска. Откройте панель GPU; запрос действует 90 секунд.' $true;break
      }
      # A second immediate read narrows the race with a newly attached screen/app.
      $againClients=@(Get-GpuClients $script:Luid)
      $again=Get-ResetDecision $Mode @(Get-Topology) ([GpuNative]::ReadPower($Config.DeviceId)) @(Get-ProtectedProcesses) $againClients $SafePaths $seconds
      if($again -ne 'AllowReset'){Set-Status ('Отложено при повторной проверке: '+$again) $true;break}
      if($approved -and (Get-ClientSignature $againClients) -ne $signature){$script:Approved=$null;Set-Status 'Клиенты GPU изменились: необходимо новое подтверждение.' $true;break}
      $script:Pending=$null;$script:Approved=$null;$script:SuppressedUntil=$now.AddSeconds(90)
      if($ObserveOnly){Set-Status 'DRY_RUN: reset would be allowed; no changes made.';break}
      Write-GpuLog ('RESET allowed reason='+$Reason+' clients='+($clients | ConvertTo-Json -Compress))
      Invoke-CheckedGpuRestart
      $script:Luid=Get-NvidiaLuid;$script:Paths=@(Get-Topology)
      $script:VerifiedAt=(Get-Date).AddSeconds(20);$script:SecondVerifyAt=(Get-Date).AddSeconds(60)
      Set-Status 'NVIDIA перезапущена. Проверяю энергосостояние без опроса NVIDIA.' $true
     }
     'AlreadyAsleep' {$script:Pending=$null;Set-Status 'Windows сообщает D3: сброс NVIDIA не нужен.'}
     'ProtectedApp' {Set-Status ('Ожидаю закрытия рабочих приложений: '+($script:PendingBlockers -join ', ')) $true}
     'UnknownClient' {$names=@($clients | Where-Object {$SafePaths -notcontains $_.Path} | ForEach-Object Name | Sort-Object -Unique);Set-Status ('Автосброс отложен: неизвестные клиенты GPU — '+($names -join ', ')) $true}
     'Cooldown' {Set-Status 'Пауза после предыдущего сброса: не менее 5 минут.'}
     default {$script:Pending=$null;Set-Status ('Сброс отменён: '+$decision) $true}
    }
   }
  }catch{$script:Pending=$null;$script:Approval=$null;Write-GpuLog ('ERROR '+$_.Exception.Message);Set-Status ('Ошибка; действие отменено: '+$_.Exception.Message) $true}
  finally{$script:Busy=$false}
 })
 $Timer.Start();[Windows.Forms.Application]::Run()
}catch{Write-GpuLog ('FATAL '+$_.Exception.Message);exit 1}
finally{if($script:BatterySession){Stop-BatterySession 'Наблюдатель остановлен' $false};if($Timer){$Timer.Stop();$Timer.Dispose()};if($Tray){$Tray.Visible=$false;$Tray.Dispose()};if($Events){$Events.Dispose()};$mutex.ReleaseMutex();$mutex.Dispose()}
