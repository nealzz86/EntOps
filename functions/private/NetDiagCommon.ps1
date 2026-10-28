function Get-WinUtilNetLocalAddresses {

    <#

    .SYNOPSIS
        Everything the network tab scans is derived from here, so the adapters Windows itself
        would not route through (loopback, link-local, APIPA, tunnel) are filtered out once.

    #>

    $result = @{
        IPv4     = @()
        Gateways = @()
        Dns      = @()
        Adapters = @()
    }

    foreach ($ip in (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue)) {
        if ($ip.IPAddress -like "127.*" -or $ip.IPAddress -like "169.254.*") { continue }
        $result.IPv4 += [pscustomobject]@{
            IPAddress = $ip.IPAddress
            Prefix    = $ip.PrefixLength
            Interface = $ip.InterfaceAlias
        }
    }

    foreach ($route in (Get-NetRoute -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.NextHop -ne "0.0.0.0" -and $_.DestinationPrefix -eq "0.0.0.0/0" })) {
        if ($route.NextHop -and $result.Gateways -notcontains $route.NextHop) {
            $result.Gateways += $route.NextHop
        }
    }

    foreach ($server in (Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue)) {
        foreach ($dns in @($server.ServerAddresses)) {
            if ($dns -and $result.Dns -notcontains $dns) { $result.Dns += $dns }
        }
    }

    foreach ($adapter in (Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq "Up" })) {
        $result.Adapters += [pscustomobject]@{
            Name     = $adapter.Name
            LinkSpeed = $adapter.LinkSpeed
            Mac      = $adapter.MacAddress
        }
    }

    return $result
}

function Get-WinUtilNetScanSubnet {

    <#

    .SYNOPSIS
        The /24 prefix a scan should cover, from the typed value or the local addresses

    #>

    param([string]$Text)

    if ($Text -and $Text.Trim()) {
        $trimmed = $Text.Trim()
        if ($trimmed -match '^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$') {
            return "{0}.{1}.{2}" -f $matches[1], $matches[2], $matches[3]
        }
        if ($trimmed -match '^(\d{1,3}\.\d{1,3}\.\d{1,3})$') {
            return $matches[1]
        }
        return $null
    }

    foreach ($entry in (Get-WinUtilNetLocalAddresses).IPv4) {
        if ($entry.Prefix -ge 8 -and $entry.Prefix -le 24) {
            $parts = $entry.IPAddress -split '\.'
            return "{0}.{1}.{2}" -f $parts[0], $parts[1], $parts[2]
        }
    }
    return $null
}

