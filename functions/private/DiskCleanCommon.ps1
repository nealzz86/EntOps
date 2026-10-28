function Get-WinUtilDiskJunkDefs {

    <#

    .SYNOPSIS
        Returns the fixed list of junk categories shown on the disk clean panel

    #>

    $localAppData = $env:LOCALAPPDATA
    $defs = @(
        @{ Id = "TempUser"; Name = "用户临时文件";
            Roots = @($env:TEMP) }
        @{ Id = "TempSys"; Name = "系统临时文件";
            Roots = @("$env:SystemRoot\Temp") }
        @{ Id = "Recycle"; Name = "回收站"; Roots = @(); Special = "Recycle" }
        @{ Id = "Update"; Name = "Windows 更新缓存";
            Roots = @("$env:SystemRoot\SoftwareDistribution\Download"); Special = "Update" }
        @{ Id = "Browser"; Name = "浏览器缓存";
            Roots = @("$localAppData\Google\Chrome\User Data\*\Cache",
                      "$localAppData\Google\Chrome\User Data\*\Code Cache",
                      "$localAppData\Microsoft\Edge\User Data\*\Cache",
                      "$localAppData\Microsoft\Edge\User Data\*\Code Cache") }
        @{ Id = "Dumps"; Name = "崩溃转储与错误报告";
            Roots = @("$localAppData\CrashDumps",
                      "$env:SystemRoot\Minidump",
                      "$env:ProgramData\Microsoft\Windows\WER\ReportQueue",
                      "$env:ProgramData\Microsoft\Windows\WER\ReportArchive") }
        @{ Id = "Thumb"; Name = "缩略图缓存";
            Roots = @("$localAppData\Microsoft\Windows\Explorer") }
        @{ Id = "Shaders"; Name = "DirectX 着色器缓存";
            Roots = @("$localAppData\D3DSCache") }
        @{ Id = "WeChat"; Name = "微信/企业微信缓存";
            Roots = @("$env:USERPROFILE\Documents\WeChat Files\*\FileStorage\Cache",
                      "$env:USERPROFILE\Documents\WeChat Files\*\FileStorage\Temp",
                      "$env:USERPROFILE\Documents\xwechat_files\*\cache",
                      "$env:APPDATA\Tencent\WXWork\Cache",
                      "$env:APPDATA\Tencent\WXWork\Temp") }
        @{ Id = "Ding"; Name = "钉钉日志缓存";
            Roots = @("$env:APPDATA\DingTalk\log",
                      "$env:APPDATA\DingTalk\*\log",
                      "$env:APPDATA\DingTalk\*\snapshot",
                      "$env:LOCALAPPDATA\DingTalk\log") }
        @{ Id = "Wps"; Name = "WPS 自动备份";
            Roots = @("$env:APPDATA\kingsoft\office6\backup",
                      "$env:LOCALAPPDATA\kingsoft\office6\backup") }
        @{ Id = "WinOld"; Name = "Windows.old 升级残留";
            Roots = @("$env:SystemDrive\Windows.old"); Takeown = $true }
    )
    return $defs
}

function Get-WinUtilRecycleBinRoots {

    <#

    .SYNOPSIS
        $Recycle.Bin folders of every fixed data drive

    #>

    $roots = @()
    foreach ($drive in [System.IO.DriveInfo]::GetDrives()) {
        if ($drive.DriveType -ne "Fixed" -or -not $drive.IsReady) { continue }
        $roots += (Join-Path $drive.RootDirectory.FullName "`$Recycle.Bin")
    }
    return $roots
}

function Measure-WinUtilJunkRoots {

    <#

    .SYNOPSIS
        Total bytes under the given root paths; wildcards resolve to every match

    #>
    param([string[]]$Roots)

    $total = [long]0
    foreach ($root in $Roots) {
        foreach ($dir in @(Get-Item -Path $root -Force -ErrorAction SilentlyContinue)) {
            if (-not $dir.PSIsContainer) { continue }
            $sum = (Get-ChildItem -LiteralPath $dir.FullName -Recurse -Force -File -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum).Sum
            if ($sum) { $total += [long]$sum }
        }
    }
    return $total
}

function Measure-WinUtilDiskJunkDef {

    <#

    .SYNOPSIS
        Bytes occupied by one junk category

    #>
    param([hashtable]$Def)

    $roots = @($Def.Roots)
    if ($Def.Special -eq "Recycle") { $roots = @(Get-WinUtilRecycleBinRoots) }
    return (Measure-WinUtilJunkRoots -Roots $roots)
}

function Format-WinUtilJunkSize {

    <#

    .SYNOPSIS
        Human readable size for the disk clean panel

    #>
    param([long]$Bytes)

    if ($Bytes -ge 1GB) { return ("{0:N1} GB" -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ("{0:N1} MB" -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ("{0:N0} KB" -f ($Bytes / 1KB)) }
    return "$Bytes B"
}

function Append-WinUtilDiskLog {

    <#

    .SYNOPSIS
        Appends a timestamped line to the disk clean output box on the UI thread

    #>
    param(
        [string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR")]
        [string]$Level = "INFO"
    )

    Write-WinUtilLog -Level $Level -Component "DiskClean" -Message $Message

    Invoke-WPFUIThread -Async -Parameters @{
        LogLine = "[$((Get-Date).ToString('HH:mm:ss'))] $Message"
    } -ScriptBlock {
        param($LogLine)

        $box = $sync["WPFDiskOutput"]
        if ($null -eq $box) { return }

        if ($box.Text -eq "就绪。点击「扫描垃圾占用」查看各类垃圾大小。") {
            $box.Text = $LogLine
        } else {
            $box.Text += "`n$LogLine"
        }
        $box.ScrollToEnd()
    }
}
