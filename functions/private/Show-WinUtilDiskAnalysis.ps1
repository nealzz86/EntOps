function New-WinUtilDiskBar {

    <#

    .SYNOPSIS
        Builds a flat proportional bar (no bitmap effects, RDP safe) as a Grid

    #>
    param(
        [double]$Fraction,
        [double]$Height = 10
    )

    if ($Fraction -lt 0.004) { $Fraction = 0.004 }
    if ($Fraction -gt 1) { $Fraction = 1 }

    $grid = New-Object Windows.Controls.Grid
    $fillCol = New-Object Windows.Controls.ColumnDefinition
    # `New-Object Type(1.0 - $x, [Type]::Star)` parses the comma first and hands the subtraction an
    # array to work with, so build these through the constructor the way the rest of the file does
    $fillCol.Width = [Windows.GridLength]::new($Fraction, [Windows.GridUnitType]::Star)
    $restCol = New-Object Windows.Controls.ColumnDefinition
    $restCol.Width = [Windows.GridLength]::new((1.0 - $Fraction), [Windows.GridUnitType]::Star)
    [void]$grid.ColumnDefinitions.Add($fillCol)
    [void]$grid.ColumnDefinitions.Add($restCol)

    $fill = New-Object Windows.Controls.Border
    $fill.Height = $Height
    $fill.CornerRadius = [Windows.CornerRadius]::new(2)
    $fill.SetResourceReference([Windows.Controls.Control]::BackgroundProperty, "ToggleButtonOnColor")
    [Windows.Controls.Grid]::SetColumn($fill, 0)
    [void]$grid.Children.Add($fill)

    $track = New-Object Windows.Controls.Border
    $track.Height = $Height
    $track.CornerRadius = [Windows.CornerRadius]::new(2)
    $track.SetResourceReference([Windows.Controls.Control]::BackgroundProperty, "ButtonBackgroundColor")
    [Windows.Controls.Grid]::SetColumn($track, 1)
    [void]$grid.Children.Add($track)

    return $grid
}

function Add-WinUtilDiskAnaRow {

    <#

    .SYNOPSIS
        Appends one label / bar / size row to a disk analysis panel

    #>
    param(
        [Windows.Controls.StackPanel]$Target,
        [string]$Label,
        [string]$SizeText,
        [double]$Fraction,
        [string]$ToolTip,
        [scriptblock]$OnClick
    )

    $row = New-Object Windows.Controls.Grid
    $row.Margin = [Windows.Thickness]::new(0, 1, 0, 1)

    $colName = New-Object Windows.Controls.ColumnDefinition
    $colName.Width = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star)
    $colBar = New-Object Windows.Controls.ColumnDefinition
    $colBar.Width = [Windows.GridLength]::new(130)
    $colSize = New-Object Windows.Controls.ColumnDefinition
    $colSize.Width = [Windows.GridLength]::new(84)
    [void]$row.ColumnDefinitions.Add($colName)
    [void]$row.ColumnDefinitions.Add($colBar)
    [void]$row.ColumnDefinitions.Add($colSize)

    $name = New-Object Windows.Controls.TextBlock
    $name.Text = $Label
    $name.TextTrimming = [Windows.TextTrimming]::CharacterEllipsis
    $name.VerticalAlignment = [Windows.VerticalAlignment]::Center
    $name.Margin = [Windows.Thickness]::new(2, 0, 8, 0)
    $name.FontSize = 12.5
    $name.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, "MainForegroundColor")
    [void]$row.Children.Add($name)

    $bar = New-WinUtilDiskBar -Fraction $Fraction
    $bar.VerticalAlignment = [Windows.VerticalAlignment]::Center
    [Windows.Controls.Grid]::SetColumn($bar, 1)
    [void]$row.Children.Add($bar)

    $size = New-Object Windows.Controls.TextBlock
    $size.Text = $SizeText
    $size.TextAlignment = [Windows.TextAlignment]::Right
    $size.VerticalAlignment = [Windows.VerticalAlignment]::Center
    $size.FontSize = 12
    $size.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, "MainForegroundColor")
    [Windows.Controls.Grid]::SetColumn($size, 2)
    [void]$row.Children.Add($size)

    if ($ToolTip) { $row.ToolTip = $ToolTip }

    if ($OnClick) {
        $row.Cursor = [System.Windows.Input.Cursors]::Hand
        $row.Add_MouseLeftButtonUp($OnClick)
    }

    [void]$Target.Children.Add($row)
}