function Format-WinUtilNetBytes {

    <#

    .SYNOPSIS
        An amount of data, in the unit that fits it

    #>

    param([double]$Bytes)

    if ($Bytes -ge 1GB) { return ("{0:N2} GB" -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ("{0:N1} MB" -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ("{0:N1} KB" -f ($Bytes / 1KB)) }
    return ("{0:N0} B" -f $Bytes)
}

function Format-WinUtilNetBytesPerSecond {

    <#

    .SYNOPSIS
        A bytes-per-second figure in the unit an operator reads off a screen

    #>

    param([double]$BytesPerSecond)

    if ($BytesPerSecond -ge 1048576) { return ("{0:N2} MB/s" -f ($BytesPerSecond / 1MB)) }
    if ($BytesPerSecond -ge 1024) { return ("{0:N1} KB/s" -f ($BytesPerSecond / 1KB)) }
    return ("{0:N0} B/s" -f $BytesPerSecond)
}

function Format-WinUtilNetBitRate {

    <#

    .SYNOPSIS
        The same figure as a link speed, which is how bandwidth is quoted

    #>

    param([double]$BytesPerSecond)

    $bits = $BytesPerSecond * 8
    if ($bits -ge 1e9) { return ("{0:N2} Gbps" -f ($bits / 1e9)) }
    if ($bits -ge 1e6) { return ("{0:N1} Mbps" -f ($bits / 1e6)) }
    if ($bits -ge 1e3) { return ("{0:N0} Kbps" -f ($bits / 1e3)) }
    return ("{0:N0} bps" -f $bits)
}

function Append-WinUtilNetLog {

    <#

    .SYNOPSIS
        Appends a timestamped line to the network diagnostics output box

    #>

    param(
        [string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR")]
        [string]$Level = "INFO"
    )

    Write-WinUtilLog -Level $Level -Component "NetDiag" -Message $Message

    Invoke-WPFUIThread -Async -Parameters @{
        LogLine = "[$((Get-Date).ToString('HH:mm:ss'))] $Message"
    } -ScriptBlock {
        param($LogLine)

        $box = $sync["WPFFNetOutput"]
        if ($null -eq $box) { return }

        if ($box.Text -eq "就绪。点击上方任一功能开始诊断。") {
            $box.Text = $LogLine
        } else {
            $box.Text += "`n$LogLine"
        }
        $box.ScrollToEnd()
    }
}

function Show-WinUtilNetResults {

    <#

    .SYNOPSIS
        Replaces the structured result list with the rows of the last scan

    .DESCRIPTION
        Rows are name/detail/status triples rendered as plain grids: no bitmaps, so the list
        stays cheap to draw over a remote session.

    #>

    param(
        [object[]]$Rows,
        [string]$EmptyText = "暂无结果。"
    )

    Invoke-WPFUIThread -Parameters @{ Rows = $Rows; EmptyText = $EmptyText } -ScriptBlock {
        param($Rows, $EmptyText)

        $panel = $sync["WPFFNetResults"]
        if ($null -eq $panel) { return }

        $panel.Children.Clear()

        if ($null -eq $Rows -or @($Rows).Count -eq 0) {
            $note = New-Object System.Windows.Controls.TextBlock
            $note.Text = $EmptyText
            $note.FontSize = 13
            $note.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, "MainForegroundColor")
            $panel.Children.Add($note) | Out-Null
            return
        }

        foreach ($row in @($Rows)) {
            $grid = New-Object System.Windows.Controls.Grid
            $grid.Margin = New-Object System.Windows.Thickness(0, 1, 0, 1)
            $nameColumn = New-Object System.Windows.Controls.ColumnDefinition
            $nameColumn.Width = New-Object System.Windows.GridLength(170, [System.Windows.GridUnitType]::Pixel)
            $detailColumn = New-Object System.Windows.Controls.ColumnDefinition
            $detailColumn.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
            $statusColumn = New-Object System.Windows.Controls.ColumnDefinition
            $statusColumn.Width = New-Object System.Windows.GridLength(110, [System.Windows.GridUnitType]::Pixel)
            $grid.ColumnDefinitions.Add($nameColumn) | Out-Null
            $grid.ColumnDefinitions.Add($detailColumn) | Out-Null
            $grid.ColumnDefinitions.Add($statusColumn) | Out-Null

            $name = New-Object System.Windows.Controls.TextBlock
            $name.Text = [string]$row.Name
            $name.FontSize = 13
            $name.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
            $name.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, "MainForegroundColor")

            $detail = New-Object System.Windows.Controls.TextBlock
            $detail.Text = [string]$row.Detail
            $detail.FontSize = 13
            $detail.Margin = New-Object System.Windows.Thickness(6, 0, 6, 0)
            $detail.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
            $detail.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, "MainForegroundColor")

            $status = New-Object System.Windows.Controls.TextBlock
            $status.Text = [string]$row.Status
            $status.FontSize = 13
            $status.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
            $status.TextAlignment = [System.Windows.TextAlignment]::Right
            # Colour carries severity so an operator scanning the list does not have to read every
            # row to find the one that needs action
            $statusResource = "MainForegroundColor"
            switch -Regex ([string]$row.Status) {
                "风险|严重|不通|失败|不可达|较差" { $statusResource = "ProgressBarErrorColor" }
                "提示|轻微|部分|一般|承压|即将" { if ($statusResource -eq "MainForegroundColor") { $statusResource = "ProgressBarWarningColor" } }
            }
            $status.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, $statusResource)

            $grid.Children.Add($name) | Out-Null
            [System.Windows.Controls.Grid]::SetColumn($detail, 1)
            $grid.Children.Add($detail) | Out-Null
            [System.Windows.Controls.Grid]::SetColumn($status, 2)
            $grid.Children.Add($status) | Out-Null

            $panel.Children.Add($grid) | Out-Null
        }
    }
}
