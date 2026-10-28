function Set-WinUtilXprinterIp {

    <#

    .SYNOPSIS
        Changes a Xprinter network receipt printer IP by sending the NET configuration command

    .DESCRIPTION
        Xprinter net interfaces accept the IP setting as raw bytes on TCP 9100:
        1F 1B 1F 91 00 followed by "IP" (49 50) and the four address octets. The module
        reboots its network port after the command, so the new address is verified by
        reconnecting once the module has had time to come back.

    #>
    param(
        [string]$CurrentIp,
        [string]$NewIp
    )

    Append-WinUtilReceiptLog -Message "正在连接芯烨打印机 $CurrentIp : 9100 ……"
    $client = New-Object System.Net.Sockets.TcpClient
    $ar = $client.BeginConnect($CurrentIp, 9100, $null, $null)
    if (-not $ar.AsyncWaitHandle.WaitOne(3000)) {
        $client.Close()
        throw "连接 $CurrentIp : 9100 超时。请确认打印机已上电、当前 IP 正确且与电脑同网段。"
    }
    try {
        $client.EndConnect($ar)
    } catch {
        $client.Close()
        throw "无法连接 $CurrentIp : 9100（$($_.Exception.Message)）。请用「搜索网段内的打印机」确认打印机实际 IP。"
    }

    $octets = @($NewIp -split '\.' | ForEach-Object { [byte]$_ })
    $command = [byte[]](0x1F, 0x1B, 0x1F, 0x91, 0x00, 0x49, 0x50) + [byte[]]$octets
    $stream = $client.GetStream()
    $stream.WriteTimeout = 3000
    $stream.Write($command, 0, $command.Length)
    $stream.Flush()
    $client.Close()

    Append-WinUtilReceiptLog -Message "IP 设置指令已发送（$NewIp），打印机网络模块正在重启，等待 8 秒……"
    Step-WinUtilJob -Status "等待打印机网络模块重启" -Percent 60
    Start-Sleep -Seconds 8

    $verified = $false
    foreach ($attempt in 1..3) {
        $probe = New-Object System.Net.Sockets.TcpClient
        try {
            $par = $probe.BeginConnect($NewIp, 9100, $null, $null)
            if ($par.AsyncWaitHandle.WaitOne(2500) -and $par.IsCompleted) {
                $probe.EndConnect($par)
                $verified = $true
            }
        } catch { }
        try { $probe.Close() } catch { }
        if ($verified) { break }
        Start-Sleep -Seconds 2
    }

    if ($verified) {
        Append-WinUtilReceiptLog -Message "✅ 验证成功：新 IP $NewIp 已可连接 9100 端口。"
    } else {
        Append-WinUtilReceiptLog -Message "⚠ 暂未能连接新 IP $NewIp。打印机可能仍在重启或与新 IP 不同网段。" -Level "WARN"
    }

    $curBase = ($CurrentIp -split '\.')[0..1] -join "."
    $newBase = ($NewIp -split '\.')[0..1] -join "."
    if ($curBase -ne $newBase) {
        Append-WinUtilReceiptLog -Message "注意：新旧 IP 网段不同（$curBase.* → $newBase.*）。电脑需把本机 IP 临时改到 $newBase.* 网段才能再次访问打印机。" -Level "WARN"
    }
    Append-WinUtilReceiptLog -Message "下一步：填写「新 IP」后点击「同步本机打印端口到新 IP」，把旧端口 $CurrentIp 切换到 $NewIp。"
    Step-WinUtilJob -Status "芯烨打印机 IP 修改完成" -Percent 95
}
