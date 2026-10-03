param([switch]$Elevated, [string]$ExpectedSid)
$ErrorActionPreference = 'Stop'
$dest = 'C:\NvidiaReset'
$taskName = 'Auto Reset NVIDIA on Monitor Disconnect'
$panelTask = 'GPU Manager Panel'
$resultFile = Join-Path $PSScriptRoot 'install-v7-result.json'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$admin = ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) {
    if ($Elevated) { throw 'Administrator rights are required.' }
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -Elevated -ExpectedSid "' + $identity.User.Value + '"'
    $process = Start-Process "$env:windir\System32\WindowsPowerShell\v1.0\powershell.exe" -Verb RunAs -WindowStyle Hidden -ArgumentList $arguments -PassThru -Wait
    $result = if (Test-Path $resultFile) { Get-Content $resultFile -Raw | ConvertFrom-Json } else { $null }
    if ($process.ExitCode -ne 0 -or -not $result.Success) { throw ('Installation failed. ' + $result.Error) }
    Write-Output ('GPU Manager v7 installed. Backup: ' + $result.Backup)
    exit 0
}
$backup = $null
$changed = $false
try {
    if ($ExpectedSid -and $ExpectedSid -ne $identity.User.Value) { throw 'Run the installer from the intended Windows account; elevation must keep the same account.' }
    if ([IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') -eq $dest) { throw 'Extract the package outside the live installation before updating.' }
    foreach ($file in @('GpuManager.exe','GpuManager.Agent.exe','config.json','README.txt','rollback-v7.ps1')) {
        if (-not (Test-Path (Join-Path $PSScriptRoot $file))) { throw "Missing package file: $file" }
    }
    # Audit uses a separate package data directory, never changes preferences or restarts a device.
    $audit = Start-Process (Join-Path $PSScriptRoot 'GpuManager.Agent.exe') -ArgumentList @('--root', ('"'+$PSScriptRoot+'"'), '--audit') -WindowStyle Hidden -PassThru -Wait
    if ($audit.ExitCode -ne 0) { throw 'Native hardware audit failed. See package data\manager.log.' }
    $hardware = Get-Content (Join-Path $PSScriptRoot 'data\audit.json') -Raw | ConvertFrom-Json
    if (-not $hardware.Power.Present -or $hardware.Power.Problem -ne 0 -or $hardware.Errors.Count -gt 0) { throw 'No healthy NVIDIA display adapter/topology found.' }
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    $backup = Join-Path $dest ('backup-v7-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
    New-Item -ItemType Directory -Path $backup | Out-Null
    foreach ($entry in @(@{Name=$taskName;File='agent-task.xml'}, @{Name=$panelTask;File='panel-task.xml'})) {
        if (Get-ScheduledTask -TaskName $entry.Name -ErrorAction SilentlyContinue) { Export-ScheduledTask -TaskName $entry.Name | Set-Content (Join-Path $backup $entry.File) -Encoding Unicode }
    }
    Get-ChildItem -LiteralPath $dest -File | Copy-Item -Destination $backup
    $desktop = [Environment]::GetFolderPath('Desktop')
    New-Item -ItemType Directory -Path (Join-Path $backup 'shortcuts') | Out-Null
    foreach ($name in @('GPU - Intel и NVIDIA.lnk','GPU - Инструкция.lnk')) {
        $path = Join-Path $desktop $name
        if (Test-Path $path) { Copy-Item -LiteralPath $path -Destination (Join-Path $backup 'shortcuts') }
    }
    $key = Get-Item 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences' -ErrorAction SilentlyContinue
    $preferences = @()
    if ($key) { $preferences = @($key.GetValueNames() | ForEach-Object { [pscustomobject]@{Path=$_;Value=$key.GetValue($_)} }) }
    ConvertTo-Json -InputObject $preferences -Depth 5 | Set-Content (Join-Path $backup 'registry-before.json') -Encoding UTF8
    # Stop both generations before taking the mutable-state snapshot or replacing files.
    $changed = $true
    foreach ($name in @($panelTask,$taskName)) {
        if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) {
            Stop-ScheduledTask -TaskName $name
            for ($i=0; $i -lt 30; $i++) { if ([string](Get-ScheduledTask -TaskName $name).State -ne 'Running') { break }; Start-Sleep -Milliseconds 500 }
            if ([string](Get-ScheduledTask -TaskName $name).State -eq 'Running') { throw "Task did not stop: $name" }
        }
    }
    # Close only our previous panel, leaving other PowerShell windows untouched.
    $legacy = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.ProcessId -ne $PID -and $_.SessionId -eq (Get-Process -Id $PID).SessionId -and $_.CommandLine -match [regex]::Escape('C:\NvidiaReset\GpuControl.ps1') })
    foreach ($process in $legacy) { Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue }
    foreach ($process in @(Get-Process -Name GpuManager -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq (Join-Path $dest 'GpuManager.exe') })) { Stop-Process -Id $process.Id -Force }
    if (Test-Path (Join-Path $dest 'data')) { Copy-Item -LiteralPath (Join-Path $dest 'data') -Destination (Join-Path $backup 'data') -Recurse }
    'Ready' | Set-Content (Join-Path $backup 'snapshot-complete.flag') -Encoding ASCII
    $runtimeFiles = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.dll' -File | Select-Object -ExpandProperty Name)
    foreach ($file in (@('GpuManager.exe','GpuManager.Agent.exe','README.txt','rollback-v7.ps1','LICENSE') + $runtimeFiles)) {
        if (Test-Path (Join-Path $PSScriptRoot $file)) { Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination $dest -Force }
    }
    $configPath = Join-Path $dest 'config.json'
    $config = if (Test-Path $configPath) { Get-Content $configPath -Raw | ConvertFrom-Json } else { Get-Content (Join-Path $PSScriptRoot 'config.json') -Raw | ConvertFrom-Json }
    $config.Version = 7
    $config | ConvertTo-Json -Depth 12 | Set-Content $configPath -Encoding UTF8
    $data = Join-Path $dest 'data'
    New-Item -ItemType Directory -Path $data -Force | Out-Null
    foreach ($file in @('command.json','reset-request.flag','ui-activate.flag')) { $path=Join-Path $data $file; if (Test-Path $path) { Remove-Item -LiteralPath $path -Force } }
    $queue = Join-Path $data 'commands'
    if (Test-Path $queue) { Get-ChildItem -LiteralPath $queue -Filter '*.json' -File | Remove-Item -Force }
    # Executables/config are protected; the panel can write only fixed-format state/commands.
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true,$false)
    foreach ($sid in @('S-1-5-32-544','S-1-5-18')) { $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),'FullControl','ContainerInherit,ObjectInherit','None','Allow')) }
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-5-32-545'),'ReadAndExecute','ContainerInherit,ObjectInherit','None','Allow'))
    Set-Acl -LiteralPath $dest -AclObject $acl
    $stateAcl = Get-Acl $data
    $stateAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($identity.User,'Modify','ContainerInherit,ObjectInherit','None','Allow'))
    Set-Acl -LiteralPath $data -AclObject $stateAcl
    # Remove any copied explicit user write permission from the rollback snapshot.
    Get-ChildItem -LiteralPath $backup -Recurse -Force | ForEach-Object { $itemAcl=Get-Acl -LiteralPath $_.FullName; $itemAcl.SetAccessRuleProtection($false,$false); foreach($rule in @($itemAcl.Access | Where-Object { -not $_.IsInherited })) { [void]$itemAcl.RemoveAccessRuleSpecific($rule) }; Set-Acl -LiteralPath $_.FullName -AclObject $itemAcl }
    @{Backup=$backup;Version=7;Installed=(Get-Date).ToString('o');UserSid=$identity.User.Value} | ConvertTo-Json | Set-Content (Join-Path $dest 'upgrade-v7.json') -Encoding UTF8
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $identity.User.Value
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([timespan]::Zero) -MultipleInstances IgnoreNew -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    $arguments = '--root "' + $dest + '"'
    $action = New-ScheduledTaskAction -Execute (Join-Path $dest 'GpuManager.Agent.exe') -Argument $arguments -WorkingDirectory $dest
    $principal = New-ScheduledTaskPrincipal -UserId $identity.User.Value -LogonType Interactive -RunLevel Highest
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description 'GPU Manager v7 native C#: guarded NVIDIA recovery and app preferences.' -Force | Out-Null
    $action = New-ScheduledTaskAction -Execute (Join-Path $dest 'GpuManager.exe') -Argument ($arguments+' --tray') -WorkingDirectory $dest
    $principal = New-ScheduledTaskPrincipal -UserId $identity.User.Value -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $panelTask -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description 'GPU Manager v7 normal-user panel, tray and confirmations.' -Force | Out-Null
    $ws = New-Object -ComObject WScript.Shell
    $link = $ws.CreateShortcut((Join-Path $desktop 'GPU - Intel и NVIDIA.lnk'))
    $link.TargetPath = Join-Path $dest 'GpuManager.exe'; $link.Arguments = ''; $link.WorkingDirectory = $dest; $link.IconLocation = "$env:windir\System32\shell32.dll,16"; $link.Save()
    $link = $ws.CreateShortcut((Join-Path $desktop 'GPU - Инструкция.lnk'))
    $link.TargetPath = Join-Path $dest 'README.txt'; $link.WorkingDirectory = $dest; $link.IconLocation = "$env:windir\System32\notepad.exe,0"; $link.Save()
    $safeBat = '@echo off'+"`r`n"+'start "" "C:\NvidiaReset\GpuManager.exe" --command Check'+"`r`n"
    foreach ($name in @('Request_Reset_Now.bat','Reset_NVIDIA_GPU.bat')) { [IO.File]::WriteAllText((Join-Path $dest $name),$safeBat,[Text.Encoding]::ASCII) }
    Start-ScheduledTask -TaskName $taskName
    $ready = $false
    for ($i=0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 1
        try { $status=Get-Content (Join-Path $data 'status.json') -Raw | ConvertFrom-Json; if ($status.Version -eq 7 -and (Get-Process -Id $status.ProcessId -ErrorAction SilentlyContinue).ProcessName -eq 'GpuManager.Agent' -and ([datetimeoffset]::Now - [datetimeoffset]$status.Heartbeat).TotalSeconds -lt 30) { $ready=$true; break } } catch { }
    }
    if (-not $ready) { throw 'Native agent did not publish a fresh v7 heartbeat.' }
    Start-ScheduledTask -TaskName $panelTask
    Start-Sleep -Seconds 3
    if ([string](Get-ScheduledTask -TaskName $panelTask).State -ne 'Running') { throw 'Normal-user panel did not stay running.' }
    @{Success=$true;Backup=$backup;Version=7} | ConvertTo-Json | Set-Content $resultFile -Encoding UTF8
} catch {
    $message = $_.Exception.Message
    $rollbackError = $null
    if ($changed -and $backup) {
        try { & (Join-Path $PSScriptRoot 'rollback-v7.ps1') -Backup $backup -Silent } catch { $rollbackError=$_.Exception.Message }
    }
    @{Success=$false;Error=$message;Backup=$backup;RollbackError=$rollbackError} | ConvertTo-Json | Set-Content $resultFile -Encoding UTF8
    exit 1
}
