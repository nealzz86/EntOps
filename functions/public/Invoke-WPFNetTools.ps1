function Get-WinUtilNetToolInput {

    <#

    .SYNOPSIS
        One of the tool rows' input boxes, trimmed

    #>

    param([string]$Name)

    $box = $sync[$Name]
    if (-not $box) { return "" }
    return [string]$box.Text.Trim()
}

function Show-WinUtilNetToolResult {

    <#

    .SYNOPSIS
        Presents what a tool produced, in the two panels the tab already has

    .DESCRIPTION
        The rows go in the result list and the explanation goes in the output box, so a tool that
        refused to run leaves a readable reason rather than an empty table.

    #>

    param(
        $Result,
        [string]$Label
    )

    if (-not $Result) { return }

    if ($Result.Problem) {
        Append-WinUtilNetLog -Message "$($Label)：$($Result.Problem)" -Level "WARN"
        Show-WinUtilNetResults -Rows @() -EmptyText "$($Label)未执行 —— $($Result.Problem)"
        return
    }

    foreach ($note in @($Result.Notes)) {
        Append-WinUtilNetLog -Message "$($Label)：$note"
    }
    Show-WinUtilNetResults -Rows $Result.Rows -EmptyText "$($Label)：无结果。"
}

function Invoke-WPFNetTool {

    <#

    .SYNOPSIS
        Runs the network tool whose button was pressed

    #>

    param([string]$Button)

    switch ($Button) {
        "WPFFNetToolIpCalc" {
            Show-WinUtilNetToolResult -Label "IP 地址计算器" -Result (Get-WinUtilNetIpCalc -Text (Get-WinUtilNetToolInput "WPFFNetToolIpCalcIn"))
        }
        "WPFFNetToolVlsm" {
            $result = Get-WinUtilNetVlsmPlan -Base (Get-WinUtilNetToolInput "WPFFNetToolVlsmIn") -Hosts (Get-WinUtilNetToolInput "WPFFNetToolVlsmIn2")
            Show-WinUtilNetToolResult -Label "子网划分" -Result $result
        }
        "WPFFNetToolSummary" {
            Show-WinUtilNetToolResult -Label "子网汇总" -Result (Get-WinUtilNetSummaryPlan -Text (Get-WinUtilNetToolInput "WPFFNetToolSummaryIn"))
        }
        "WPFFNetToolMac" {
            Show-WinUtilNetToolResult -Label "MAC 地址工具" -Result (Get-WinUtilNetMacTool -Text (Get-WinUtilNetToolInput "WPFFNetToolMacIn"))
        }
        "WPFFNetToolConflict" { Invoke-WPFNetToolConflict }
        "WPFFNetToolArp" { Invoke-WPFNetToolArp }
        "WPFFNetToolWol" { Invoke-WPFNetToolWakeOnLan }
        "WPFFNetToolBw" {
            $result = Get-WinUtilNetBandwidthPlan -Size (Get-WinUtilNetToolInput "WPFFNetToolBwIn") -Link (Get-WinUtilNetToolInput "WPFFNetToolBwIn2")
            Show-WinUtilNetToolResult -Label "带宽计算" -Result $result
        }
        "WPFFNetToolVlan" {
            $result = Get-WinUtilNetVlanPlan -Range (Get-WinUtilNetToolInput "WPFFNetToolVlanIn") -Base (Get-WinUtilNetToolInput "WPFFNetToolVlanIn2")
            Show-WinUtilNetToolResult -Label "VLAN 规划" -Result $result
        }
        "WPFFNetToolMtu" {
            $result = Get-WinUtilNetMtuPlan -Mtu (Get-WinUtilNetToolInput "WPFFNetToolMtuIn") -Payload (Get-WinUtilNetToolInput "WPFFNetToolMtuIn2")
            Show-WinUtilNetToolResult -Label "MTU 计算" -Result $result
        }
        "WPFFNetToolStp" {
            $result = Get-WinUtilNetStpPriority -Priority (Get-WinUtilNetToolInput "WPFFNetToolStpIn") -Vlan (Get-WinUtilNetToolInput "WPFFNetToolStpIn2")
            Show-WinUtilNetToolResult -Label "STP 优先级" -Result $result
        }
        "WPFFNetToolRadix" {
            Show-WinUtilNetToolResult -Label "进制转换" -Result (Get-WinUtilNetRadix -Text (Get-WinUtilNetToolInput "WPFFNetToolRadixIn"))
        }
        "WPFFNetToolRate" {
            Show-WinUtilNetToolResult -Label "速率单位转换" -Result (Get-WinUtilNetRateTool -Text (Get-WinUtilNetToolInput "WPFFNetToolRateIn"))
        }
        "WPFFNetToolTime" {
            Show-WinUtilNetToolResult -Label "时间戳转换" -Result (Get-WinUtilNetTimestampTool -Text (Get-WinUtilNetToolInput "WPFFNetToolTimeIn"))
        }
    }
}

