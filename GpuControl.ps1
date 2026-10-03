param([ValidateSet('Panel','Auto','Battery','Nvidia','Check')][string]$Action='Panel',[string]$PreviewPath='',[int]$AutoCloseSeconds=0)
$ErrorActionPreference='Stop'
. "$PSScriptRoot\GpuCommon.ps1"
New-Item -ItemType Directory -Path $Data -Force | Out-Null
function Send-Command([string]$Action,[string]$Value='',[int]$Minutes=120,[string]$Label='') {
 $folder=Join-Path $Data 'commands';New-Item -ItemType Directory -Path $folder -Force | Out-Null
 Save-Json @{Action=$Action;Value=$Value;Minutes=$Minutes;Label=$Label} (Join-Path $folder ((Get-Date -Format 'yyyyMMddHHmmssfffffff')+'-'+[guid]::NewGuid().ToString('N')+'.json'))
}
if($Action -ne 'Panel'){if($Action -eq 'Check'){Send-Command 'Check'}else{Send-Command 'Mode' $Action};exit}
$principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){[Windows.Forms.MessageBox]::Show('Откройте панель обычным двойным щелчком, без запуска от администратора.','GPU Manager') | Out-Null;exit}
$form=New-Object Windows.Forms.Form
$form.Text='GPU Manager v6 — Intel / NVIDIA';$form.Size=New-Object Drawing.Size(1050,760);$form.MinimumSize=$form.Size;$form.StartPosition='CenterScreen';$form.Font=New-Object Drawing.Font('Segoe UI',10);$form.AutoScaleMode='Dpi'
$tabs=New-Object Windows.Forms.TabControl;$tabs.Dock='Fill';$form.Controls.Add($tabs)
function Tab([string]$Title){$p=New-Object Windows.Forms.TabPage;$p.Text=$Title;$p.AutoScroll=$true;[void]$tabs.TabPages.Add($p);return $p}
function Label($Parent,[string]$Text,[int]$X,[int]$Y,[int]$Width,[int]$Height=40){$c=New-Object Windows.Forms.Label;$c.Text=$Text;$c.Location=New-Object Drawing.Point($X,$Y);$c.Size=New-Object Drawing.Size($Width,$Height);$Parent.Controls.Add($c);return $c}
function Button($Parent,[string]$Text,[int]$X,[int]$Y,[int]$Width,[scriptblock]$Handler){$c=New-Object Windows.Forms.Button;$c.Text=$Text;$c.Location=New-Object Drawing.Point($X,$Y);$c.Size=New-Object Drawing.Size($Width,40);$c.Add_Click({try{& $Handler}catch{[Windows.Forms.MessageBox]::Show($_.Exception.Message,'GPU Manager') | Out-Null}}.GetNewClosure());$Parent.Controls.Add($c);return $c}
function TextBox($Parent,[int]$X,[int]$Y,[int]$Width,[int]$Height,[bool]$ReadOnly=$false){$c=New-Object Windows.Forms.TextBox;$c.Location=New-Object Drawing.Point($X,$Y);$c.Size=New-Object Drawing.Size($Width,$Height);$c.Multiline=$true;$c.ReadOnly=$ReadOnly;$c.ScrollBars='Vertical';$Parent.Controls.Add($c);return $c}
function Combo($Parent,[string[]]$Items,[int]$X,[int]$Y,[int]$Width){$c=New-Object Windows.Forms.ComboBox;$c.DropDownStyle='DropDownList';$c.Location=New-Object Drawing.Point($X,$Y);$c.Width=$Width;$c.Items.AddRange($Items);$c.SelectedIndex=0;$Parent.Controls.Add($c);return $c}
function Grid($Parent,[string[]]$Columns,[int]$X,[int]$Y,[int]$Width,[int]$Height){$c=New-Object Windows.Forms.DataGridView;$c.Location=New-Object Drawing.Point($X,$Y);$c.Size=New-Object Drawing.Size($Width,$Height);$c.ReadOnly=$true;$c.AllowUserToAddRows=$false;$c.AllowUserToDeleteRows=$false;$c.RowHeadersVisible=$false;$c.SelectionMode='FullRowSelect';$c.MultiSelect=$false;$c.AutoSizeColumnsMode='Fill';foreach($name in $Columns){[void]$c.Columns.Add($name,$name)};$Parent.Controls.Add($c);return $c}
function Choose-Exe {$d=New-Object Windows.Forms.OpenFileDialog;$d.Filter='Программы (*.exe)|*.exe';try{if($d.ShowDialog() -eq 'OK'){return $d.FileName}}finally{$d.Dispose()};return $null}
function Gpu-Name([int]$Value){switch($Value){0{'Выбор Windows'}1{'Intel'}2{'NVIDIA'}}}
function Refresh-Apps {
 $appsGrid.Rows.Clear();$key=Get-Item 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences' -ErrorAction SilentlyContinue
 foreach($a in @(Get-AppAssignments)){
  $actual=if($key){[string]$key.GetValue($a.Path)}else{''};$match=$actual -match ('GpuPreference='+$a.Gpu+';')
  $idx=$appsGrid.Rows.Add([IO.Path]::GetFileName($a.Path),(Gpu-Name $a.Gpu),$(if($match){'Сохранено'}else{'Ожидает применения / отличается'}),$a.Path)
  $appsGrid.Rows[$idx].Tag=$a.Path
 }
}
function Selected-App {if(-not $appsGrid.SelectedRows.Count){throw 'Выберите приложение в списке.'};return [string]$appsGrid.SelectedRows[0].Tag}
function Refresh-Protected {
 $protectedGrid.Rows.Clear()
 foreach($name in @($Config.ProtectedProcessNames)){[void]$protectedGrid.Rows.Add($name,'Встроенная защита')}
 foreach($path in @((Get-Options).ProtectedPaths)){$i=$protectedGrid.Rows.Add($path,'Ваша защита');$protectedGrid.Rows[$i].Tag=$path}
}
function Save-Options {
 $o=Get-Options;$o.ResetPolicy=@('Auto','Ask','Notify')[$policy.SelectedIndex];Save-Json $o (Join-Path $Data 'options.json');Send-Command 'Options'
 Write-GpuLog ('OPTIONS reset_policy='+$o.ResetPolicy)
}
function Refresh-History {
 $history.Text='';$file=Join-Path $Data 'GpuManager.log';if(Test-Path $file){$history.Lines=[string[]]@(Get-Content -LiteralPath $file -Tail 200);$history.SelectionStart=$history.TextLength;$history.ScrollToCaret()}
}
function Diagnostic-Text($d){
 $lines=@('Проверено: '+$d.Time,$d.Explanation,'Состояние NVIDIA: '+$d.Power.Power+'; код проблемы: '+$d.Power.Problem,'','Экраны:')
 foreach($p in @($d.Displays)){$lines += $p.Monitor+' — '+$p.Technology+' — '+$(if($p.Nvidia){'NVIDIA'}else{'Intel / другой адаптер'})}
 $lines += @('','Клиенты NVIDIA (выделенная память, а не доказательство текущей нагрузки):')
 foreach($c in @($d.Clients)){$lines += $c.Name+' (PID '+$c.Id+') — '+$c.Path}
 if(-not @($d.Clients).Count){$lines += 'Нет обнаруженных клиентов; это не доказывает причину активности GPU.'}
 foreach($e in @($d.Errors)){$lines += 'Ошибка диагностики: '+$e}
 return ($lines -join "`r`n")
}
$main=Tab 'Режим и состояние'
[void](Label $main 'Intel — для обычной работы, NVIDIA — для 3D и видео. Закрытие панели не останавливает наблюдатель.' 18 16 970 35)
$status=TextBox $main 18 55 970 155 $true
[void](Button $main 'Авто' 18 225 155 {Send-Command 'Mode' 'Auto'})
[void](Button $main 'Экономия энергии' 188 225 190 {Send-Command 'Mode' 'Battery'})
$pause=Combo $main @('30 минут','2 часа','До ручного отключения') 396 232 220
[void](Button $main 'Приостановить автосброс' 637 225 350 {Send-Command 'Mode' 'Nvidia' (@(30,120,0)[$pause.SelectedIndex])})
[void](Label $main 'Авто: проверка после отключения экрана, перехода на батарею и пробуждения на батарее. Экономия: также после пробуждения от сети. Пауза: временно запрещает сброс, выбор GPU не меняет.' 18 279 970 55)
[void](Button $main 'Проверить и запросить перезапуск…' 18 344 460 {Send-Command 'Check'})
[void](Button $main 'Выбрать приложение для NVIDIA и запустить…' 495 344 492 {$path=Choose-Exe;if($path){Set-AppOverride $path '2';Send-Command 'RefreshPreferences';Send-Command 'Mode' 'Nvidia' 120;Start-Process -FilePath $path -WorkingDirectory (Split-Path $path);Refresh-Apps}})
[void](Button $main 'Обновить диагностику' 18 397 300 {$script:Diagnosis=Get-Diagnosis;$diagnosis.Text=Diagnostic-Text $script:Diagnosis})
[void](Button $main 'Настройки графики Windows' 336 397 320 {Start-Process 'ms-settings:display-advancedgraphics'})
[void](Button $main 'Открыть инструкцию' 674 397 313 {Start-Process -FilePath (Join-Path $PSScriptRoot 'README.txt')})
$diagnosis=TextBox $main 18 452 970 185 $true
$diagnosis.Text='Нажмите «Обновить диагностику», чтобы увидеть экраны и клиентов NVIDIA. Постоянный опрос GPU не выполняется.'
[void](Label $main 'D0 — активное состояние; D3 — энергосбережение. Показано последнее чтение Windows, а не расход в ваттах.' 18 647 970 35)
$appTab=Tab 'Приложения'
[void](Label $appTab 'Назначения сохраняются. После изменения перезапустите приложение. Ваш выбор имеет приоритет над исходным списком менеджера.' 18 16 970 45)
$appsGrid=Grid $appTab @('Программа','GPU','Назначение Windows','Путь') 18 70 970 420
$appsGrid.Columns[3].FillWeight=230
$gpuChoice=Combo $appTab @('Выбор Windows','Intel','NVIDIA') 18 510 190
[void](Button $appTab 'Применить к выбранной' 225 502 250 {Set-AppOverride (Selected-App) ([string]$gpuChoice.SelectedIndex);Send-Command 'RefreshPreferences';Refresh-Apps})
[void](Button $appTab 'Добавить EXE…' 493 502 220 {$p=Choose-Exe;if($p){Set-AppOverride $p ([string]$gpuChoice.SelectedIndex);Send-Command 'RefreshPreferences';Refresh-Apps}})
[void](Button $appTab 'Обновить список' 730 502 258 {Refresh-Apps})
[void](Button $appTab 'Удалить из управления' 18 560 310 {Set-AppOverride (Selected-App) 'Remove';Send-Command 'RefreshPreferences';Refresh-Apps})
[void](Button $appTab 'Вернуть исходное назначение' 346 560 370 {Set-AppOverride (Selected-App) 'Restore';Send-Command 'RefreshPreferences';Refresh-Apps})
[void](Label $appTab 'Удаление оставляет текущее назначение Windows. Возврат восстанавливает значение до первого изменения менеджером и прекращает управление этой программой.' 18 616 970 55)
$protectTab=Tab 'Защита и сброс'
[void](Label $protectTab 'Поведение при безопасной возможности автоматического сброса:' 18 18 960 30)
$policy=Combo $protectTab @('Автоматически после защитных проверок','Спрашивать перед сбросом','Только уведомлять') 18 60 680
$policy.SelectedIndex=[array]::IndexOf(@('Auto','Ask','Notify'),(Get-Options).ResetPolicy)
[void](Button $protectTab 'Сохранить' 718 53 270 {Save-Options})
[void](Label $protectTab 'Ручной запрос всегда требует подтверждения. В режиме «Спрашивать» откройте панель: запрос действует 90 секунд. Подтверждение не отменяет защитные проверки.' 18 111 970 55)
$protectedGrid=Grid $protectTab @('Программа / путь','Тип защиты') 18 183 970 340
[void](Button $protectTab 'Защитить приложение…' 18 542 460 {$p=Choose-Exe;if($p){$o=Get-Options;$o.ProtectedPaths=@($o.ProtectedPaths)+@($p) | Sort-Object -Unique;Save-Json $o (Join-Path $Data 'options.json');Send-Command 'Options';Refresh-Protected}})
[void](Button $protectTab 'Удалить выбранную свою защиту' 496 542 492 {if(-not $protectedGrid.SelectedRows.Count -or -not $protectedGrid.SelectedRows[0].Tag){throw 'Встроенная защита не удаляется из панели. Выберите свою запись.'};$p=[string]$protectedGrid.SelectedRows[0].Tag;$o=Get-Options;$o.ProtectedPaths=@($o.ProtectedPaths | Where-Object {$_ -ne $p});Save-Json $o (Join-Path $Data 'options.json');Send-Command 'Options';Refresh-Protected})
[void](Label $protectTab 'Пока защищённая программа открыта, перезапуск запрещён. Активный внешний экран, неизвестные клиенты GPU и ошибки устройства также блокируют сброс. При перезапуске экран может мигнуть, графические ресурсы программ могут прерваться.' 18 601 970 65)
$historyTab=Tab 'История и отчёт'
[void](Label $historyTab 'Последние 200 записей. Время активной работы и время сна при перезапуске учитываются отдельно.' 18 16 970 35)
$history=TextBox $historyTab 18 63 970 525 $true
[void](Button $historyTab 'Обновить историю' 18 609 300 {Refresh-History})
[void](Button $historyTab 'Сохранить отчёт диагностики…' 336 609 652 {
 $d=New-Object Windows.Forms.SaveFileDialog;$d.Filter='Отчёт JSON (*.json)|*.json';$d.FileName='GPU-report-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.json'
 try{if($d.ShowDialog() -eq 'OK'){$measurements=@();$folder=Join-Path $Data 'measurements';if(Test-Path $folder){$measurements=@(Get-ChildItem $folder -Filter '*.json' | Sort-Object LastWriteTime -Descending | Select-Object -First 20 | ForEach-Object {Read-Json $_.FullName $null})};$report=@{Version=6;Time=(Get-Date).ToString('o');Status=(Read-Json (Join-Path $Data 'status.json') $null);Diagnosis=(Get-Diagnosis);Options=(Get-Options);Assignments=@(Get-AppAssignments);History=$history.Text;Measurements=$measurements};Save-Json $report $d.FileName;[Windows.Forms.MessageBox]::Show('Отчёт сохранён. Он содержит пути приложений и историю событий.','GPU Manager') | Out-Null}}finally{$d.Dispose()}
})
$batteryTab=Tab 'Замер батареи'
[void](Label $batteryTab 'Отключите зарядку. Для сравнения оставьте одинаковые яркость, приложения и нагрузку. Во время замера автоматические сбросы приостановлены; сон или подключение зарядки прерывают замер.' 18 16 970 60)
$duration=Combo $batteryTab @('5 минут','10 минут') 18 91 150
[void](Label $batteryTab 'Название / условия:' 190 92 175 30)
$measurementLabel=TextBox $batteryTab 370 87 618 35;$measurementLabel.Multiline=$false;$measurementLabel.Text='Обычная работа'
[void](Button $batteryTab 'Начать замер' 18 141 300 {Send-Command 'BatteryStart' '' (@(5,10)[$duration.SelectedIndex]) $measurementLabel.Text})
[void](Button $batteryTab 'Остановить' 336 141 300 {Send-Command 'BatteryStop'})
[void](Button $batteryTab 'Обновить результаты' 654 141 334 {Refresh-Measurements})
$batteryStatus=TextBox $batteryTab 18 200 970 110 $true
$measureGrid=Grid $batteryTab @('Дата / название','Минуты','Средний расход, Вт','CPU, %','D3 / отсчёты','Пригодность') 18 330 970 255
[void](Label $batteryTab 'Расход — всего ноутбука по данным батареи, не одной NVIDIA. Отсчёты раз в 15 секунд. Сравнивайте завершённые замеры с похожей CPU-нагрузкой; короткий замер не доказывает причину экономии.' 18 605 970 65)
function Refresh-Measurements {
 $measureGrid.Rows.Clear();$folder=Join-Path $Data 'measurements';if(Test-Path $folder){foreach($f in @(Get-ChildItem $folder -Filter '*.json' | Sort-Object LastWriteTime -Descending | Select-Object -First 40)){$m=Read-Json $f.FullName $null;if($m.Summary){[void]$measureGrid.Rows.Add($m.Started+' / '+$m.Label,[math]::Round($m.Summary.DurationSeconds/60,1),$m.Summary.MeanDischargeWatts,$m.Summary.MeanCpuPercent,($m.Summary.D3Samples.ToString()+' / '+$m.Summary.Samples),$(if($m.Valid){'Завершён'}else{'Прерван: '+$m.EndReason}))}}}
}
$script:SeenApprovals=@{};$script:Started=Get-Date
function Refresh-Status {
 try{
  $s=Read-Json (Join-Path $Data 'status.json') $null
  if(-not $s){$status.Text='Нет статуса наблюдателя. Он запускается при входе в Windows.';return}
  $alive=Get-Process -Id $s.ProcessId -ErrorAction SilentlyContinue
  $modeName=switch($s.Mode){'Auto'{'Авто'}'Battery'{'Экономия энергии'}'Nvidia'{'Автосброс приостановлен'}}
  $remaining='';if($s.Mode -eq 'Nvidia'){$remaining=if($s.Until){'Осталось: '+[math]::Max(0,[math]::Ceiling(([datetime]$s.Until-(Get-Date)).TotalMinutes))+' мин.'}else{'До ручного отключения'}}
  $status.Text='Наблюдатель: '+$(if($alive){'работает'}else{'не запущен'})+"`r`nРежим: "+$modeName+' '+$remaining+"`r`n"+$s.Status+"`r`nПоследнее событие: "+$s.Time+"`r`nПоследнее энергосостояние: "+$s.GpuPower
  $m=Read-Json (Join-Path $Data 'battery-current.json') $null
  if($m){$summary=$m.Summary;$batteryStatus.Text=$m.Label+' — '+$(if($m.Complete){$m.EndReason}else{'замер идёт'})+"`r`nОтсчётов: "+$summary.Samples+'; длительность: '+$summary.DurationSeconds+' сек.; средний расход: '+$summary.MeanDischargeWatts+' Вт'+"`r`nОценка по падению ёмкости: "+$summary.CapacityDeltaWatts+' Вт; средняя CPU-нагрузка: '+$summary.MeanCpuPercent+' %'}else{$batteryStatus.Text='Замеров ещё нет. Если батарея не сообщает расход, соответствующее поле останется пустым.'}
  if($s.Approval -and -not $script:SeenApprovals.ContainsKey($s.Approval.Id) -and (Get-Date) -lt [datetime]$s.Approval.Expires){
   $script:SeenApprovals[$s.Approval.Id]=$true
   $names=@($s.Approval.Clients | ForEach-Object {$_.Name+' (PID '+$_.Id+')'}) -join ', '
   if(-not $names){$names='Клиенты не обнаружены'}
   $answer=[Windows.Forms.MessageBox]::Show("Перезапустить NVIDIA? Экран может мигнуть, графические ресурсы приложений могут прерваться.`r`n`r`nЗатрагиваемые клиенты: $names`r`n`r`nЗащитные проверки будут повторены. Запрос действует 90 секунд.",'Подтверждение перезапуска','YesNo','Warning')
   if($answer -eq 'Yes'){Send-Command 'Approve' $s.Approval.Id}else{Send-Command 'Dismiss' $s.Approval.Id}
  }
 }catch{$status.Text='Не удалось прочитать состояние: '+$_.Exception.Message}
}
$timer=New-Object Windows.Forms.Timer;$timer.Interval=3000;$timer.Add_Tick({Refresh-Status;if($AutoCloseSeconds -gt 0 -and ((Get-Date)-$script:Started).TotalSeconds -ge $AutoCloseSeconds){$form.Close()}})
Refresh-Apps;Refresh-Protected;Refresh-History;Refresh-Measurements;Refresh-Status
$form.Add_Shown({if($PreviewPath){for($i=0;$i -lt $tabs.TabPages.Count;$i++){$tabs.SelectedIndex=$i;$form.Refresh();$bitmap=New-Object Drawing.Bitmap($form.Width,$form.Height);try{$form.DrawToBitmap($bitmap,[Drawing.Rectangle]::new(0,0,$form.Width,$form.Height));$bitmap.Save($PreviewPath.Replace('.png',('-'+$i+'.png')))}finally{$bitmap.Dispose()}};$tabs.SelectedIndex=0};$timer.Start()})
try{[void]$form.ShowDialog()}finally{$timer.Stop();$timer.Dispose();$form.Dispose()}
