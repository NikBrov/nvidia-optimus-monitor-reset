param([string]$Backup, [switch]$Silent)
$ErrorActionPreference = 'Stop'
$dest = 'C:\NvidiaReset'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run rollback from an elevated PowerShell window.' }
if (-not $Backup) { $Backup = (Get-Content (Join-Path $dest 'upgrade-v7.json') -Raw | ConvertFrom-Json).Backup }
$Backup = [IO.Path]::GetFullPath($Backup)
if ([IO.Path]::GetDirectoryName($Backup) -ne $dest -or [IO.Path]::GetFileName($Backup) -notlike 'backup-v7-*' -or -not (Test-Path (Join-Path $Backup 'registry-before.json'))) { throw 'Invalid rollback snapshot.' }
$tasks = @(@{Name='Auto Reset NVIDIA on Monitor Disconnect';File='agent-task.xml'},@{Name='GPU Manager Panel';File='panel-task.xml'})
foreach ($task in $tasks) { if (Get-ScheduledTask -TaskName $task.Name -ErrorAction SilentlyContinue) { Stop-ScheduledTask -TaskName $task.Name; Start-Sleep -Seconds 1 } }
foreach ($process in @(Get-Process -Name GpuManager,GpuManager.Agent -ErrorAction SilentlyContinue | Where-Object { $_.Path -in @((Join-Path $dest 'GpuManager.exe'),(Join-Path $dest 'GpuManager.Agent.exe')) })) {
    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    if (-not $process.WaitForExit(10000)) { throw 'Current executable did not exit.' }
}
$registry = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
$snapshot = @(Get-Content (Join-Path $Backup 'registry-before.json') -Raw | ConvertFrom-Json)
$touched = Join-Path $dest 'data\preferences-before.json'
if (Test-Path $touched) {
    New-Item -Path $registry -Force | Out-Null
    foreach ($entry in @(Get-Content $touched -Raw | ConvertFrom-Json)) {
        $saved = @($snapshot | Where-Object { $_.Path -eq $entry.Path })
        if ($saved.Count) { New-ItemProperty -Path $registry -Name $entry.Path -Value $saved[0].Value -PropertyType String -Force | Out-Null }
        else { Remove-ItemProperty -Path $registry -Name $entry.Path -ErrorAction SilentlyContinue }
    }
}
Get-ChildItem -LiteralPath $Backup -File | Where-Object { $_.Name -notin @('agent-task.xml','panel-task.xml','registry-before.json','snapshot-complete.flag') } | Copy-Item -Destination $dest -Force
# Restore state that affects policy/preferences. Preserve new diagnostic history and measurements.
if (Test-Path (Join-Path $Backup 'snapshot-complete.flag')) {
foreach ($file in @('mode.json','options.json','assignments.json','preferences-before.json','manual-apps.json','app-overrides.json','last-reset.json')) {
    $source=Join-Path $Backup ('data\'+$file); $target=Join-Path $dest ('data\'+$file)
    if (Test-Path $source) { Copy-Item -LiteralPath $source -Destination $target -Force } elseif (Test-Path $target) { Remove-Item -LiteralPath $target -Force }
}
}
$queue=Join-Path $dest 'data\commands'
if (Test-Path $queue) { Get-ChildItem -LiteralPath $queue -Filter '*.json' -File | Remove-Item -Force }
foreach ($file in @('command.json','reset-request.flag','ui-activate.flag')) { $path=Join-Path $dest ('data\'+$file); if (Test-Path $path) { Remove-Item -LiteralPath $path -Force } }
$desktop=[Environment]::GetFolderPath('Desktop')
foreach ($name in @('GPU - Intel и NVIDIA.lnk','GPU - Инструкция.lnk')) {
    $source=Join-Path $Backup ('shortcuts\'+$name); $target=Join-Path $desktop $name
    if (Test-Path $source) { Copy-Item -LiteralPath $source -Destination $target -Force } elseif (Test-Path $target) { Remove-Item -LiteralPath $target -Force }
}
foreach ($task in $tasks) {
    $xml=Join-Path $Backup $task.File
    if (Test-Path $xml) { Register-ScheduledTask -TaskName $task.Name -Xml (Get-Content $xml -Raw) -Force | Out-Null; Start-ScheduledTask -TaskName $task.Name }
    elseif (Get-ScheduledTask -TaskName $task.Name -ErrorAction SilentlyContinue) { Unregister-ScheduledTask -TaskName $task.Name -Confirm:$false }
}
if (-not $Silent) { Write-Output ('Previous installation restored from '+$Backup+'. Files and new history remain available.') }