function Invoke-WPFNetToolConflict {

    <#

    .SYNOPSIS
        Duplicate address check, off the interface thread because it pings

    #>

    $text = Get-WinUtilNetToolInput "WPFFNetToolConflictIn"

    Start-WinUtilJob -Name "IP 冲突检测" -Description "正在检测 IP 冲突" -Parameters @{ Text = $text } -ScriptBlock {
        param($Text)

        $result = Get-WinUtilNetIpConflict -Text $Text -OnProgress {
            param($Message)
            Append-WinUtilNetLog -Message $Message
        }
        Show-WinUtilNetToolResult -Label "IP 冲突检测" -Result $result
    }
}

function Invoke-WPFNetToolArp {

    <#

    .SYNOPSIS
        Neighbour table lookup, which may have to ask the host once before the cache has it

    #>

    $text = Get-WinUtilNetToolInput "WPFFNetToolArpIn"
    if (-not $text) {
        Show-WinUtilNetToolResult -Label "ARP 查询" -Result (New-WinUtilNetToolError -Message "请输入 IP 或 MAC 地址。")
        return
    }

    Start-WinUtilJob -Name "ARP 查询" -Description "正在查询 $text" -Parameters @{ Text = $text } -ScriptBlock {
        param($Text)

        Show-WinUtilNetToolResult -Label "ARP 查询" -Result (Get-WinUtilNetArpLookup -Text $Text)
    }
}

function Invoke-WPFNetToolWakeOnLan {

    <#

    .SYNOPSIS
        Sends the magic packet; a UDP send is quick enough to stay on the interface thread

    #>

    $mac = Get-WinUtilNetToolInput "WPFFNetToolWolIn"
    if (-not (Get-WinUtilMacBytes -Text $mac)) {
        Show-WinUtilNetToolResult -Label "远程唤醒" -Result (New-WinUtilNetToolError -Message "请输入有效的 MAC 地址（6 组十六进制）。")
        return
    }

    $port = 9
    $target = ""
    foreach ($token in (@((Get-WinUtilNetToolInput "WPFFNetToolWolIn2") -split '[,;、\s]+' | Where-Object { $_ }))) {
        if ($token -match '^\d{1,5}$' -and [int]$token -ge 1 -and [int]$token -le 65535) { $port = [int]$token }
        else { $target += $(if ($target) { "," } else { "" }) + $token }
    }

    $send = Send-WinUtilWakeOnLan -Mac $mac -Target $target -Port $port

    $rows = @()
    foreach ($entry in @($send.Sent)) {
        $rows += New-WinUtilNetToolRow -Name "已发送 $entry" -Detail "魔术包 102 字节 · 目标 MAC $mac" -Status "成功"
    }
    foreach ($entry in @($send.Failed)) {
        $rows += New-WinUtilNetToolRow -Name "发送失败" -Detail $entry -Status "失败"
    }

    $notes = @("发往：$(if (@($send.Targets).Count) { $send.Targets -join ' / ' } else { '无' })，UDP 端口 $port。")
    if (@($send.Sent).Count -eq 0) {
        $notes += "一个包都没发出去，请检查本机网络是否可用。"
    } else {
        $notes += "魔术包已发出。Wake-on-LAN 是单向广播，收不到回应是正常的：判断是否成功请看目标机是否真的开机。"
        $notes += "跨网段唤醒需要三层设备放行 UDP 9（或在同网段放一台常开的主机做中继）；BIOS 与网卡属性里的 WOL/唤醒魔法包必须已启用，关机后网卡要仍供电。"
    }

    Show-WinUtilNetToolResult -Label "远程唤醒" -Result (New-WinUtilNetToolResult -Rows $rows -Notes $notes)
}
