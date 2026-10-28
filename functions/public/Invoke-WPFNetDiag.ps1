function Get-WinUtilNetTargetInput {

    <#

    .SYNOPSIS
        The typed target, or the default gateway when the box is left empty

    #>

    param([switch]$AllowEmpty)

    $box = $sync["WPFFNetTarget"]
    $target = if ($box) { $box.Text.Trim() } else { "" }

    if ($target) { return $target }

    $gateways = (Get-WinUtilNetLocalAddresses).Gateways
    if (@($gateways).Count -gt 0) { return [string]$gateways[0] }
    if ($AllowEmpty) { return $null }

    Append-WinUtilNetLog -Message "请填写目标 IP 或域名（本机没有默认网关，无法自动填写）。" -Level "WARN"
    return $null
}

function Parse-WinUtilPortList {

    <#

    .SYNOPSIS
        Expands "80,443,1-1024" into the port numbers it stands for

    #>

    param([string]$Text, [int[]]$Default = @(21, 22, 23, 25, 53, 80, 135, 139, 443, 445, 1433, 1521, 3306, 3389, 5432, 5900, 6379, 8000, 8080, 8443, 9000, 37777, 554))

    if ([string]::IsNullOrWhiteSpace($Text)) { return $Default }

    $ports = New-Object System.Collections.Generic.List[int]
    foreach ($part in ($Text.Trim() -split '[,;、\s]+' | Where-Object { $_ })) {
        if ($part -match '^(\d+)$') {
            $value = [int]$matches[1]
            if ($value -ge 1 -and $value -le 65535) { $ports.Add($value) }
        } elseif ($part -match '^(\d+)[-~](\d+)$') {
            $from = [int]$matches[1]
            $to = [int]$matches[2]
            if ($from -lt 1 -or $to -gt 65535 -or $to -lt $from) { continue }
            if (($to - $from) -gt 2048) {
                Append-WinUtilNetLog -Message "端口范围 $part 超过 2048 个，已截断（请分段扫描）。" -Level "WARN"
                $to = $from + 2048
            }
            for ($p = $from; $p -le $to; $p++) { $ports.Add($p) }
        }
    }

    if ($ports.Count -eq 0) { return $Default }
    return @($ports | Select-Object -Unique)
}

function Invoke-WPFNetHealthRefresh {

    <#

    .SYNOPSIS
        Refreshes the overview cards

    #>

    Start-WinUtilJob -Name "网络总览" -Description "正在检查网络状态" -ScriptBlock {
        $health = Get-WinUtilNetHealth
        $sync.NetDiagHealth = $health

        Invoke-WPFUIThread -Parameters @{ Health = $health; Time = (Get-Date).ToString("HH:mm:ss") } -ScriptBlock {
            param($Health, $Time)
            foreach ($card in @("Local", "Gateway", "Dns", "DnsPing", "Internet", "Throughput", "Conns", "Adapter", "Uptime")) {
                $label = $sync["WPFOvNet$card"]
                if ($null -ne $label) {
                    $key = if ($card -eq "DnsPing") { "DnsResolve" } else { $card }
                    $label.Text = [string]$Health[$key]
                }
            }
            $stamp = $sync["WPFOvNetUpdated"]
            if ($null -ne $stamp) { $stamp.Text = "最后刷新 $Time" }
        }
        Append-WinUtilNetLog -Message "网络总览已刷新：网关 $($health.Gateway)；互联网 $($health.Internet)。"
    }
}

