function Get-WinUtilBaselineStateText {

    <#

    .SYNOPSIS
        The Chinese caption and theme colour for one check verdict

    .DESCRIPTION
        The scanner reports machine-readable states; the list has to say something an operator can
        read, and colour alone must never be the only signal.

    #>

    param([string]$State)

    switch ($State) {
        "pass" { return @{ Text = "合格"; Brush = "MainForegroundColor" } }
        "warn" { return @{ Text = "提醒"; Brush = "ProgressBarWarningColor" } }
        "fail" { return @{ Text = "不合格"; Brush = "ProgressBarErrorColor" } }
        default { return @{ Text = "未知"; Brush = "MainForegroundColor" } }
    }
}

function New-WinUtilBaselineText {
    param(
        [string]$Text,
        [int]$FontSize = 13,
        [System.Windows.TextAlignment]$Alignment = [System.Windows.TextAlignment]::Left,
        [switch]$Wrap
    )

    $block = New-Object System.Windows.Controls.TextBlock
    $block.Text = $Text
    $block.FontSize = $FontSize
    $block.TextAlignment = $Alignment
    if ($Wrap) { $block.TextWrapping = [System.Windows.TextWrapping]::Wrap } else {
        $block.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
    }
    $block.Margin = New-Object System.Windows.Thickness(6, 0, 6, 0)
    $block.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, "MainForegroundColor")
    return $block
}

function Show-WinUtilBaselineResults {

    <#

    .SYNOPSIS
        Replaces the checklist table with the rows of the last check-up

    .DESCRIPTION
       状态 / 项目 / 说明 / 操作, drawn as plain grids and solid colours: the tool is used over a
        remote session, so nothing here may cost a bitmap effect. A failing row carries the button
        that fixes it, which keeps the checklist honest - it can only offer what the tool already
        does somewhere else.

    #>

    param(
        [object[]]$Rows,
        [string]$EmptyText = "尚未体检。点「开始体检」逐项核对。"
    )

    Invoke-WPFUIThread -Parameters @{ Rows = $Rows; EmptyText = $EmptyText } -ScriptBlock {
        param($Rows, $EmptyText)

        $panel = $sync["WPFBaselineResults"]
        if ($null -eq $panel) { return }

        $panel.Children.Clear()

        if ($null -eq $Rows -or @($Rows).Count -eq 0) {
            $note = New-WinUtilBaselineText -Text $EmptyText
            $note.Margin = New-Object System.Windows.Thickness(0)
            $panel.Children.Add($note) | Out-Null
            return
        }

        $header = New-Object System.Windows.Controls.Grid
        foreach ($column in @(
            (New-Object System.Windows.GridLength(80, [System.Windows.GridUnitType]::Pixel)),
            (New-Object System.Windows.GridLength(200, [System.Windows.GridUnitType]::Pixel)),
            (New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)),
            (New-Object System.Windows.GridLength(150, [System.Windows.GridUnitType]::Pixel))
        )) {
            $definition = New-Object System.Windows.Controls.ColumnDefinition
            $definition.Width = $column
            $header.ColumnDefinitions.Add($definition) | Out-Null
        }
        $titles = @("状态", "项目", "说明", "操作")
        for ($columnIndex = 0; $columnIndex -lt $titles.Count; $columnIndex++) {
            $titleBlock = New-WinUtilBaselineText -Text $titles[$columnIndex] -FontSize 12
            $titleBlock.FontWeight = [System.Windows.FontWeights]::Bold
            [System.Windows.Controls.Grid]::SetColumn($titleBlock, $columnIndex)
            $header.Children.Add($titleBlock) | Out-Null
        }
        $panel.Children.Add($header) | Out-Null

        foreach ($row in @($Rows)) {
            $verdict = Get-WinUtilBaselineStateText -State ([string]$row.State)

            $grid = New-Object System.Windows.Controls.Grid
            $grid.Margin = New-Object System.Windows.Thickness(0, 3, 0, 3)
            foreach ($column in @(
                (New-Object System.Windows.GridLength(80, [System.Windows.GridUnitType]::Pixel)),
                (New-Object System.Windows.GridLength(200, [System.Windows.GridUnitType]::Pixel)),
                (New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)),
                (New-Object System.Windows.GridLength(150, [System.Windows.GridUnitType]::Pixel))
            )) {
                $definition = New-Object System.Windows.Controls.ColumnDefinition
                $definition.Width = $column
                $grid.ColumnDefinitions.Add($definition) | Out-Null
            }

            $stateBlock = New-WinUtilBaselineText -Text $verdict.Text
            $stateBlock.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, $verdict.Brush)
            $grid.Children.Add($stateBlock) | Out-Null

            $nameBlock = New-WinUtilBaselineText -Text ([string]$row.Name) -Wrap
            [System.Windows.Controls.Grid]::SetColumn($nameBlock, 1)
            $grid.Children.Add($nameBlock) | Out-Null

            $detailBlock = New-WinUtilBaselineText -Text ([string]$row.Detail) -Wrap
            [System.Windows.Controls.Grid]::SetColumn($detailBlock, 2)
            $grid.Children.Add($detailBlock) | Out-Null

            if (-not [string]::IsNullOrWhiteSpace([string]$row.FixButton)) {
                $fixButton = New-Object System.Windows.Controls.Button
                $caption = [string]$row.FixText
                if ([string]::IsNullOrWhiteSpace($caption)) { $caption = "处理" }
                $fixButton.Content = $caption
                # Same trap as the printer editor's rows: the theme's button style pins every Button
                # to 200x25, which is wider than this column and too short for the label.
                $fixButton.Width = [double]::NaN
                $fixButton.Height = [double]::NaN
                $fixButton.MinHeight = 26
                $fixButton.MinWidth = 60
                $fixButton.Tag = [string]$row.FixButton
                $fixButton.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
                $fixButton.Add_Click({ Invoke-WPFButton -Button $this.Tag })
                [System.Windows.Controls.Grid]::SetColumn($fixButton, 3)
                $grid.Children.Add($fixButton) | Out-Null
            }

            $panel.Children.Add($grid) | Out-Null
        }
    }
}
