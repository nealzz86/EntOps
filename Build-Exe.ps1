#Requires -Version 5.1

<#

.SYNOPSIS
    Builds the single-file portable executable for the enterprise operations tool.

.DESCRIPTION
    Compiles the script, publishes it into the release folder, packages it with ps2exe, and then
    appends the offline material (drivers and tools) to the end of the executable. The running
    exe finds that trailer and unpacks it on first launch, so the release folder can ship as one
    file instead of an exe plus two side-by-side folders.

.NOTES
    The appended archive is plain zip data, so 7-Zip or Explorer can open the exe and read it.

#>

param(
    [string]$ReleaseDir = "D:\打印\企业运维工具",
    [string]$ExeName = "企业运维工具.exe",
    [string]$Title = "企业运维工具",
    [string]$IconFile = "$PSScriptRoot\assets\entops-icon.ico"
)

$ErrorActionPreference = "Stop"
Set-Location -LiteralPath $PSScriptRoot

Write-Output "== 编译 winutil.ps1"
& .\Compile.ps1

$compiled = Get-Content -LiteralPath "$PSScriptRoot\winutil.ps1" -Raw
$version = [regex]::Match($compiled, '\$sync\.version = "([^"]+)"').Groups[1].Value
if (-not $version) {
    throw "Compiled script carries no version string."
}
Write-Output "   版本 $version"

$scriptPath = Join-Path $ReleaseDir "EntOps.ps1"
$exePath = Join-Path $ReleaseDir $ExeName
Copy-Item -LiteralPath "$PSScriptRoot\winutil.ps1" -Destination $scriptPath -Force
Write-Output "== 发布 $scriptPath"

Write-Output "== 打包内置资源"
$stage = Join-Path $env:TEMP "entops-payload-stage"
$zipPath = Join-Path $env:TEMP "entops-payload.zip"
if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
New-Item -ItemType Directory -Path $stage -Force | Out-Null

# Anything the tool looks for beside its own file belongs in the archive
foreach ($folder in @("drivers", "tools")) {
    $source = Join-Path $ReleaseDir $folder
    if (Test-Path -LiteralPath $source) {
        Copy-Item -LiteralPath $source -Destination (Join-Path $stage $folder) -Recurse -Force
    }
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory($stage, $zipPath, [System.IO.Compression.CompressionLevel]::Fastest, $false)
Remove-Item -LiteralPath $stage -Recurse -Force
$payloadLength = (Get-Item -LiteralPath $zipPath).Length
Write-Output ("   内置资源 {0:N1} MB" -f ($payloadLength / 1MB))

Write-Output "== 生成 EXE"
Import-Module ps2exe
if (Test-Path -LiteralPath $exePath) {
    # A running instance holds the file open, and the error ps2exe reports for that is misleading
    Remove-Item -LiteralPath $exePath -Force
}
Invoke-ps2exe -inputFile $scriptPath -outputFile $exePath -noConsole -title $Title -version $version -iconFile $IconFile | Out-Null

Write-Output "== 追加内置资源"
$trailer = [System.Text.Encoding]::ASCII.GetBytes("ENTOPS01") + [BitConverter]::GetBytes([Int64] $payloadLength)
$exeStream = [System.IO.File]::Open($exePath, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
try {
    $zipStream = [System.IO.File]::OpenRead($zipPath)
    try { $zipStream.CopyTo($exeStream, 1048576) } finally { $zipStream.Dispose() }
    $exeStream.Write($trailer, 0, $trailer.Length)
} finally {
    $exeStream.Dispose()
}
Remove-Item -LiteralPath $zipPath -Force

Write-Output ("== 完成：{0}（{1:N1} MB）" -f $exePath, ((Get-Item -LiteralPath $exePath).Length / 1MB))
