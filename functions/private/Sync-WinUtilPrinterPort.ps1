function Sync-WinUtilPrinterPort {

    <#

    .SYNOPSIS
        Re-points local TCP printer ports and the printers using them from an old IP to a new IP

    #>
    param(
        [string]$OldIp,
        [string]$NewIp
    )

    Append-WinUtilReceiptLog -Message "正在检查本机指向 $OldIp 的 TCP 打印端口……"
    Step-WinUtilJob -Status "同步本机打印端口" -Percent 20

    $ports = @(Get-PrinterPort -ErrorAction SilentlyContinue)
    $escaped = [regex]::Escape($OldIp)
    $matched = @($ports | Where-Object { $_.PrinterHostAddress -eq $OldIp -or $_.Name -match $escaped })

    if ($matched.Count -eq 0) {
        Append-WinUtilReceiptLog -Message "未找到指向 $OldIp 的打印端口。如果打印机尚未添加到本机，请先在「打印机一键安装」中添加，或手动新建端口 IP_$NewIp。" -Level "WARN"
        return
    }

    $newPortName = "IP_$NewIp"
    $existing = @($ports | Where-Object { $_.Name -eq $newPortName })
    if ($existing.Count -eq 0) {
        try {
            Add-PrinterPort -Name $newPortName -PrinterHostAddress $NewIp -ErrorAction Stop
            Append-WinUtilReceiptLog -Message "已创建新端口 $newPortName（TCP 9100 → $NewIp）。"
        } catch {
            throw "创建端口 $newPortName 失败：$($_.Exception.Message)。请以管理员身份重试。"
        }
    } else {
        Append-WinUtilReceiptLog -Message "端口 $newPortName 已存在，直接复用。"
    }

    $switched = 0
    foreach ($port in $matched) {
        $printers = @(Get-Printer -ErrorAction SilentlyContinue | Where-Object { $_.PortName -eq $port.Name })
        foreach ($printer in $printers) {
            try {
                Set-Printer -Name $printer.Name -PortName $newPortName -ErrorAction Stop
                $switched++
                Append-WinUtilReceiptLog -Message "打印机「$($printer.Name)」端口已从 $($port.Name) 切换到 $newPortName。"
            } catch {
                Append-WinUtilReceiptLog -Message "切换「$($printer.Name)」端口失败：$($_.Exception.Message)" -Level "ERROR"
            }
        }
    }

    if ($switched -eq 0) {
        Append-WinUtilReceiptLog -Message "没有找到使用旧端口 $($matched[0].Name) 的打印机，请确认打印机是否已添加到本机。" -Level "WARN"
    } else {
        Append-WinUtilReceiptLog -Message "✅ 端口同步完成，共切换 $switched 台打印机。建议在打印机上打印测试页验证。"
    }
    Step-WinUtilJob -Status "端口同步完成" -Percent 95
}