function Invoke-WPFNetPing {

    <#

    .SYNOPSIS
        Ping test against the typed target

    #>

    $target = Get-WinUtilNetTargetInput
    if (-not $target) { return }

    $count = 4
    $argBox = $sync["WPFFNetArg"]
    if ($argBox -and $argBox.Text.Trim() -match '^\d+$') { $count = [Math]::Min(20, [Math]::Max(1, [int]$argBox.Text.Trim())) }

    Start-WinUtilJob -Name "Ping" -Description "正在 Ping $target" -Parameters @{ Target = $target; Count = $count } -ScriptBlock {
        param($Target, $Count)

        Append-WinUtilNetLog -Message "Ping $Target（$Count 次）……"
        $result = Test-WinUtilPing -Target $Target -Count $Count -TimeoutMs 1000

        $lines = @($result.Rounds | ForEach-Object { "来自 {0} 的回复：时间={1}ms TTL={2}" -f $_.Address, $_.Round, $_.Ttl })
        foreach ($line in $lines) { Append-WinUtilNetLog -Message $line }

        if ($result.Received -eq 0) {
            Append-WinUtilNetLog -Message "无法访问目标（$($result.Error)）。请确认目标在线、网段正确、未被防火墙拦截 ICMP。" -Level "WARN"
            Show-WinUtilNetResults -Rows @() -EmptyText "Ping 无响应。"
            return
        }

        Append-WinUtilNetLog -Message ("统计：发送 {0} / 接收 {1} / 丢失 {2}%；最短 {3}ms 最长 {4}ms 平均 {5}ms 抖动 {6}ms" -f `
                    $result.Sent, $result.Received, $result.Loss, $result.Min, $result.Max, $result.Avg, $result.Jitter)

        Show-WinUtilNetResults -Rows @([pscustomobject]@{
            Name   = $Target
            Detail = "平均 $([Math]::Round($result.Avg,1)) ms · 抖动 $($result.Jitter) ms · 丢包 $($result.Loss)%"
            Status = if ($result.Loss -eq 0) { "正常" } elseif ($result.Loss -lt 10) { "轻微丢包" } else { "丢包严重" }
        })
    }
}

function Invoke-WPFNetTrace {

    <#

    .SYNOPSIS
        Route trace to the typed target

    #>

    $target = Get-WinUtilNetTargetInput
    if (-not $target) { return }

    Start-WinUtilJob -Name "路由追踪" -Description "正在追踪到 $target 的路径" -Parameters @{ Target = $target } -ScriptBlock {
        param($Target)

        Append-WinUtilNetLog -Message "路由追踪 $Target……"
        $trace = Start-WinUtilTraceRoute -Target $Target -MaxHops 20

        $rows = @()
        foreach ($hop in $trace.Hops) {
            $detail = if ($hop.Address -eq "*") { "请求超时" } else { "$($hop.Round) ms" }
            Append-WinUtilNetLog -Message ("{0,2}  {1,-16} {2}" -f $hop.Hop, $hop.Address, $detail)
            $rows += [pscustomobject]@{
                Name   = "第 $($hop.Hop) 跳"
                Detail = "$($hop.Address)　$detail"
                Status = if ($hop.Address -eq "*") { "超时" } else { "可达" }
            }
        }

        Show-WinUtilNetResults -Rows $rows
        Append-WinUtilNetLog -Message "追踪结束：$Target（$($trace.Resolved)）共 $($trace.Hops.Count) 跳。"
    }
}

function Invoke-WPFNetPortScan {

    <#

    .SYNOPSIS
        TCP connect scan of the typed target

    #>

    $target = Get-WinUtilNetTargetInput
    if (-not $target) { return }

    $argBox = $sync["WPFFNetArg"]
    $ports = Parse-WinUtilPortList -Text $(if ($argBox) { $argBox.Text } else { "" })

    Start-WinUtilJob -Name "端口扫描" -Description "正在扫描 $target 的 $($ports.Count) 个端口" -Parameters @{ Target = $target; Ports = $ports } -ScriptBlock {
        param($Target, $Ports)

        Append-WinUtilNetLog -Message "扫描 $Target 的 $($Ports.Count) 个端口……"
        $open = Search-WinUtilOpenPorts -Targets @($Target) -Ports $Ports -TimeoutMs 800 -OnProgress {
            param($Done, $Total)
            Step-WinUtilJob -Status "正在扫描 $Target（$Done/$Total）" -Percent (5 + [int](90 * $Done / $Total))
        }

        $rows = @($open | ForEach-Object {
            [pscustomobject]@{
                Name   = "端口 $($_.Port)"
                Detail = Get-WinUtilNetPortHint -Port $_.Port
                Status = "开放"
            }
        })

        Show-WinUtilNetResults -Rows $rows -EmptyText "$Target 未发现开放端口（也可能被防火墙拦截）。"
        Append-WinUtilNetLog -Message "端口扫描完成：$Target 开放 $($rows.Count) 个端口。"
    }
}

function Get-WinUtilNetPortHint {

    <#

    .SYNOPSIS
        What a port number means to the people using this tool

    #>

    param([int]$Port)

    switch ($Port) {
        21 { "FTP 文件传输" }
        22 { "SSH 远程管理" }
        23 { "Telnet 明文远程（建议停用）" }
        25 { "SMTP 邮件" }
        53 { "DNS 解析" }
        80 { "HTTP 网页" }
        135 { "Windows RPC" }
        139 { "NetBIOS 会话（建议停用）" }
        443 { "HTTPS 网页" }
        445 { "SMB 文件共享（勒索病毒主要入口）" }
        554 { "RTSP 视频流（网络摄像头）" }
        1433 { "SQL Server 数据库" }
        3306 { "MySQL 数据库" }
        3389 { "远程桌面" }
        5900 { "VNC 远程桌面" }
        8000 { "HTTP 备用端口（多数 IPC 后台）" }
        8080 { "HTTP 代理/管理后台" }
        8088 { "HTTP 管理后台（大华常用）" }
        37777 { "DVR 私有协议（大华）" }
        9100 { "打印机 RAW 端口（小票打印机改 IP 用这个）" }
        default { "未知服务" }
    }
}

function Invoke-WPFNetSession {

    <#

    .SYNOPSIS
        Concurrent connection test against a service port

    #>

    $target = Get-WinUtilNetTargetInput
    if (-not $target) { return }

    $argBox = $sync["WPFFNetArg"]
    $text = if ($argBox) { $argBox.Text.Trim() } else { "" }

    $port = 0
    $sessions = 20
    if ($text -match '^(\d+)\s*[,;:]\s*(\d+)$') {
        $port = [int]$matches[1]
        $sessions = [Math]::Min(200, [int]$matches[2])
    } elseif ($text -match '^\d+$') {
        $port = [int]$text
    }

    if ($port -lt 1 -or $port -gt 65535) {
        Append-WinUtilNetLog -Message "请在参数框填写端口，或「端口,并发数」（如 9100,50）。" -Level "WARN"
        return
    }

    Start-WinUtilJob -Name "会话测试" -Description "正在对 $target`:$port 建立 $sessions 个并发连接" -Parameters @{ Target = $target; Port = $port; Sessions = $sessions } -ScriptBlock {
        param($Target, $Port, $Sessions)

        Append-WinUtilNetLog -Message "向 $Target`:$Port 同时建立 $Sessions 个连接……"
        $result = Test-WinUtilConcurrentSessions -Target $Target -Port $Port -Sessions $Sessions

        $rate = [Math]::Round(100 * $result.Succeeded / $result.Requested, 1)
        Append-WinUtilNetLog -Message "成功 $($result.Succeeded)/$($result.Requested)（$rate%），耗时 $($result.Milliseconds) ms。"

        Show-WinUtilNetResults -Rows @([pscustomobject]@{
            Name   = "$Target`:$Port"
            Detail = "并发 $($result.Requested) · 成功 $($result.Succeeded) · 耗时 $($result.Milliseconds) ms"
            Status = if ($rate -eq 100) { "正常" } elseif ($rate -ge 80) { "部分失败" } else { "服务承压" }
        })
    }
}

function Invoke-WPFNetResolve {

    <#

    .SYNOPSIS
        Forward and reverse name lookup

    #>

    $target = Get-WinUtilNetTargetInput -AllowEmpty
    if (-not $target) { return }

    Start-WinUtilJob -Name "DNS" -Description "正在解析 $target" -Parameters @{ Target = $target } -ScriptBlock {
        param($Target)

        $result = Resolve-WinUtilNetName -Target $Target
        if ($result.Error) {
            Append-WinUtilNetLog -Message "解析 $Target 失败：$($result.Error)" -Level "WARN"
            return
        }

        $rows = @([pscustomobject]@{
            Name   = $Target
            Detail = "$(($result.Addresses | Select-Object -Unique) -join '、')　反向：$(if ($result.HostName) { $result.HostName } else { '无记录' })"
            Status = "已解析"
        })
        Show-WinUtilNetResults -Rows $rows
        Append-WinUtilNetLog -Message "$Target → $(($result.Addresses | Select-Object -Unique) -join '、')"
    }
}

function Invoke-WPFNetWan {

    <#

    .SYNOPSIS
        Internet latency, loss and download rate

    #>

    $target = Get-WinUtilNetTargetInput -AllowEmpty
    Start-WinUtilJob -Name "外网测速" -Description "正在测试外网质量" -Parameters @{ Target = $target } -ScriptBlock {
        param($Target)

        $probe = if ($Target) { $Target } else { "223.5.5.5" }
        Append-WinUtilNetLog -Message "外网质量测试：目标 $probe（延迟/抖动/丢包）……"
        $ping = Test-WinUtilPing -Target $probe -Count 10 -TimeoutMs 1500

        if ($ping.Received -eq 0) {
            Append-WinUtilNetLog -Message "外网不可达（本机处于离线网络属正常情况）。内网带宽请用「内网共享测速」。" -Level "WARN"
            Show-WinUtilNetResults -Rows @() -EmptyText "外网不可达，无法测速。"
            return
        }

        Append-WinUtilNetLog -Message ("延迟：平均 {0} ms（最短 {1} / 最长 {2}）· 抖动 {3} ms · 丢包 {4}%" -f `
                    $ping.Avg, $ping.Min, $ping.Max, $ping.Jitter, $ping.Loss)

        $quality = if ($ping.Loss -eq 0 -and $ping.Avg -lt 60) { "良好" } elseif ($ping.Loss -lt 5 -and $ping.Avg -lt 150) { "一般" } else { "较差" }

        $rows = @([pscustomobject]@{
            Name   = "外网延迟 $probe"
            Detail = "平均 $([Math]::Round($ping.Avg,1)) ms · 抖动 $($ping.Jitter) ms · 丢包 $($ping.Loss)%"
            Status = $quality
        })

        # Download throughput needs a real file; the domestic mirrors below are only tried when
        # the machine actually has internet, which the ping above just proved.
        foreach ($url in @("https://dldir1.qq.com/qqfile/qq/QQNT/Windows/QQNT.exe", "https://mirrors.aliyun.com/ubuntu/ls-lR.gz")) {
            try {
                Append-WinUtilNetLog -Message "下载测速：$url"
                $down = Measure-WinUtilHttpDownload -Url $url -MaxMb 16 -TimeoutSec 25
                Append-WinUtilNetLog -Message ("实测下载 {0}（{1}，{2:N1} 秒）" -f `
                            (Format-WinUtilNetBitRate $down.BytesPerSecond), (Format-WinUtilNetBytesPerSecond $down.BytesPerSecond), $down.Seconds)
                $rows += [pscustomobject]@{
                    Name   = "外网下载"
                    Detail = "{0} · {1}" -f (Format-WinUtilNetBitRate $down.BytesPerSecond), (Format-WinUtilNetBytesPerSecond $down.BytesPerSecond)
                    Status = "已测"
                }
                break
            } catch {
                Append-WinUtilNetLog -Message "该测速地址不可用：$($_.Exception.Message)" -Level "WARN"
            }
        }

        Show-WinUtilNetResults -Rows $rows
    }
}

