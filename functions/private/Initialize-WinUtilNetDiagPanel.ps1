function Initialize-WinUtilNetDiagPanel {

    <#

    .SYNOPSIS
        Fills the network diagnostics tab: prefills the scan targets and takes the first overview
        reading

    .DESCRIPTION
        The scan boxes are prefilled with the values an operator uses on their own machine, so a
        diagnosis starts with a click instead of with typing. The overview cards need a second of
        pinging and sampling, which is queued after the tab has painted rather than done here.

    #>

    $local = Get-WinUtilNetLocalAddresses

    $subnet = $sync["WPFFNetSubnet"]
    if ($subnet -and -not $subnet.Text.Trim()) {
        $prefix = Get-WinUtilNetScanSubnet -Text ""
        if ($prefix) { $subnet.Text = $prefix }
    }

    $lan = $sync["WPFFNetLanPath"]
    if ($lan -and -not $lan.Text.Trim()) {
        # The share list already configures which servers this unit uses; a path is all that is
        # needed here, never the credentials stored next to it
        foreach ($share in @($sync.configs.entprinters.shares)) {
            $path = if ($share.Paths -and @($share.Paths).Count -gt 0) { [string]$share.Paths[0] } else { "" }
            if ($path) {
                $lan.Text = $path
                $lan.ToolTip = "$($share.Name) 共享（可改成其他内网路径）"
                break
            }
        }
    }

    if ($sync.NetDiagHealth) {
        $health = $sync.NetDiagHealth
        foreach ($card in @("Local", "Gateway", "Dns", "DnsPing", "Internet", "Throughput", "Conns", "Adapter", "Uptime")) {
            $label = $sync["WPFOvNet$card"]
            if ($null -ne $label) {
                $key = if ($card -eq "DnsPing") { "DnsResolve" } else { $card }
                $label.Text = [string]$health[$key]
            }
        }
    }

    $target = $sync["WPFFNetTarget"]
    if ($target -and -not $target.Text.Trim() -and @($local.Gateways).Count -gt 0) {
        $target.ToolTip = "留空则使用默认网关 $($local.Gateways[0])"
    }

    if (-not $sync.NetDiagHealth -and (Test-WinUtilUIAlive)) {
        $null = $sync.Form.Dispatcher.BeginInvoke(
            [System.Windows.Threading.DispatcherPriority]::Background,
            [action] { Invoke-WPFNetHealthRefresh })
    }
}
