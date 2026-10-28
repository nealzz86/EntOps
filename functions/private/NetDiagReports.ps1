function Get-WinUtilNetHealth {

    <#

    .SYNOPSIS
        One pass over everything the overview cards show

    .DESCRIPTION
        Runs in a job: the connectivity pings and the one second throughput sample together take
        a couple of seconds, which is exactly what must not happen on the interface thread.

    #>

    $local = Get-WinUtilNetLocalAddresses

    $health = @{
        Local      = "--"
        Gateway    = "--"
        Dns        = "--"
        DnsResolve = "--"
        Internet   = "--"
        Throughput = "--"
        Conns      = "--"
        Adapter    = "--"
        Uptime     = "--"
    }

    if (@($local.IPv4).Count -gt 0) {
        $health.Local = ($local.IPv4 | ForEach-Object { "{0}/{1}" -f $_.IPAddress, $_.Prefix }) -join "、"
    }

    if (@($local.Adapters).Count -gt 0) {
        $health.Adapter = ($local.Adapters | ForEach-Object { "{0}（{1}）" -f $_.Name, $_.LinkSpeed }) -join "、"
    }

    $gateway = if (@($local.Gateways).Count -gt 0) { $local.Gateways[0] } else { $null }
    if ($gateway) {
        $probe = Test-WinUtilPing -Target $gateway -Count 2 -TimeoutMs 800
        $health.Gateway = if ($probe.Received -gt 0) { "正常 $([Math]::Round($probe.Avg,0)) ms（$gateway）" } else { "不通（$gateway）" }
    } else {
        $health.Gateway = "无默认网关"
    }

    if (@($local.Dns).Count -gt 0) {
        $health.Dns = $local.Dns -join "、"
        $probe = Test-WinUtilPing -Target $local.Dns[0] -Count 2 -TimeoutMs 800
        $health.DnsResolve = if ($probe.Received -gt 0) { "可达 $([Math]::Round($probe.Avg,0)) ms" } else { "不可达" }
    } else {
        $health.Dns = "未配置"
    }

    # A name lookup is the honest internet test here: it works through a proxy-only network and
    # fails loudly on an isolated one, without depending on any one site being up.
    try {
        $null = [System.Net.Dns]::GetHostAddresses("www.baidu.com")
        $probe = Test-WinUtilPing -Target "223.5.5.5" -Count 2 -TimeoutMs 1000
        $health.Internet = if ($probe.Received -gt 0) { "可访问 $([Math]::Round($probe.Avg,0)) ms" } else { "解析成功但 ICMP 受限" }
    } catch {
        $health.Internet = "不可访问（离线）"
    }

    $before = (Get-NetAdapterStatistics -ErrorAction SilentlyContinue | Measure-Object -Property ReceivedBytes, SentBytes -Sum)
    $rx1 = [int64](($before | Where-Object { $_.Property -eq "ReceivedBytes" }).Sum)
    $tx1 = [int64](($before | Where-Object { $_.Property -eq "SentBytes" }).Sum)
    Start-Sleep -Seconds 1
    $after = (Get-NetAdapterStatistics -ErrorAction SilentlyContinue | Measure-Object -Property ReceivedBytes, SentBytes -Sum)
    $rx2 = [int64](($after | Where-Object { $_.Property -eq "ReceivedBytes" }).Sum)
    $tx2 = [int64](($after | Where-Object { $_.Property -eq "SentBytes" }).Sum)
    $health.Throughput = "↓ {0}  ↑ {1}" -f (
        (Format-WinUtilNetBytesPerSecond ([Math]::Max(0, $rx2 - $rx1))),
        (Format-WinUtilNetBytesPerSecond ([Math]::Max(0, $tx2 - $tx1))))

    $listen = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue).Count
    $established = @(Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue).Count
    $health.Conns = "监听 $listen · 已建立 $established"

    $health.Uptime = (Get-WinUtilUptimeText)

    return $health
}

function Get-WinUtilUptimeText {

    <#

    .SYNOPSIS
        How long the machine has been up, in the way an operator reads it

    #>

    try {
        $boot = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime
        $span = (Get-Date) - $boot
        if ($span.Days -gt 0) { return "{0} 天 {1} 小时" -f $span.Days, $span.Hours }
        return "{0} 小时 {1} 分" -f $span.Hours, $span.Minutes
    } catch {
        return "--"
    }
}

