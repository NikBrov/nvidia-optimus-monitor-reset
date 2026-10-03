function Start-BatterySession([int]$Minutes,[string]$Label) {
 if($Minutes -notin @(5,10)){throw 'Длительность замера: 5 или 10 минут.'}
 if($script:BatterySession){throw 'Замер уже запущен.'}
 $reading=[GpuNative]::Battery()
 if(-not $reading.Present -or $reading.Online -or -not $reading.Discharging){throw 'Для замера отключите зарядку; батарея должна разряжаться.'}
 $brightness=$null;try{$brightness=@(Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorBrightness -OperationTimeoutSec 3 -ErrorAction Stop | Select-Object -ExpandProperty CurrentBrightness)}catch{}
 $script:BatterySession=[ordered]@{Id=(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,6);Label=$Label.Substring(0,[math]::Min(120,$Label.Length));Started=(Get-Date).ToString('o');AwakeStart=[GpuNative]::AwakeSeconds();Minutes=$Minutes;Mode=$script:Mode;Brightness=$brightness;Samples=@();Complete=$false;Valid=$true;EndReason='';Summary=$null}
 $script:BatteryNext=Get-Date
 Write-GpuLog ('BATTERY start '+$script:BatterySession.Id+'; automatic resets suspended during measurement')
}
function Get-BatterySummary($Samples) {
 $s=@($Samples);$rates=@($s | Where-Object {$null -ne $_.Watts} | ForEach-Object Watts);$cpus=@($s | Where-Object {$null -ne $_.CpuPercent} | ForEach-Object CpuPercent)
 $duration=0;$capacityWatts=$null
 if($s.Count -gt 1){$duration=[double]$s[-1].AwakeSeconds-[double]$s[0].AwakeSeconds;$delta=[double]$s[0].RemainingMWh-[double]$s[-1].RemainingMWh;if($duration -ge 30 -and $delta -ge 0 -and $s[0].RemainingMWh -gt 0 -and $s[-1].RemainingMWh -gt 0 -and $s[0].RemainingMWh -ne [uint32]::MaxValue -and $s[-1].RemainingMWh -ne [uint32]::MaxValue){$capacityWatts=[math]::Round(($delta/1000)/($duration/3600),2)}}
 return [pscustomobject]@{Samples=$s.Count;DurationSeconds=[math]::Round($duration,1);MeanDischargeWatts=if($rates.Count){[math]::Round(($rates | Measure-Object -Average).Average,2)}else{$null};CapacityDeltaWatts=$capacityWatts;MeanCpuPercent=if($cpus.Count){[math]::Round(($cpus | Measure-Object -Average).Average,1)}else{$null};D3Samples=@($s | Where-Object GpuPower -eq 'D3').Count}
}
function Save-BatterySession {
 if(-not $script:BatterySession){return}
 $script:BatterySession.Summary=Get-BatterySummary $script:BatterySession.Samples
 Save-Json $script:BatterySession (Join-Path $Data 'battery-current.json')
}
function Stop-BatterySession([string]$Reason,[bool]$Valid=$true) {
 if(-not $script:BatterySession){return}
 $script:BatterySession.Complete=$true;$script:BatterySession.Valid=$Valid;$script:BatterySession.EndReason=$Reason;$script:BatterySession['Ended']=(Get-Date).ToString('o')
 Save-BatterySession
 $folder=Join-Path $Data 'measurements';New-Item -ItemType Directory -Path $folder -Force | Out-Null
 Save-Json $script:BatterySession (Join-Path $folder ($script:BatterySession.Id+'.json'))
 if(@($script:BatterySession.Samples).Count){$script:BatterySession.Samples | Export-Csv -LiteralPath (Join-Path $folder ($script:BatterySession.Id+'.csv')) -NoTypeInformation -Encoding UTF8}
 Write-GpuLog ('BATTERY end '+$script:BatterySession.Id+'; '+$Reason+'; valid='+$Valid)
 $script:BatterySession=$null
}
function Update-BatterySession {
 if(-not $script:BatterySession -or (Get-Date) -lt $script:BatteryNext){return}
 $script:BatteryNext=(Get-Date).AddSeconds(15)
 $r=[GpuNative]::Battery()
 if($r.Online -or -not $r.Discharging){Stop-BatterySession 'Подключена зарядка или батарея перестала разряжаться' $false;return}
 $state=[GpuNative]::ReadPower($Config.DeviceId)
 $sample=[pscustomobject]@{Time=(Get-Date).ToString('o');AwakeSeconds=[GpuNative]::AwakeSeconds();Watts=$r.Watts;RemainingMWh=$r.RemainingMWh;Percent=[math]::Round([Windows.Forms.SystemInformation]::PowerStatus.BatteryLifePercent*100,1);CpuPercent=[GpuNative]::CpuPercent();GpuPower=$state.Power;ActiveApplications=(@(Get-Process | Where-Object MainWindowHandle -ne 0 | ForEach-Object ProcessName | Sort-Object -Unique) -join ', ')}
 $script:BatterySession.Samples += $sample
 Save-BatterySession
 if(($sample.AwakeSeconds-$script:BatterySession.AwakeStart) -ge $script:BatterySession.Minutes*60){Stop-BatterySession 'Замер завершён по времени'}
}
