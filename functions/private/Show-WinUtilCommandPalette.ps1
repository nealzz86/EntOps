function Get-WinUtilCommandPaletteHint {

    <#

    .SYNOPSIS
        What the palette says when there is nothing to show yet

    #>

    param([string]$Query, [int]$Count)

    if ([string]::IsNullOrWhiteSpace($Query)) {
        return "输入功能名称或关键字开始搜索，例如「打印机」「清理」「ISO」。"
    }
    if ($Count -eq 0) {
        return "没有匹配「$($Query.Trim())」的功能。可以换个说法，或到对应页面里找。"
    }
    return "找到 $Count 项，回车执行第一项。"
}

function Show-WinUtilCommandPaletteResults {

    <#

    .SYNOPSIS
        Draws the palette's result list, marking the keyboard-selected row

    .DESCRIPTION
        Rows are borders with plain text rather than styled buttons: the palette redraws on every
        keystroke, and a flat list costs nothing to draw over a remote session. A row carries its
        command in Tag so the click handler does not have to close over anything.

    #>

    param(
        [object[]]$Items,
        [int]$SelectedIndex = 0,
        [string]$Query = ""
    )

    Invoke-WPFUIThread -Parameters @{ Items = $Items; SelectedIndex = $SelectedIndex; Query = $Query } -ScriptBlock {
        param($Items, $SelectedIndex, $Query)

        $panel = $sync["WPFPaletteResults"]
        if ($null -eq $panel) { return }

        $panel.Children.Clear()

        $hint = New-Object System.Windows.Controls.TextBlock
        $hint.Text = Get-WinUtilCommandPaletteHint -Query $Query -Count (@($Items).Count)
        $hint.FontSize = 11
        $hint.Margin = New-Object System.Windows.Thickness(9, 2, 9, 6)
        $hint.TextWrapping = [System.Windows.TextWrapping]::Wrap
        $hint.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, "SidebarMutedColor")
        $panel.Children.Add($hint) | Out-Null

        $index = 0
        foreach ($item in @($Items)) {
            if ($null -eq $item) { continue }

            $row = New-Object System.Windows.Controls.Border
            $row.Margin = New-Object System.Windows.Thickness(2, 1, 2, 1)
            $row.Padding = New-Object System.Windows.Thickness(8, 6, 8, 6)
            $row.Background = [System.Windows.Media.Brushes]::Transparent
            $row.Cursor = [System.Windows.Input.Cursors]::Hand
            $row.Tag = $item

            $label = New-Object System.Windows.Controls.TextBlock
            $label.Text = Format-WinUtilCommandResult -Command $item
            $label.FontSize = 13
            $label.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
            $label.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, "MainForegroundColor")
            $row.Child = $label

            # The keyboard row is marked with a fill rather than a border so the list keeps its
            # width whatever is selected
            if ($index -eq $SelectedIndex) {
                $row.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, "AppInstallSelectedColor")
            }

            $row.Add_MouseLeftButtonDown({
                param($Sender, $EventArgs)
                Invoke-WPFCommandPaletteRun -Command $Sender.Tag
            })

            $panel.Children.Add($row) | Out-Null
            $index++
        }
    }
}