function Get-WinUtilDhcpReport {

    <#

    .SYNOPSIS
        How each adapter got its address, and when the lease runs out

    #>

    $rows = @()

    foreach ($config in (Get-CimInstance Win32_NetworkAdapterConfiguration -Filter "IPEnabled=True" -ErrorAction SilentlyContinue)) {
        $lease = "无"
        if ($config.DhcpEnabled -and $config.DhcpLeaseObtained) {
            $obtained = [System.Management.ManagementDateTimeConverter]::ToDateTime($config.DhcpLeaseObtained)
            $lease = "取得 {0}" -f $obtained.ToString("MM-dd HH:mm")
            if ($config.DhcpLeaseExpires) {
                try {
                    $expires = [System.Management.ManagementDateTimeConverter]::ToDateTime($config.DhcpLeaseExpires)
                    $lease += "，{0} 到期" -f $expires.ToString("MM-dd HH:mm")
                    if (($expires - (Get-Date)).TotalHours -lt 6) { $lease += "（即将到期）" }
                } catch { }
            }
        }

        $server = if ($config.DhcpServer) { $config.DhcpServer } else { "静态地址" }
        $rows += [pscustomobject]@{
            Name   = $config.Description
            Detail = "DHCP 服务器 $server · 租约 $lease"
            Status = if ($config.DhcpEnabled) { "动态" } else { "静态" }
        }
    }

    return $rows
}

function Invoke-WinUtilNetSecurityAudit {

    <#

    .SYNOPSIS
        Checks the machine's own network exposure against what a unit's terminal should look like

    .DESCRIPTION
        Read only. It reports what is exposed and how to close it, and changes nothing, so an
        operator can run it on a colleague's machine without explaining a side effect afterwards.

    #>

    $rows = @()

    foreach ($profile in (Get-NetFirewallProfile -ErrorAction SilentlyContinue)) {
        $rows += [pscustomobject]@{
            Name   = "防火墙 - $($profile.Name)"
            Detail = if ($profile.Enabled) { "已启用（默认动作：入站阻止）" } else { "已关闭，本机端口对全网段可见" }
            Status = if ($profile.Enabled) { "正常" } else { "风险" }
        }
    }

    $dangerousPorts = @{
        135 = "RPC"; 139 = "NetBIOS"; 445 = "SMB 文件共享"; 3389 = "远程桌面"; 5900 = "VNC"; 23 = "Telnet"; 21 = "FTP"
    }
    $listening = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
        Where-Object { $_.LocalAddress -ne "127.0.0.1" -and $_.LocalAddress -notlike "169.254.*" -and $_.LocalAddress -ne "::1" } |
        Select-Object -ExpandProperty LocalPort -Unique | Sort-Object)

    foreach ($port in $listening) {
        $isRisk = $dangerousPorts.ContainsKey([int]$port)
        $rows += [pscustomobject]@{
            Name   = "监听端口 $port"
            Detail = if ($isRisk) { "$($dangerousPorts[[int]$port])，对本机所在网段开放" } else { "由本机服务监听，确认是否为已知软件" }
            Status = if ($isRisk) { "风险" } else { "提示" }
        }
    }

    $smb = Get-SmbServerConfiguration -ErrorAction SilentlyContinue
    if ($smb) {
        $rows += [pscustomobject]@{
            Name   = "SMBv1 协议"
            Detail = if ($smb.EnableSmb1Protocol) { "仍启用，可被勒索病毒利用（WannaCry 类）" } else { "已关闭" }
            Status = if ($smb.EnableSmb1Protocol) { "风险" } else { "正常" }
        }
    }

    foreach ($share in (Get-SmbShare -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike "*$" })) {
        $everyone = @(Get-SmbShareAccess -Name $share.Name -ErrorAction SilentlyContinue | Where-Object { $_.AccountName -eq "Everyone" -and $_.AccessRight -ne "None" })
        $rows += [pscustomobject]@{
            Name   = "共享 $($share.Name)"
            Detail = if ($everyone.Count) { "Everyone 具有 $((($everyone | Select-Object -First 1).AccessRight)) 权限" } else { "仅授权账户可访问" }
            Status = if ($everyone.Count) { "风险" } else { "正常" }
        }
    }

    $rdp = Get-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server" -Name fDenyTSConnections -ErrorAction SilentlyContinue
    if ($null -ne $rdp) {
        $open = ($rdp.fDenyTSConnections -eq 0)
        $nla = Get-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" -Name UserAuthentication -ErrorAction SilentlyContinue
        $rows += [pscustomobject]@{
            Name   = "远程桌面"
            Detail = if ($open) { "已开启（网络级别认证 NLA：{0}）" -f $(if ($nla -and $nla.UserAuthentication -eq 1) { "已启用" } else { "未启用，建议开启" }) } else { "已关闭" }
            Status = if ($open) { "提示" } else { "正常" }
        }
    }

    $auto = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" -ErrorAction SilentlyContinue
    if ($auto) {
        $names = @($auto.PSObject.Properties | Where-Object { $_.Name -notlike "PS*" } | Select-Object -ExpandProperty Name)
        $rows += [pscustomobject]@{
            Name   = "开机自启项"
            Detail = if ($names.Count) { ($names -join "、") } else { "无" }
            Status = "提示"
        }
    }

    return $rows
}

