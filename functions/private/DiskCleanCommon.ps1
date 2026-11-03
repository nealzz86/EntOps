function Get-WinUtilDiskJunkDefs {

    <#

    .SYNOPSIS
        Returns the fixed list of junk categories shown on the disk clean panel

    #>

    $localAppData = $env:LOCALAPPDATA
    $roaming = $env:APPDATA

    # Electron/Chromium 系应用里可以安全重生成的那批目录。刻意不含 Local Storage、Session Storage、
    # IndexedDB、WebStorage：那几个装着登录状态和会话数据，删掉等于把同事的账号退出。
    $aiCacheParts = @(
        "Cache", "Code Cache", "GPUCache", "ShaderCache", "blob_storage", "CachedData",
        "logs", "log", "Crashpad", "CrashReports", "sentry", (Join-Path "Service Worker" "CacheStorage")
    )
    # 国内常见的 AI 对话/效率客户端（目录名，装了才扫得到，扫不到就是 0）
    $aiChatApps = @(
        "CherryStudio", "Chatbox", "doubao", "Kimi", "TongyiQianWen", "tongyi", "yuanbao", "ima.copilot",
        "iFlytek", "Xinghuo", "MiniMax", "MiniMaxHub", "com.minimax.hub", "hermes-desktop",
        "anythingllm-desktop", "dd-doc", "ichat", "JianyingPro\User Data", "WPS AI", "Coze", "codefuse"
    )
    # AI 编程工具：VS Code 分支的缓存目录名基本一致，清完会自动重建
    $aiCoderApps = @(
        "Cursor", "Trae", "Trae CN", "TRAE SOLO CN", "Windsurf", "Qoder", "Qoder CN", "QoderCN",
        "QoderWork CN", "CodeBuddy", "CodeBuddyExtension", "WorkBuddy", "WorkBuddyExtension", "ZCode",
        "Lingma", "通义灵码", "Comate", "Fitten Code", "Void", "Roo Code"
    )

    function New-WinUtilAiCacheRoots([string[]]$Apps, [string[]]$Bases) {
        $roots = @()
        foreach ($app in $Apps) {
            foreach ($base in $Bases) {
                foreach ($part in $aiCacheParts) {
                    $roots += (Join-Path $base (Join-Path $app $part))
                }
            }
        }
        return $roots
    }

    $aiChatRoots = @(New-WinUtilAiCacheRoots -Apps $aiChatApps -Bases @($roaming, $localAppData))
    $aiCoderRoots = @(New-WinUtilAiCacheRoots -Apps $aiCoderApps -Bases @($roaming, $localAppData))

    # %LOCALAPPDATA% 的清扫：只认每个应用目录下那几个标准缓存名（Cache、日志、临时、崩溃报告）。
    # 顶层名单里的是"不是缓存"的东西——已安装程序、UWP 应用状态、装了 SDK 和浏览器配置的 Microsoft
    # 目录，还有别的类别已经负责的位置，跳过它们既避免误删也避免同一块空间被重复计数。
    $localSkipTop = @(
        "Programs", "Packages", "Comms", "ConnectedDevicesPackages", "Microsoft",
        "Temp", "CrashDumps", "D3DSCache",
        "pip", "npm-cache", "pnpm-store", "pnpm-cache", "Yarn", "uv", "node-gyp",
        "ms-playwright", "pyppeteer"
    )
    $localCacheParts = @(
        "Cache", "Code Cache", "GPUCache", "GrShaderCache", "ShaderCache", "CachedData",
        "CachedExtensions", "blob_storage", "logs", "log", "tmp", "temp",
        "Crashpad", "CrashReports", "sentry", "SquirrelTemp"
    )

    function New-WinUtilLocalCacheRoots {
        $roots = @()
        foreach ($app in @(Get-ChildItem -LiteralPath $localAppData -Force -Directory -ErrorAction SilentlyContinue)) {
            # "Application Data" 这类junction指回自己，跟进去就把整层又数了一遍
            if ($app.Attributes -match "ReparsePoint") { continue }
            if ($localSkipTop -contains $app.Name) { continue }
            # *-updater 里的安装残留归「应用更新安装包残留」管
            if ($app.Name -like "*-updater") { continue }
            foreach ($part in $localCacheParts) {
                $roots += (Join-Path $app.FullName $part)
            }
        }
        if ($roots.Count -eq 0) {
            # 干净的镜像上应用目录还没长出来，退回通配符：扫不到东西也不会漏掉后来装的应用
            foreach ($part in $localCacheParts) { $roots += (Join-Path $localAppData (Join-Path "*" $part)) }
        }
        return $roots
    }

    $localCacheRoots = @(New-WinUtilLocalCacheRoots)

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
                      "$env:ProgramData\Microsoft\Windows\WER\ReportArchive",
                      "$localAppData\Microsoft\Windows\WER\ReportQueue",
                      "$localAppData\Microsoft\Windows\WER\ReportArchive",
                      "$localAppData\Microsoft\Windows\WER\Temp") }
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
        @{ Id = "AiChat"; Name = "AI 客户端缓存";
            Roots = $aiChatRoots }
        @{ Id = "AiCoder"; Name = "AI 编程工具缓存";
            Roots = $aiCoderRoots }
        @{ Id = "AiUpdater"; Name = "应用更新安装包残留";
            Roots = @("$localAppData\*-updater\pending")
            Files = @("$localAppData\*-updater\installer.exe") }
        @{ Id = "AiModels"; Name = "本地大模型文件";
            Roots = @("$env:USERPROFILE\.ollama\models",
                      "$env:USERPROFILE\.lmstudio\models",
                      "$env:USERPROFILE\.lms\models",
                      "$env:USERPROFILE\.cache\huggingface",
                      "$env:USERPROFILE\.cache\modelscope",
                      "$env:USERPROFILE\.ModelScope\hub") }
        @{ Id = "LocalCache"; Name = "AppData\Local 应用缓存";
            Roots = $localCacheRoots }
        @{ Id = "LocalNet"; Name = "系统与远程桌面缓存";
            Roots = @("$localAppData\Microsoft\Windows\INetCache",
                      "$localAppData\Microsoft\Windows\Temporary Internet Files",
                      "$localAppData\Microsoft\Terminal Server Client\Cache",
                      "$localAppData\Microsoft\Windows\History") }
        @{ Id = "LocalDev"; Name = "开发与自动化缓存";
            Roots = @("$localAppData\pip\cache",
                      "$localAppData\npm-cache",
                      "$localAppData\pnpm-store",
                      "$localAppData\pnpm-cache",
                      "$localAppData\uv\cache",
                      "$localAppData\node-gyp\Cache",
                      "$localAppData\Microsoft\NuGet",
                      "$localAppData\ms-playwright",
                      "$localAppData\pyppeteer") }
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
    $total = Measure-WinUtilJunkRoots -Roots $roots

    # Files 给的是单个文件（例如更新器留下的 installer.exe），目录引擎会跳过非容器，所以单独量
    foreach ($pattern in @($Def.Files | Where-Object { $_ })) {
        foreach ($item in @(Get-Item -Path $pattern -Force -ErrorAction SilentlyContinue)) {
            if ($item.PSIsContainer) { continue }
            $total += [long]$item.Length
        }
    }

    return $total
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

function Write-WinUtilDiskLog {

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
