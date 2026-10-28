function Invoke-WinUtilOverviewPopulate {
    <#
    .SYNOPSIS
        Fills the overview dashboard cards with live machine facts

    .DESCRIPTION
        Runs on the interface thread when the Overview tab is first opened or refreshed.
        Every probe is independently guarded: a fact that cannot be collected shows "-"
        instead of taking the whole dashboard down.
    #>

    if (-not $sync.ContainsKey("WPFOverviewComputer")) {
        return
    }

    $goodBrush = $sync.Form.Resources["ProgressBarForegroundColor"]
    $badBrush = $sync.Form.Resources["ProgressBarErrorColor"]

    $os = $null
    try { $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop } catch { }

    try { $sync.WPFOverviewComputer.Text = [string]$env:COMPUTERNAME } catch { }

    if ($os) {
        try {
            $build = ""
            if ($os.BuildNumber) { $build = "（Build $($os.BuildNumber)）" }
            $sync.WPFOverviewOS.Text = "$($os.Caption.Trim()) $build"
        } catch { }
        try {
            $up = (Get-Date) - $os.LastBootUpTime
            if ($up.Days -gt 0) {
                $sync.WPFOverviewUptime.Text = "$($up.Days) 天 $($up.Hours) 小时"
            } else {
                $sync.WPFOverviewUptime.Text = "$($up.Hours) 小时 $($up.Minutes) 分"
            }
        } catch { }
        try {
            $totalGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
            $usedGB = [math]::Round(($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1MB, 1)
            $sync.WPFOverviewMemory.Text = "$usedGB / $totalGB GB"
        } catch { }
    }

    try {
        $c = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction Stop
        if ($c) {
            $freeGB = [math]::Round($c.FreeSpace / 1GB, 1)
            $totalGB = [math]::Round($c.Size / 1GB, 1)
            $usedPct = 0
            if ($totalGB -gt 0) { $usedPct = [math]::Round((($totalGB - $freeGB) / $totalGB) * 100) }
            $sync.WPFOverviewDisk.Text = "$freeGB / $totalGB GB 剩余（已用 $usedPct%）"
        }
    } catch { }

    try {
        $ips = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object { $_.IPAddress -ne "127.0.0.1" -and $_.IPAddress -notlike "169.*" } |
            Sort-Object -Property InterfaceMetric |
            Select-Object -First 2
        if ($ips) {
            $sync.WPFOverviewIP.Text = (($ips | ForEach-Object { $_.IPAddress }) -join ", ")
        }
    } catch { }

    try {
        if ($sync.ContainsKey("PARAM_OFFLINE")) {
            $offline = $sync.PARAM_OFFLINE
        } else {
            $offline = $PARAM_OFFLINE
        }
    } catch { $offline = $false }
    try {
        if ($offline) {
            $sync.WPFOverviewNet.Text = "离线"
            $sync.WPFOverviewNet.Foreground = $badBrush
        } else {
            $sync.WPFOverviewNet.Text = "在线"
            $sync.WPFOverviewNet.Foreground = $goodBrush
        }
    } catch { }

    try {
        $wingetCmd = Get-Command winget -ErrorAction SilentlyContinue
        if ($wingetCmd) {
            $sync.WPFOverviewWinget.Text = "可用"
            $sync.WPFOverviewWinget.Foreground = $goodBrush
        } else {
            $sync.WPFOverviewWinget.Text = "未安装"
            $sync.WPFOverviewWinget.Foreground = $badBrush
        }
    } catch { }

    try {
        $chocoCmd = Get-Command choco -ErrorAction SilentlyContinue
        if ($chocoCmd) {
            $sync.WPFOverviewChoco.Text = "可用"
            $sync.WPFOverviewChoco.Foreground = $goodBrush
        } else {
            $sync.WPFOverviewChoco.Text = "未安装"
            $sync.WPFOverviewChoco.Foreground = $badBrush
        }
    } catch { }

    try {
        $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if ($isAdmin) {
            $sync.WPFOverviewAdmin.Text = "管理员"
            $sync.WPFOverviewAdmin.Foreground = $goodBrush
        } else {
            $sync.WPFOverviewAdmin.Text = "普通权限"
            $sync.WPFOverviewAdmin.Foreground = $badBrush
        }
    } catch { }

    try {
        $logPath = ""
        if ($sync.ContainsKey("logPath")) { $logPath = $sync.logPath }
        if ($logPath -and (Test-Path $logPath)) {
            $tail = Get-Content -Path $logPath -Tail 14 -ErrorAction Stop
            $lines = @()
            foreach ($entry in $tail) {
                $text = [string]$entry
                if ($text.Trim() -eq "") { continue }
                if ($text.Length -gt 160) { $text = $text.Substring(0, 160) + "…" }
                $lines += $text
            }
            if ($lines.Count -gt 0) {
                $sync.WPFOverviewActivity.Text = $lines -join "`n"
            } else {
                $sync.WPFOverviewActivity.Text = "暂无日志记录。"
            }
        } else {
            $sync.WPFOverviewActivity.Text = "日志文件尚未生成。"
        }
    } catch {
        try { $sync.WPFOverviewActivity.Text = "日志读取失败。" } catch { }
    }
}