function Search-WinUtilIpCameras {

    <#

    .SYNOPSIS
        Finds network cameras and video recorders answering on a subnet

    .DESCRIPTION
        Asset inventory for the unit's own network: it looks for the ports the common domestic
        IPC brands serve, then asks those ports what they are so the list carries a model hint
        rather than a bare IP.

    #>

    param(
        [Parameter(Mandatory)][string]$Prefix,
        [object[]]$LiveHosts,
        [scriptblock]$OnProgress
    )

    $cameraPorts = @(554, 80, 443, 8000, 8080, 8088, 8899, 37777, 5000, 3000)

    if (-not $LiveHosts) {
        $LiveHosts = Search-WinUtilLiveHosts -Prefix $Prefix -OnProgress $OnProgress
    }

    $targets = @($LiveHosts | Select-Object -ExpandProperty Address)
    if ($targets.Count -eq 0) { return @() }

    $open = Search-WinUtilOpenPorts -Targets $targets -Ports $cameraPorts -TimeoutMs 500

    $rows = @()
    $byHost = $open | Group-Object Target
    foreach ($group in $byHost) {
        $ports = @($group.Group | Select-Object -ExpandProperty Port | Sort-Object)
        $brand = "网络摄像/视频设备"
        try {
            foreach ($httpPort in ($ports | Where-Object { $_ -in @(80, 8080, 8088, 443, 5000, 8899) } | Select-Object -First 1)) {
                $scheme = if ($httpPort -eq 443) { "https" } else { "http" }
                $probe = Invoke-WebRequest -Uri "${scheme}://$($group.Name):$httpPort/" -TimeoutSec 4 -UseBasicParsing -ErrorAction SilentlyContinue
                $server = $probe.Headers["Server"]
                $auth = $probe.Headers["WWW-Authenticate"]
                $head = if ($probe.Content) { $probe.Content.Substring(0, [Math]::Min(600, $probe.Content.Length)) } else { "" }
                $signature = "$server $auth $head"
                if ($signature -match "(?i)hikvision|webcomponents|doc/page/login") { $brand = "海康威视 IPC/NVR" }
                elseif ($signature -match "(?i)dahua|web3.0|dws") { $brand = "大华 IPC/NVR" }
                elseif ($signature -match "(?i)uniview|unv") { $brand = "宇视 IPC/NVR" }
                elseif ($signature -match "(?i)tp-link|tl-c") { $brand = "TP-LINK 摄像机" }
                elseif ($signature -match "(?i)xiaomi|miio|mijia") { $brand = "小米摄像机" }
                elseif ($signature -match "(?i)reolink") { $brand = "Reolink 摄像机" }
                break
            }
        } catch { }

        $rows += [pscustomobject]@{
            Name   = $group.Name
            Detail = "$brand · 开放端口 $($ports -join ', ')"
            Status = if ($ports -contains 554) { "RTSP" } else { "HTTP" }
        }
    }

    return $rows
}

function Get-WinUtilNetEventLog {

    <#

    .SYNOPSIS
        The recent network-side system events that explain an intermittent connection

    #>

    param([int]$Latest = 25)

    $providers = @(
        "Microsoft-Windows-NetworkProfile",
        "Dhcp-Client",
        "Dnscache",
        "Microsoft-Windows-Forwarding",
        "e1dexpress",
        "e1iexpress",
        "Intel-VNet",
        "RTWlAN",
        "Realtek Wireless Lan"
    )

    $rows = @()
    foreach ($provider in $providers) {
        # A provider this machine does not have makes Get-WinEvent throw rather than return
        # nothing, and a NIC driver name is exactly the kind of thing a machine may not have
        try {
            $events = @(Get-WinEvent -FilterHashtable @{
                LogName      = "System"
                ProviderName = $provider
                StartTime    = (Get-Date).AddDays(-3)
            } -MaxEvents $Latest -ErrorAction Stop)
        } catch {
            continue
        }

        foreach ($event in $events) {
            $text = ""
            if ($event.Message) { $text = ($event.Message -split "`n")[0] }
            $rows += [pscustomobject]@{
                Name   = "{0:MM-dd HH:mm} {1}" -f $event.TimeCreated, $event.ProviderName
                Detail = $text
                Status = $event.LevelDisplayName
            }
        }
    }

    return ($rows | Sort-Object { $_.Name } -Descending | Select-Object -First ($Latest * 2))
}
