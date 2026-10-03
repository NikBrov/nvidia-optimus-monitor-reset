# Shared v6 policy and user-managed assignments. No user-provided code is executed.
function Get-Options {
 $o=Read-Json (Join-Path $Data 'options.json') $null
 $policy='Auto';if($o -and $o.ResetPolicy -in @('Auto','Ask','Notify')){$policy=[string]$o.ResetPolicy}
 $paths=@();if($o){$paths=@($o.ProtectedPaths | Where-Object {$_ -is [string] -and [IO.Path]::IsPathRooted($_) -and [IO.Path]::GetExtension($_) -eq '.exe'})}
 return [pscustomobject]@{ResetPolicy=$policy;ProtectedPaths=$paths}
}
function Get-ProtectedProcesses {
 $options=Get-Options
 return @(Get-Process -ErrorAction Stop | Where-Object {$Config.ProtectedProcessNames -contains $_.ProcessName -or ($_.Path -and $options.ProtectedPaths -contains $_.Path)} | Select-Object ProcessName,Id,Path)
}
function Get-AppAssignments {
 $items=@{};foreach($a in @(Get-DefaultAssignments)){$items[$a.Path]=$a}
 foreach($a in @(Read-Json (Join-Path $Data 'app-overrides.json') @())){
  if($a.Path -isnot [string] -or -not [IO.Path]::IsPathRooted($a.Path) -or [IO.Path]::GetExtension($a.Path) -ne '.exe'){continue}
  if($a.Disabled){$items.Remove($a.Path);continue}
  if($a.Gpu -in @(0,1,2)){$items[$a.Path]=[pscustomobject]@{Path=[string]$a.Path;Gpu=[int]$a.Gpu}}
 }
 return @($items.Values | Sort-Object Path)
}
function Get-SafeClientPaths($Assignments) {
 $safe=@($Assignments | Where-Object {$_.Gpu -eq 1 -and $Config.ResetTolerantExecutableNames -contains [IO.Path]::GetFileName($_.Path)} | ForEach-Object Path)
 return @($safe)+@("$env:windir\System32\dwm.exe","$env:windir\System32\csrss.exe","$env:windir\explorer.exe")
}
function Set-AppOverride([string]$Path,[string]$Choice) {
 if(-not [IO.Path]::IsPathRooted($Path) -or [IO.Path]::GetExtension($Path) -ne '.exe'){throw 'Выберите полный путь к EXE.'}
 $list=@(Read-Json (Join-Path $Data 'app-overrides.json') @() | Where-Object Path -ne $Path)
 switch($Choice){
  'Remove' {$list += [pscustomobject]@{Path=$Path;Disabled=$true;Gpu=0}}
  'Restore' {
   $original=@(Read-Json (Join-Path $Data 'preferences-before.json') @() | Where-Object Path -eq $Path)
   if(-not $original.Count){throw 'Исходное назначение не сохранено.'}
   $key='HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
   if($original[0].Existed){New-ItemProperty -Path $key -Name $Path -Value $original[0].Value -PropertyType String -Force | Out-Null}else{Remove-ItemProperty -Path $key -Name $Path -ErrorAction SilentlyContinue}
   $list += [pscustomobject]@{Path=$Path;Disabled=$true;Gpu=0}
  }
  default {if($Choice -notin @('0','1','2')){throw 'Неверный выбор GPU'};Set-AppPreference $Path ([int]$Choice);$list += [pscustomobject]@{Path=$Path;Disabled=$false;Gpu=[int]$Choice}}
 }
 Save-Json @($list) (Join-Path $Data 'app-overrides.json')
 Write-GpuLog "APP choice=$Choice path=$Path"
}
function Write-GpuLog([string]$Text) {
 foreach($name in @('GpuManager.log','history.jsonl')){
  $file=Join-Path $Data $name
  if((Test-Path $file) -and (Get-Item $file).Length -gt 2MB){Move-Item -LiteralPath $file -Destination ($file+'.previous') -Force}
  if($name -eq 'history.jsonl'){@{Time=(Get-Date).ToString('o');Message=$Text} | ConvertTo-Json -Compress | Add-Content -LiteralPath $file -Encoding UTF8}
  else {((Get-Date -Format 'yyyy-MM-dd HH:mm:ss')+' '+$Text) | Add-Content -LiteralPath $file -Encoding UTF8}
 }
}
function Get-Diagnosis {
 $paths=@(Get-Topology);$power=[GpuNative]::ReadPower($Config.DeviceId);$clients=@();$errors=@()
 if($power.Power -ne 'D3'){try{$clients=@(Get-GpuClients (Get-NvidiaLuid))}catch{$errors += $_.Exception.Message}}
 $blocked=@(Get-ProtectedProcesses);$apps=@(Get-AppAssignments)
 $decision=Get-ResetDecision 'Auto' $paths $power $blocked $clients (Get-SafeClientPaths $apps) 999999
 if($errors.Count){$decision='ClientQueryError'}
 $why=switch($decision){
  'AlreadyAsleep' {'Windows сообщает D3: NVIDIA в энергосбережении.'}
  'DisplayInUse' {'Внешний экран активен: перезапуск запрещён. Смотрите подключение экранов ниже.'}
  'ProtectedApp' {'Открыта защищённая программа: '+(@($blocked | ForEach-Object ProcessName | Sort-Object -Unique) -join ', ')}
  'UnknownClient' {'На NVIDIA есть клиенты, для которых безопасный сброс не разрешён.'}
  'AllowReset' {'NVIDIA активна; защитные проверки сейчас допускают запрос перезапуска.'}
  default {'Проверка: '+$decision}
 }
 return [pscustomobject]@{Time=(Get-Date).ToString('o');Power=$power;Decision=$decision;Explanation=$why;Clients=$clients;Protected=$blocked;Displays=$paths;Errors=$errors}
}
function Invoke-CheckedGpuRestart {
 $wall=Get-Date;$awake=[GpuNative]::AwakeSeconds()
 Write-GpuLog 'RESET start; awake-time timeout 45 seconds; sleep excluded'
 $proc=Start-Process -FilePath "$env:windir\System32\pnputil.exe" -ArgumentList @('/restart-device',('"'+$Config.DeviceId+'"')) -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $Data 'restart-output.txt') -RedirectStandardError (Join-Path $Data 'restart-error.txt')
 $timedOut=$false
 while(-not $proc.WaitForExit(250)){
  if(([GpuNative]::AwakeSeconds()-$awake) -gt 45){$proc.Kill();$proc.WaitForExit();$timedOut=$true;break}
 }
 $exit=$proc.ExitCode;$state=[GpuNative]::ReadPower($Config.DeviceId)
 if($state.Present -and $state.Problem -eq 22){
  Write-GpuLog 'RECOVERY enabling disabled NVIDIA device'
  $enable=Start-Process -FilePath "$env:windir\System32\pnputil.exe" -ArgumentList @('/enable-device',('"'+$Config.DeviceId+'"')) -WindowStyle Hidden -PassThru
  if(-not $enable.WaitForExit(10000)){throw 'Восстановление устройства ещё выполняется. Проверьте диспетчер устройств.'}
  $state=[GpuNative]::ReadPower($Config.DeviceId)
 }
 $active=[GpuNative]::AwakeSeconds()-$awake;$elapsed=((Get-Date)-$wall).TotalSeconds
 Write-GpuLog ('RESET finished; exit='+$exit+' awake_seconds='+[math]::Round($active,2)+' wall_seconds='+[math]::Round($elapsed,2)+' sleep_or_gap_seconds='+[math]::Round([math]::Max(0,$elapsed-$active),2))
 if($timedOut){throw "Перезапуск превысил 45 секунд активной работы; повтор отменён. Устройство: present=$($state.Present), problem=$($state.Problem)."}
 if($exit -ne 0 -or -not $state.Present -or $state.Problem -ne 0){throw "GPU restart failed or needs reboot: exit=$exit present=$($state.Present) problem=$($state.Problem)"}
 Save-Json @{At=(Get-Date).ToString('o');ExitCode=$exit;AwakeSeconds=$active;WallSeconds=$elapsed} (Join-Path $Data 'last-reset.json')
}
function Get-ClientSignature($Clients){return (@($Clients | ForEach-Object {([string]$_.Id)+':'+$_.Path} | Sort-Object) -join '|')}
function Get-ResetAuthorization([string]$Policy,[bool]$Manual,[bool]$Approved){
 if($Approved){return 'Proceed'}
 if($Manual -or $Policy -eq 'Ask'){return 'Ask'}
 if($Policy -eq 'Notify'){return 'Notify'}
 return 'Proceed'
}
