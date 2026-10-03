$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
if (-not ('GpuNative' -as [type])) { Add-Type -Path "$PSScriptRoot\GpuNative.cs" -ReferencedAssemblies System.Windows.Forms }
$script:Root=$PSScriptRoot
$script:Data=Join-Path $Root 'data'
$script:Config=Get-Content (Join-Path $Root 'config.json') -Raw | ConvertFrom-Json
$devices=@(Get-PnpDevice -Class Display -PresentOnly -ErrorAction Stop | Where-Object InstanceId -like 'PCI\VEN_10DE*')
if(-not $Config.DeviceId){
 if($devices.Count -ne 1){throw 'Expected exactly one NVIDIA display device. Set DeviceId explicitly in config.json.'}
 $Config.DeviceId=[string]$devices[0].InstanceId
}
if(@($devices | Where-Object InstanceId -eq $Config.DeviceId).Count -ne 1){throw 'Configured DeviceId must be a present NVIDIA display adapter.'}

function Write-GpuLog([string]$Text) {
 $log=Join-Path $Data 'GpuManager.log'
 if ((Test-Path $log) -and (Get-Item $log).Length -gt 2MB) { Move-Item -LiteralPath $log -Destination ($log+'.previous') -Force }
 ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss')+' '+$Text) | Add-Content -LiteralPath $log -Encoding UTF8
}
function Save-Json($Object,[string]$Path) {
 $tmp=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'; $Object | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $tmp -Encoding UTF8
 Move-Item -LiteralPath $tmp -Destination $Path -Force
}
function Read-Json([string]$Path,$Default) { if(Test-Path $Path){ return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json) };return $Default }
function Get-Topology {
 $paths=@([GpuNative]::Displays($false))
 if($paths.Count -eq 0){throw 'No active display paths; reset forbidden'}
 return $paths
}
function Get-NvidiaLuid {
 $paths=@([GpuNative]::Displays($true) | Where-Object Nvidia | Select-Object -ExpandProperty AdapterLuid -Unique)
 if($paths.Count -ne 1){throw 'NVIDIA adapter mapping is ambiguous'}
 $split=$paths[0].Split(':'); return ('luid_0x'+$split[0]+'_0x'+$split[1])
}
function Get-GpuClients([string]$Luid) {
 # Windows bookkeeping, not NVML/nvidia-smi. Memory allocations are conservative
 # evidence of GPU clients, not a measurement of instantaneous utilisation.
 $rows=@(Get-CimInstance Win32_PerfRawData_GPUPerformanceCounters_GPUProcessMemory -ErrorAction Stop)
 $ids=@($rows | Where-Object { $_.Name -like ('*'+$Luid+'*') -and [uint64]$_.TotalCommitted -gt 0 } | ForEach-Object { if($_.Name -match '^pid_(\d+)_'){[int]$Matches[1]} } | Sort-Object -Unique)
 $clients=@()
 foreach($processId in $ids) {
  if($processId -le 4){continue} # Kernel bookkeeping is not a restartable user app.
  $proc=Get-Process -Id $processId -ErrorAction SilentlyContinue
  if($proc){$clients += [pscustomobject]@{Id=$processId;Name=$proc.ProcessName;Path=[string]$proc.Path}}
 }
 return $clients
}
function Get-DefaultProtectedProcesses {
 return @(Get-Process -ErrorAction Stop | Where-Object {$Config.ProtectedProcessNames -contains $_.ProcessName} | Select-Object ProcessName,Id,Path)
}
function Get-ResetDecision($Mode,$Paths,$Power,$Protected,$Clients,$SafePaths,$SecondsSinceLast) {
 if($Mode -eq 'Nvidia'){return 'Paused'}
 if(@($Paths).Count -eq 0 -or @($Paths | Where-Object { -not $_.Internal -or $_.Nvidia }).Count -gt 0){return 'DisplayInUse'}
 if(-not $Power.Present -or $Power.Problem -ne 0){return 'DeviceError'}
 if(@($Protected).Count -gt 0){return 'ProtectedApp'}
 if($Power.Power -eq 'D3'){return 'AlreadyAsleep'}
 if($Power.Power -ne 'D0'){return 'UnknownPower'}
 if($SecondsSinceLast -lt $Config.CooldownSeconds){return 'Cooldown'}
 foreach($client in @($Clients)){if(-not $client.Path -or $SafePaths -notcontains $client.Path){return 'UnknownClient'}}
 return 'AllowReset'
}
function Get-DefaultAssignments {
 $assignments=@()
 foreach($entry in @($Config.EverydayExecutables)){$p=[Environment]::ExpandEnvironmentVariables($entry);if(Test-Path -LiteralPath $p){$assignments += [pscustomobject]@{Path=$p;Gpu=1}}}
 foreach($entry in @($Config.PerformanceExecutables)+@($Config.ManualPerformanceExecutables)){$p=[Environment]::ExpandEnvironmentVariables($entry);if(Test-Path -LiteralPath $p){$assignments += [pscustomobject]@{Path=$p;Gpu=2}}}
 foreach($pattern in $Config.PackagePatterns){
  foreach($package in @(Get-AppxPackage -Name $pattern -ErrorAction Stop)){
   foreach($file in @(Get-ChildItem -LiteralPath $package.InstallLocation -Recurse -File -Filter '*.exe' -ErrorAction SilentlyContinue | Where-Object {$Config.PackageExecutableNames -contains $_.Name})){
    $assignments += [pscustomobject]@{Path=$file.FullName;Gpu=1}
   }
  }
 }
 $unique=@{}
 foreach($item in $assignments){$unique[$item.Path]=$item}
 foreach($manualPath in @(Read-Json (Join-Path $Data 'manual-apps.json') @())){
  if($manualPath -is [string] -and [IO.Path]::IsPathRooted($manualPath) -and [IO.Path]::GetExtension($manualPath) -eq '.exe' -and (Test-Path -LiteralPath $manualPath)){$unique[$manualPath]=[pscustomobject]@{Path=$manualPath;Gpu=2}}
 }
 return @($unique.Values | Sort-Object Path)
}
function Set-AppPreference([string]$Path,[int]$Gpu) {
 $key='HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
 if(-not(Test-Path $key)){New-Item $key -Force | Out-Null}
 $rk=Get-Item $key; $exists=$rk.GetValueNames() -contains $Path; $old=$rk.GetValue($Path,$null)
 $backupPath=Join-Path $Data 'preferences-before.json'
 $entries=@(Read-Json $backupPath @())
 if(-not @($entries | Where-Object Path -eq $Path).Count){
  $entries += [pscustomobject]@{Path=$Path;Existed=$exists;Value=$old}
  Save-Json @($entries) $backupPath
 }
 $other=([string]$old -replace 'GpuPreference=\d+;?','').Trim(';')
 $value='GpuPreference='+$Gpu+';';if($other){$value += $other+';'}
 if($old -ne $value){New-ItemProperty -Path $key -Name $Path -Value $value -PropertyType String -Force | Out-Null;Write-GpuLog "PREFERENCE gpu=$Gpu path=$Path"}
}
function Update-AppPreferences {
 $apps=@(Get-AppAssignments)
 foreach($app in $apps){Set-AppPreference $app.Path $app.Gpu}
 Save-Json @($apps) (Join-Path $Data 'assignments.json')
 return $apps
}
function Get-SafeClientPaths($Assignments) {
 $safe=@($Assignments | Where-Object {$_.Gpu -eq 1 -and $Config.ResetTolerantExecutableNames -contains [IO.Path]::GetFileName($_.Path)} | ForEach-Object Path)
 # Only the known system display processes, identified by full path.
 $safe += @("$env:windir\System32\dwm.exe","$env:windir\System32\csrss.exe","$env:windir\explorer.exe")
 $manual=@(Read-Json (Join-Path $Data 'manual-apps.json') @())
 return @($safe | Where-Object {$manual -notcontains $_})
}
. "$PSScriptRoot\GpuV6.ps1"