function Show-WinUtilDiskAnalysis {

    <#

    .SYNOPSIS
        Renders the children and top files of one scanned directory from $sync.DiskAna

    #>
    param([string]$Prefix)

    $st = $sync.DiskAna
    if ($null -eq $st) { return }

    $st.Prefix = $Prefix
    $dirsPanel = $sync.WPFDiskAnaDirs
    $filesPanel = $sync.WPFDiskAnaFiles
    if ($null -eq $dirsPanel -or $null -eq $filesPanel) { return }

    $dirsPanel.Children.Clear()
    $filesPanel.Children.Clear()

    $parentBytes = $st.Total
    if ($Prefix -ne "" -and $st.Dirs.ContainsKey($Prefix)) { $parentBytes = $st.Dirs[$Prefix] }

    $children = @()
    foreach ($key in $st.Dirs.Keys) {
        if ($key -eq $Prefix) { continue }
        $i = $key.LastIndexOf("\")
        $parentKey = if ($i -lt 0) { "" } else { $key.Substring(0, $i) }
        if ($parentKey -eq $Prefix) {
            $children += @{ Key = $key; Bytes = $st.Dirs[$key]; Files = $st.Counts[$key] }
        }
    }

    $sorted = @($children | Sort-Object -Property @{Expression = "Bytes"; Descending = $true} | Select-Object -First 200)
    $shown = 0
    foreach ($child in $sorted) {
        if ($child.Bytes -le 0) { continue }
        $shown++
        $leaf = $child.Key
        $i = $leaf.LastIndexOf("\")
        if ($i -ge 0) { $leaf = $leaf.Substring($i + 1) }

        $fraction = 0
        if ($parentBytes -gt 0) { $fraction = $child.Bytes / $parentBytes }
        $pctText = ""
        if ($parentBytes -gt 0) { $pctText = ("{0:N1}%" -f ($fraction * 100)) }

        $fullPath = "$($st.RootTrim)\$($child.Key)"
        $tip = "$fullPath（含子目录共 $($child.Files) 个文件，点击进入）"
        $relCopy = $child.Key
        $click = { Invoke-WPFDiskAnaDrill -RelPath $relCopy }.GetNewClosure()

        Add-WinUtilDiskAnaRow -Target $dirsPanel -Label "$leaf  $pctText" -SizeText (Format-WinUtilJunkSize $child.Bytes) `
            -Fraction $fraction -ToolTip $tip -OnClick $click
    }

    if ($sorted.Count -gt $shown) {
        $more = New-Object Windows.Controls.TextBlock
        $more.Text = "…… 仅显示前 200 个子目录（跳过 0 字节目录）"
        $more.FontSize = 11
        $more.FontStyle = [Windows.FontStyle]::Italic
        $more.Margin = [Windows.Thickness]::new(2, 4, 0, 0)
        $more.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, "MainForegroundColor")
        [void]$dirsPanel.Children.Add($more)
    }
    if ($shown -eq 0) {
        $none = New-Object Windows.Controls.TextBlock
        $none.Text = "（此目录下没有可统计的子目录）"
        $none.FontSize = 11.5
        $none.Margin = [Windows.Thickness]::new(2, 4, 0, 0)
        $none.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, "MainForegroundColor")
        [void]$dirsPanel.Children.Add($none)
    }

    $fileShown = 0
    foreach ($entry in $st.Top) {
        if ($fileShown -ge 20) { break }
        $relDir = ""
        $j = $entry.Rel.LastIndexOf("\")
        if ($j -ge 0) { $relDir = $entry.Rel.Substring(0, $j) }

        $under = ($Prefix -eq "") -or ($relDir -eq $Prefix) -or ($relDir.StartsWith("$Prefix\"))
        if (-not $under) { continue }

        $fileShown++
        $leafName = $entry.Rel
        if ($j -ge 0) { $leafName = $entry.Rel.Substring($j + 1) }

        $fraction = 0
        if ($st.Total -gt 0) { $fraction = $entry.Bytes / $st.Total }

        $pathCopy = $entry.Path
        $click = {
            try { Start-Process explorer.exe -ArgumentList "/select,`"$pathCopy`"" } catch { }
        }.GetNewClosure()

        Add-WinUtilDiskAnaRow -Target $filesPanel -Label $leafName -SizeText (Format-WinUtilJunkSize $entry.Bytes) `
            -Fraction $fraction -ToolTip "$pathCopy（点击在资源管理器中定位）" -OnClick $click
    }
    if ($fileShown -eq 0) {
        $none = New-Object Windows.Controls.TextBlock
        $none.Text = "（当前目录内没有大于 50MB 的前 300 名文件）"
        $none.FontSize = 11.5
        $none.FontStyle = [Windows.FontStyle]::Italic
        $none.Margin = [Windows.Thickness]::new(2, 4, 0, 0)
        $none.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, "MainForegroundColor")
        [void]$filesPanel.Children.Add($none)
    }

    $driveInfo = $null
    try { $driveInfo = New-Object System.IO.DriveInfo($st.RootTrim) } catch { }
    $driveLine = ""
    if ($driveInfo) {
        $freeGB = [Math]::Round($driveInfo.AvailableFreeSpace / 1GB, 1)
        $totalGB = [Math]::Round($driveInfo.TotalSize / 1GB, 1)
        $driveLine = "　·　磁盘共 $totalGB GB，剩余 $freeGB GB"
    }

    $shownBytesText = "未扫描"
    if ($st.Dirs.ContainsKey($Prefix)) { $shownBytesText = Format-WinUtilJunkSize $st.Dirs[$Prefix] }
    $pathText = "$($st.Root)$Prefix"
    if ($Prefix -eq "") { $pathText = $st.Root }
    $sync.WPFDiskAnaPath.Text = "$pathText　·　占用 $shownBytesText$driveLine"
    $sync.WPFDiskAnaNote.Text = "扫描 $($st.FileCount) 个文件 / $($st.DirCount) 个目录，用时 $($st.Seconds) 秒；无权限目录已跳过。点击左侧目录继续下钻，点击「上一级」返回。"
}
