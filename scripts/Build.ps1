param([string]$DotNet = 'dotnet')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$package = Join-Path $root 'artifacts\package'
New-Item -ItemType Directory -Path $package -Force | Out-Null
foreach ($project in @('App', 'Agent')) {
    & $DotNet publish (Join-Path $root "src\GpuManager.$project\GpuManager.$project.csproj") -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=false -o $package
    if ($LASTEXITCODE) { throw "Publish $project failed" }
}
foreach ($name in @('config.json','README.txt','LICENSE','Install.cmd')) { Copy-Item -LiteralPath (Join-Path $root $name) -Destination $package -Force }
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Install-v7.ps1') -Destination $package -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'rollback-v7.ps1') -Destination $package -Force
# Native runtime DLLs remain beside the EXEs in the protected install directory.
# Never archive local audit data, results, PDBs or other leftover package files.
$files = @('GpuManager.exe','GpuManager.Agent.exe','config.json','README.txt','LICENSE','Install.cmd','Install-v7.ps1','rollback-v7.ps1') | ForEach-Object { Join-Path $package $_ }
$files += @(Get-ChildItem -LiteralPath $package -File -Filter '*.dll' | Select-Object -ExpandProperty FullName)
Compress-Archive -LiteralPath $files -DestinationPath (Join-Path $root 'artifacts\GpuManager-v7-win-x64.zip') -Force
Write-Output "Package: $package"
