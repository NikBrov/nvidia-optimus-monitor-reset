$ProjectRoot=Split-Path $PSScriptRoot -Parent
$ErrorActionPreference='Stop'
. "$ProjectRoot\GpuCommon.ps1"
. "$ProjectRoot\GpuBattery.ps1"
function Assert($Condition,[string]$Name){if(-not $Condition){throw "FAIL: $Name"};"PASS: $Name"}
$testRoot=Join-Path $ProjectRoot ('test-'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $testRoot | Out-Null
$script:Data=$testRoot
try{
 $internal=@([pscustomobject]@{Internal=$true;Nvidia=$false});$external=@([pscustomobject]@{Internal=$false;Nvidia=$true})
 $awake=[pscustomobject]@{Present=$true;Problem=0;Power='D0'};$sleep=[pscustomobject]@{Present=$true;Problem=0;Power='D3'}
 $safe=@('C:\browser\chrome.exe');$known=@([pscustomobject]@{Id=10;Path=$safe[0]})
 Assert ((Get-ResetDecision 'Auto' $external $awake @() @() $safe 9999) -eq 'DisplayInUse') 'External screen blocks reset'
 Assert ((Get-ResetDecision 'Auto' $internal $awake @('work') @() $safe 9999) -eq 'ProtectedApp') 'Protected work blocks reset'
 Assert ((Get-ResetDecision 'Auto' $internal $awake @() @([pscustomobject]@{Path=''}) $safe 9999) -eq 'UnknownClient') 'Unreadable client path blocks reset'
 Assert ((Get-ResetDecision 'Auto' $internal $sleep @() @() $safe 9999) -eq 'AlreadyAsleep') 'Sleeping GPU is not restarted'
 Assert ((Get-ResetDecision 'Nvidia' $internal $awake @() @() $safe 9999) -eq 'Paused') 'Pause blocks reset'
 Assert ((Get-ResetDecision 'Auto' $internal $awake @() $known $safe 10) -eq 'Cooldown') 'Cooldown enforced'
 Assert ((Get-ResetDecision 'Auto' $internal $awake @() $known $safe 9999) -eq 'AllowReset') 'Known client eligible'
 Assert ((Get-ResetAuthorization 'Auto' $true $false) -eq 'Ask') 'Manual request requires confirmation in Auto'
 Assert ((Get-ResetAuthorization 'Notify' $false $false) -eq 'Notify') 'Notify never directly restarts'
 Assert ((Get-ResetAuthorization 'Ask' $false $false) -eq 'Ask') 'Ask requires approval'
 Assert ((Get-ResetAuthorization 'Notify' $true $true) -eq 'Proceed') 'Explicit approval permits rechecked manual request'
 Assert ((Get-ClientSignature $known) -ne (Get-ClientSignature @([pscustomobject]@{Id=11;Path=$safe[0]}))) 'Changed client invalidates approval identity'
 Save-Json @{ResetPolicy='Unknown';ProtectedPaths=@('relative.exe','C:\work\a.exe','C:\work\evil.ps1')} (Join-Path $Data 'options.json')
 $o=Get-Options;Assert ($o.ResetPolicy -eq 'Auto' -and $o.ProtectedPaths.Count -eq 1) 'Options reject invalid policy and non-EXE paths'
 $fake=Join-Path $testRoot 'preference-test.exe';$reg='HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
 try{
  New-ItemProperty -Path $reg -Name $fake -Value 'GpuPreference=2;TestToken=keep;' -PropertyType String -Force | Out-Null
  Set-AppOverride $fake '0'
  Assert (((Get-Item $reg).GetValue($fake)) -eq 'GpuPreference=0;TestToken=keep;') 'Windows choice preserves unrelated registry tokens'
  Set-AppOverride $fake '1';Set-AppOverride $fake 'Remove'
  Assert (((Get-Item $reg).GetValue($fake)) -eq 'GpuPreference=1;TestToken=keep;') 'Removing management leaves current GPU preference'
  Set-AppOverride $fake 'Restore'
  Assert (((Get-Item $reg).GetValue($fake)) -eq 'GpuPreference=2;TestToken=keep;') 'Restore returns first-touch original preference'
 }finally{Remove-ItemProperty -Path $reg -Name $fake -ErrorAction SilentlyContinue}
 function Get-DefaultAssignments {return @([pscustomobject]@{Path='C:\default.exe';Gpu=1},[pscustomobject]@{Path='C:\removed.exe';Gpu=2})}
 Save-Json @(@{Path='C:\default.exe';Gpu=0;Disabled=$false},@{Path='C:\removed.exe';Gpu=0;Disabled=$true},@{Path='C:\added.exe';Gpu=2;Disabled=$false}) (Join-Path $Data 'app-overrides.json')
 $a=@(Get-AppAssignments);Assert ($a.Count -eq 2 -and ($a | Where-Object Path -eq 'C:\default.exe').Gpu -eq 0 -and -not @($a | Where-Object Path -eq 'C:\removed.exe').Count) 'User Windows choice and removal override managed defaults'
 $samples=@([pscustomobject]@{AwakeSeconds=0;Watts=12;CpuPercent=$null;GpuPower='D0';RemainingMWh=40000},[pscustomobject]@{AwakeSeconds=300;Watts=18;CpuPercent=20;GpuPower='D3';RemainingMWh=38750})
 $summary=Get-BatterySummary $samples;Assert ($summary.MeanDischargeWatts -eq 15 -and $summary.CapacityDeltaWatts -eq 15 -and $summary.D3Samples -eq 1 -and $summary.MeanCpuPercent -eq 20) 'Battery units, missing CPU and means'
 $summary=Get-BatterySummary @([pscustomobject]@{AwakeSeconds=0;Watts=$null;CpuPercent=$null;GpuPower='D3';RemainingMWh=0})
 Assert ($null -eq $summary.MeanDischargeWatts -and $null -eq $summary.CapacityDeltaWatts) 'Unavailable battery values are not reported as zero watts'
 $script:BatterySession=[ordered]@{Id='fixture';Label='test';Samples=$samples;Complete=$false;Valid=$true;EndReason='';Summary=$null}
 Stop-BatterySession 'Simulated sleep' $false
 $m=Read-Json (Join-Path $Data 'measurements\fixture.json') $null
 Assert ($m.Complete -and -not $m.Valid -and (Test-Path (Join-Path $Data 'measurements\fixture.csv')) -and -not $script:BatterySession) 'Interrupted measurement persisted as invalid with CSV'
 $first=[GpuNative]::AwakeSeconds();Start-Sleep -Milliseconds 50;Assert ([GpuNative]::AwakeSeconds() -gt $first) 'Active-time clock works'
 $battery=[GpuNative]::Battery();Assert ($battery.Present -and $battery.RemainingMWh -gt 0) 'Native battery reading works on this laptop'
 'Battery native reading: '+($battery | ConvertTo-Json -Compress)
 'All v6 policy tests passed; no real GPU reset or user preference changes.'
}finally{Remove-Item -LiteralPath $testRoot -Recurse -Force}
