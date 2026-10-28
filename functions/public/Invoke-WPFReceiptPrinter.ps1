function Invoke-WPFReceiptScan {

    <#

    .SYNOPSIS
        Scans the local /24 segments for receipt printers listening on TCP 9100

    #>
    param([string]$Button)

    $knownIp = ""
    if ($sync.WPFReceiptIp) { $knownIp = $sync.WPFReceiptIp.Text.Trim() }

    Start-WinUtilJob -Name "小票打印机搜索" -Description "正在搜索网段内的小票打印机" -Parameters @{ KnownIp = $knownIp } -ScriptBlock {
        param($KnownIp)

        Append-WinUtilReceiptLog -Message "开始搜索：扫描本机各网卡的 /24 网段及芯烨/爱普生出厂默认 IP 的 9100 端口……"
        $found = Search-WinUtilReceiptPrinters -KnownIp $KnownIp

        if ($found.Count -eq 0) {
            Append-WinUtilReceiptLog -Message "未发现任何监听 9100 端口的设备。请确认打印机已上电、网线已插好，且电脑与打印机在同一网段。" -Level "WARN"
            return
        }

        foreach ($ip in $found) {
            $note = ""
            if ($ip -eq "192.168.123.100") { $note = "（芯烨出厂默认 IP）" }
            if ($ip -eq "192.168.192.168") { $note = "（爱普生出厂默认 IP）" }
            Append-WinUtilReceiptLog -Message "发现网口打印机候选：$ip : 9100 $note"
        }
        Append-WinUtilReceiptLog -Message "把要操作的打印机 IP 填入「打印机当前 IP」输入框后，即可修改 IP 或同步本机端口。"
    }
}

function Invoke-WPFReceiptSetXp {

    <#

    .SYNOPSIS
        Changes the LAN IP of a Xprinter XQ200 receipt printer over TCP 9100

    #>
    param([string]$Button)

    $currentIp = ""
    $newIp = ""
    if ($sync.WPFReceiptIp) { $currentIp = $sync.WPFReceiptIp.Text.Trim() }
    if ($sync.WPFReceiptNewIp) { $newIp = $sync.WPFReceiptNewIp.Text.Trim() }

    if (-not (Test-WinUtilIPv4 $currentIp)) {
        Append-WinUtilReceiptLog -Message "「打印机当前 IP」不是有效的 IPv4 地址，请先填写（芯烨出厂默认 192.168.123.100）。" -Level "ERROR"
        return
    }
    if (-not (Test-WinUtilIPv4 $newIp)) {
        Append-WinUtilReceiptLog -Message "「新 IP」不是有效的 IPv4 地址，请填写要设置的新 IP。" -Level "ERROR"
        return
    }
    if ($currentIp -eq $newIp) {
        Append-WinUtilReceiptLog -Message "当前 IP 与新 IP 相同，无需修改。" -Level "WARN"
        return
    }

    $answer = Show-WinUtilMessage -Title "修改芯烨打印机 IP" -Button "YesNo" -Icon "Warning" -Message @"
将通过网口（TCP 9100）把芯烨 XQ200 打印机的 IP 从：

　　$currentIp　改为　$newIp

- 打印机网络模块会重启，期间约 5 秒无法连接。
- 修改后本机指向旧 IP 的打印端口会失效，请点击「同步本机打印端口到新 IP」。
- 若新旧 IP 不在同一网段，电脑需临时改到对应网段才能再次访问打印机。

确定继续吗？
"@
    if ($answer -ne "Yes") { return }

    Start-WinUtilJob -Name "芯烨IP修改" -Description "正在修改芯烨打印机 IP" -Parameters @{ CurrentIp = $currentIp; NewIp = $newIp } -ScriptBlock {
        param($CurrentIp, $NewIp)
        try {
            Set-WinUtilXprinterIp -CurrentIp $CurrentIp -NewIp $NewIp
        } catch {
            Append-WinUtilReceiptLog -Message "修改失败：$($_.Exception.Message)" -Level "ERROR"
            Append-WinUtilReceiptLog -Message "请确认打印机是当前 IP、已上电且与电脑同网段；也可断电重启打印机后重试（出厂 IP 会恢复为 192.168.123.100 以外的最后设置值）。" -Level "WARN"
        }
    }
}

function Invoke-WPFReceiptEpsonWeb {

    <#

    .SYNOPSIS
        Opens the Epson TM-T82III embedded web configuration page

    #>
    param([string]$Button)

    $ip = ""
    if ($sync.WPFReceiptIp) { $ip = $sync.WPFReceiptIp.Text.Trim() }
    if (-not (Test-WinUtilIPv4 $ip) -and $sync.WPFReceiptNewIp) { $ip = $sync.WPFReceiptNewIp.Text.Trim() }
    if (-not (Test-WinUtilIPv4 $ip)) {
        Append-WinUtilReceiptLog -Message "请填写爱普生打印机的 IP（出厂默认 192.168.192.168），再打开网页配置。" -Level "ERROR"
        return
    }

    Append-WinUtilReceiptLog -Message "正在打开 http://$ip/ ……"
    try {
        Start-Process "http://$ip/"
        Append-WinUtilReceiptLog -Message "登录用户名：epson；密码：打印机自检页上的 SERIAL No（长按进纸键开机可打印自检页）。在 网络设置 → TCP/IP 中修改 IP。"
    } catch {
        Append-WinUtilReceiptLog -Message "无法打开网页：$($_.Exception.Message)。请确认电脑与打印机 $ip 在同一网段。" -Level "ERROR"
    }
}

function Invoke-WPFReceiptSyncPort {

    <#

    .SYNOPSIS
        Re-points local TCP printer ports from the old IP to the new IP

    #>
    param([string]$Button)

    $oldIp = ""
    $newIp = ""
    if ($sync.WPFReceiptIp) { $oldIp = $sync.WPFReceiptIp.Text.Trim() }
    if ($sync.WPFReceiptNewIp) { $newIp = $sync.WPFReceiptNewIp.Text.Trim() }

    if (-not (Test-WinUtilIPv4 $oldIp)) {
        Append-WinUtilReceiptLog -Message "请填写「打印机当前 IP」（打印机现在实际使用的旧 IP），再执行端口同步。" -Level "ERROR"
        return
    }
    if (-not (Test-WinUtilIPv4 $newIp)) {
        Append-WinUtilReceiptLog -Message "请填写「新 IP」（打印机修改后的 IP），再执行端口同步。" -Level "ERROR"
        return
    }

    Start-WinUtilJob -Name "打印端口同步" -Description "正在同步本机打印端口" -Parameters @{ OldIp = $oldIp; NewIp = $newIp } -ScriptBlock {
        param($OldIp, $NewIp)
        try {
            Sync-WinUtilPrinterPort -OldIp $OldIp -NewIp $NewIp
        } catch {
            Append-WinUtilReceiptLog -Message "端口同步失败：$($_.Exception.Message)" -Level "ERROR"
        }
    }
}