function Invoke-WPFNetLan {

    <#

    .SYNOPSIS
        Throughput to a company share, which is the number that matters offline

    #>

    $box = $sync["WPFFNetLanPath"]
    $path = if ($box) { $box.Text.Trim() } else { "" }
    if (-not $path) {
        # The box is prefilled from the share list when the tab is built, so an empty one means the
        # operator cleared it deliberately and wants a different server
        Append-WinUtilNetLog -Message "请填写内网共享路径（例如 \\fileserver\share）。" -Level "WARN"
        return
    }

    Start-WinUtilJob -Name "内网测速" -Description "正在测试 $path 的读写吞吐" -Parameters @{ Path = $path } -ScriptBlock {
        param($Path)

        Append-WinUtilNetLog -Message "向 $Path 写入并读取 32 MB 临时文件……"
        try {
            $result = Measure-WinUtilShareThroughput -Path $Path -SizeMb 32
        } catch {
            Append-WinUtilNetLog -Message "内网测速失败：$($_.Exception.Message)" -Level "ERROR"
            return
        }

        Append-WinUtilNetLog -Message ("写入 {0}（{1:N2} 秒）· 读取 {2}（{3:N2} 秒）" -f `
                    (Format-WinUtilNetBytesPerSecond $result.WriteBps), $result.WriteSeconds,
                    (Format-WinUtilNetBytesPerSecond $result.ReadBps), $result.ReadSeconds)

        $speed = "写 {0} / 读 {1}（{2}）" -f (Format-WinUtilNetBytesPerSecond $result.WriteBps),
        (Format-WinUtilNetBytesPerSecond $result.ReadBps), (Format-WinUtilNetBitRate $result.ReadBps)

        Show-WinUtilNetResults -Rows @([pscustomobject]@{
            Name   = $Path
            Detail = $speed
            Status = "完成"
        })
    }
}

function Invoke-WPFNetHosts {

    <#

    .SYNOPSIS
        Live host discovery over the local /24

    #>

    $box = $sync["WPFFNetSubnet"]
    $prefix = Get-WinUtilNetScanSubnet -Text $(if ($box) { $box.Text } else { "" })
    if (-not $prefix) {
        Append-WinUtilNetLog -Message "无法确定网段，请在「网段」框填写前三段（如 192.168.1）。" -Level "WARN"
        return
    }

    Start-WinUtilJob -Name "主机发现" -Description "正在扫描 $prefix.0/24" -Parameters @{ Prefix = $prefix } -ScriptBlock {
        param($Prefix)

        Append-WinUtilNetLog -Message "扫描网段 $prefix.0/24（254 个地址）……"
        $hosts = Search-WinUtilLiveHosts -Prefix $Prefix -OnProgress {
            param($Done, $Total)
            Step-WinUtilJob -Status "正在扫描 $prefix（$Done/$Total）" -Percent (5 + [int](90 * $Done / $Total))
        }

        $rows = @($hosts | ForEach-Object {
            [pscustomobject]@{
                Name   = $_.Address
                Detail = "MAC $($_.Mac) · $($_.Round) ms · TTL $($_.Ttl)"
                Status = "在线"
            }
        })

        Show-WinUtilNetResults -Rows $rows -EmptyText "$prefix.0/24 未发现其他在线主机。"
        $sync.NetDiagLiveHosts = $hosts
        Append-WinUtilNetLog -Message "主机发现完成：$($rows.Count) 台在线（含本机）。"
    }
}

function Invoke-WPFNetCamera {

    <#

    .SYNOPSIS
        Network camera inventory over the local /24

    #>

    $box = $sync["WPFFNetSubnet"]
    $prefix = Get-WinUtilNetScanSubnet -Text $(if ($box) { $box.Text } else { "" })
    if (-not $prefix) {
        Append-WinUtilNetLog -Message "无法确定网段，请在「网段」框填写前三段（如 192.168.1）。" -Level "WARN"
        return
    }

    Start-WinUtilJob -Name "摄像头扫描" -Description "正在盘点 $prefix.0/24 的网络摄像设备" -Parameters @{ Prefix = $prefix } -ScriptBlock {
        param($Prefix)

        $hosts = $sync.NetDiagLiveHosts
        if (-not $hosts -or @($hosts).Count -eq 0) {
            Append-WinUtilNetLog -Message "先做一轮主机发现……"
            $hosts = Search-WinUtilLiveHosts -Prefix $Prefix -OnProgress {
                param($Done, $Total)
                Step-WinUtilJob -Status "正在发现主机（$Done/$Total）" -Percent [int](30 * $Done / $Total)
            }
            $sync.NetDiagLiveHosts = $hosts
        }

        Append-WinUtilNetLog -Message "在 $($hosts.Count) 台在线主机上查找摄像/录像设备端口……"
        $rows = Search-WinUtilIpCameras -Prefix $Prefix -LiveHosts $hosts -OnProgress {
            param($Done, $Total)
            Step-WinUtilJob -Status "正在识别设备（$Done/$Total）" -Percent (30 + [int](65 * $Done / $Total))
        }

        Show-WinUtilNetResults -Rows $rows -EmptyText "本网段未发现网络摄像/录像设备。"
        Append-WinUtilNetLog -Message "摄像设备盘点完成：$(@($rows).Count) 台。"
    }
}

function Invoke-WPFNetDhcp {

    <#

    .SYNOPSIS
        How each adapter got its address

    #>

    Start-WinUtilJob -Name "DHCP" -Description "正在检查地址分配情况" -ScriptBlock {
        $rows = @(Get-WinUtilDhcpReport)
        Show-WinUtilNetResults -Rows $rows -EmptyText "未发现启用 IP 的网络适配器。"
        foreach ($row in $rows) { Append-WinUtilNetLog -Message "$($row.Name)：$($row.Detail)" }
        Append-WinUtilNetLog -Message "DHCP 检查完成。"
    }
}

function Invoke-WPFNetAudit {

    <#

    .SYNOPSIS
        Local network exposure self test

    #>

    Start-WinUtilJob -Name "安全自测" -Description "正在检查本机网络暴露面" -ScriptBlock {
        $rows = @(Invoke-WinUtilNetSecurityAudit)
        $risks = @($rows | Where-Object { $_.Status -eq "风险" })

        Show-WinUtilNetResults -Rows $rows
        foreach ($row in $rows) { Append-WinUtilNetLog -Message "[$($row.Status)] $($row.Name)：$($row.Detail)" }

        if ($risks.Count -eq 0) {
            Append-WinUtilNetLog -Message "安全自测完成：未发现高风险项。"
        } else {
            Append-WinUtilNetLog -Message "安全自测完成：$($risks.Count) 项高风险，建议联系信息部处理。" -Level "WARN"
        }
    }
}

function Invoke-WPFNetEvents {

    <#

    .SYNOPSIS
        Recent network-related system events

    #>

    Start-WinUtilJob -Name "网络事件" -Description "正在读取网络相关系统日志" -ScriptBlock {
        $rows = @(Get-WinUtilNetEventLog)
        Show-WinUtilNetResults -Rows $rows -EmptyText "近 3 天没有网络相关的系统事件。"
        Append-WinUtilNetLog -Message "读取到 $($rows.Count) 条网络相关系统事件（近 3 天）。"
    }
}

function Invoke-WPFNetDnsBenchmark {

    <#

    .SYNOPSIS
        Ranks the neutral DNS providers by how fast they answer

    #>

    Start-WinUtilJob -Name "DNS 测速" -Description "正在测量各 DNS 服务器的响应速度" -ScriptBlock {
        Append-WinUtilNetLog -Message "测量各 DNS 服务商 53 端口往返时间……"

        $ranked = @(Get-WinUtilDNSBenchmark)
        $rows = @()
        for ($i = 0; $i -lt $ranked.Count; $i++) {
            $entry = $ranked[$i]
            $rows += [pscustomobject]@{
                Name   = "$($entry.Provider)（$($entry.PrimaryIP)）"
                Detail = if ($entry.LatencyMs -ge 9999) { "53 端口无响应" } else { "往返 $($entry.LatencyMs) ms" }
                Status = if ($entry.LatencyMs -ge 9999) { "不可达" } elseif ($i -eq 0) { "最快" } else { "可用" }
            }
        }

        Show-WinUtilNetResults -Rows $rows -EmptyText "本机没有可测速的 DNS 配置。"
        if ($rows.Count) { Append-WinUtilNetLog -Message "DNS 测速完成：最快为 $($rows[0].Name)，$($rows[0].Detail)。" }
    }
}

function Invoke-WPFNetPorts {

    <#

    .SYNOPSIS
        Which program is holding which port on this machine

    #>

    Start-WinUtilJob -Name "端口占用" -Description "正在列出本机端口与对应程序" -ScriptBlock {
        # CIM rather than Get-Process: the listener often belongs to a service process that
        # Get-Process will not return
        $names = @{}
        foreach ($process in (Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) {
            if (-not $names.ContainsKey([int]$process.ProcessId)) { $names[[int]$process.ProcessId] = $process.Name }
        }

        $seen = @{}
        $rows = @()
        foreach ($conn in (Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Sort-Object LocalPort)) {
            $key = "$($conn.LocalAddress):$($conn.LocalPort)"
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true

            # OwningProcess comes back as UInt32; a hashtable keyed by Int32 will not find it
            $ownerPid = [int]$conn.OwningProcess
            $owner = if ($names.ContainsKey($ownerPid)) { $names[$ownerPid] } else { "进程 $ownerPid" }
            $public = $conn.LocalAddress -notin @("127.0.0.1", "::1")
            $rows += [pscustomobject]@{
                Name   = "端口 $($conn.LocalPort)"
                Detail = "$owner · $key · $((Get-WinUtilNetPortHint -Port $conn.LocalPort))"
                Status = if ($public) { "对网段开放" } else { "仅本机" }
            }
        }

        Show-WinUtilNetResults -Rows $rows -EmptyText "本机没有处于监听状态的 TCP 端口。"
        Append-WinUtilNetLog -Message "端口占用列表完成：$($rows.Count) 个监听端口。"
    }
}

function Invoke-WPFNetPktStart {

    <#

    .SYNOPSIS
        Starts a pktmon capture

    #>

    if ($sync.PktmonRunning) {
        Append-WinUtilNetLog -Message "抓包已在进行中，请先「停止并分析」。" -Level "WARN"
        return
    }

    $argBox = $sync["WPFFNetPktFilter"]
    $ports = @()
    if ($argBox -and $argBox.Text.Trim()) {
        foreach ($part in ($argBox.Text.Trim() -split '[,;、\s]+' | Where-Object { $_ -match '^\d+$' })) {
            $ports += [int]$part
        }
    }

    $seconds = 0
    $secBox = $sync["WPFFNetPktSeconds"]
    if ($secBox -and $secBox.Text.Trim() -match '^\d+$') { $seconds = [int]$secBox.Text.Trim() }

    try {
        $file = Start-WinUtilPktmonCapture -Ports $ports
    } catch {
        Append-WinUtilNetLog -Message "抓包启动失败：$($_.Exception.Message)" -Level "ERROR"
        return
    }

    $sync.PktmonRunning = $true
    if ($ports.Count) {
        Append-WinUtilNetLog -Message "抓包已开始（仅端口 $($ports -join ', ')）：$file"
    } else {
        Append-WinUtilNetLog -Message "抓包已开始（全部报文）：$file"
    }

    if ($seconds -gt 0) {
        Start-WinUtilJob -Name "抓包" -Description "抓包 $seconds 秒后自动停止" -Parameters @{ Seconds = $seconds } -ScriptBlock {
            param($Seconds)
            for ($left = $Seconds; $left -gt 0; $left -= 5) {
                Step-WinUtilJob -Status "正在抓包，剩余 $([Math]::Max(0, $left)) 秒" -Percent ([int](100 * ($Seconds - $left) / $Seconds))
                Start-Sleep -Seconds ([Math]::Min(5, $left))
            }
            Invoke-WPFNetPktStopInternal
        }
    } else {
        Append-WinUtilNetLog -Message "复现问题后点击「停止并分析」。"
    }
}

function Invoke-WPFNetPktStop {
    Invoke-WPFNetPktStopInternal
}

function Invoke-WPFNetPktStopInternal {

    <#

    .SYNOPSIS
        Stops the capture and shows the per-flow summary

    #>

    if (-not $sync.PktmonRunning) {
        Append-WinUtilNetLog -Message "当前没有进行中的抓包。" -Level "WARN"
        return
    }
    $sync.PktmonRunning = $false

    Start-WinUtilJob -Name "抓包分析" -Description "正在转换并分析抓包结果" -ScriptBlock {
        Append-WinUtilNetLog -Message "停止抓包并转换文本……"
        try {
            $result = Stop-WinUtilPktmonCapture
        } catch {
            Append-WinUtilNetLog -Message "停止抓包失败：$($_.Exception.Message)" -Level "ERROR"
            return
        }

        if (-not $result -or -not $result.File) {
            Append-WinUtilNetLog -Message "未找到抓包文件，可能抓包时间过短。" -Level "WARN"
            return
        }

        Append-WinUtilNetLog -Message "抓包文件：$($result.File)"
        if ($result.Text) { Append-WinUtilNetLog -Message "文本明细：$($result.Text)" }
        if ($result.Error) { Append-WinUtilNetLog -Message "文本转换未成功：$($result.Error)" -Level "WARN" }

        $report = $result.Report
        if (-not $report -or $report.Packets -eq 0) {
            Append-WinUtilNetLog -Message "未解析到报文（抓包时间过短，或本机 pktmon 输出格式不同），可用文本文件人工查看。" -Level "WARN"
            Show-WinUtilNetResults -Rows @() -EmptyText "未能解析报文，请打开文本文件查看。"
            return
        }

        if ($report.Matched -eq 0) {
            Append-WinUtilNetLog -Message "共 $($report.Packets) 个报文，但本机 pktmon 的文本格式与解析器不匹配，请查看文本明细。" -Level "WARN"
            Show-WinUtilNetResults -Rows @() -EmptyText "共 $($report.Packets) 个报文，未能归纳会话，请打开文本明细查看。"
            return
        }

        Append-WinUtilNetLog -Message "共解析 $($report.Packets) 个报文（$($report.Matched) 个可归类，合计 $(Format-WinUtilNetBytes $report.Bytes)），$(@($report.Flows).Count) 条会话。"
        Show-WinUtilNetResults -Rows $report.Flows
    }
}

function Invoke-WPFNetPktOpen {

    <#

    .SYNOPSIS
        Opens the capture folder in Explorer

    #>

    Start-Process explorer.exe -ArgumentList (Get-WinUtilPktmonDir)
}
