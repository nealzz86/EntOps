function Show-WinUtilEntPrinterEditor {

    <#

    .SYNOPSIS
        Loads a printer and share configuration into the editing controls on the settings page

    .DESCRIPTION
        Rebuilds the whole editor, including the printer and share rows, from the configuration that
        is currently in effect. Called when the settings page opens and again after every save, so
        the rows always show what is actually configured rather than what was typed before a
        rejected save.

    .PARAMETER Config
        The configuration to display

    #>
    param($Config)

    if (-not $sync["WPFEntCfgPrinterRows"]) { return }

    $sync.WPFEntCfgFormName.Text = [string]$Config.formName
    $sync.WPFEntCfgFormWidth.Text = ConvertTo-WinUtilEntMillimetre -Tenths $Config.formWidthTenthMm
    $sync.WPFEntCfgFormHeight.Text = ConvertTo-WinUtilEntMillimetre -Tenths $Config.formHeightTenthMm
    $sync.WPFEntCfgColorCode.Text = [string]$Config.colorUserCode

    Clear-WinUtilEntPrinterEditorRows
    foreach ($printer in @($Config.printers)) {
        if ($printer) { Add-WinUtilEntPrinterEditorRow -Printer $printer }
    }
    foreach ($share in @($Config.shares)) {
        if ($share) { Add-WinUtilEntShareEditorRow -Share $share }
    }

    $path = Get-WinUtilEntPrinterConfigPath
    if (Test-Path -LiteralPath $path) {
        $sync.WPFEntCfgSource.Text = "当前使用的是本机配置（$path）。「恢复内置配置」会删除这个文件，改用程序自带的配置。"
    } else {
        $sync.WPFEntCfgSource.Text = "当前使用的是程序内置配置。保存后写入 $path，只影响这台电脑。"
    }
    Set-WinUtilEntPrinterEditorStatus -Message ""
}

function Initialize-WinUtilEntPrinterSettings {

    <#

    .SYNOPSIS
        Fills the printer and share settings page from the configuration in effect

    #>
    Show-WinUtilEntPrinterEditor -Config $sync.configs.entprinters
}

function Update-WinUtilEntPrinterUiFromConfig {

    <#

    .SYNOPSIS
        Redraws both printing pages from the configuration that now applies

    .DESCRIPTION
        One call because the two pages read the same config: the settings page shows the rows that
        were just validated and written, and the operation page's choice lists have to follow them -
        otherwise the next install runs against a printer name the operator already deleted.

    #>
    Initialize-WinUtilEntPrinterPanel
    Initialize-WinUtilEntPrinterSettings
}

function Clear-WinUtilEntPrinterEditorRows {
    $sync["WPFEntCfgPrinterRows"].Children.Clear()
    $sync["WPFEntCfgShareRows"].Children.Clear()
    $sync.EntCfgPrinterRows = [System.Collections.Generic.List[object]]::new()
    $sync.EntCfgShareRows = [System.Collections.Generic.List[object]]::new()
}

function Add-WinUtilEntPrinterEditorRow {

    <#

    .SYNOPSIS
        One editable printer row: name, address, location, colour capability and a remove button

    .DESCRIPTION
        The driver package file names are not editable here on purpose. They belong to the driver
        rather than to the printer, every machine at one site installs from the same package, and
        putting six more boxes on the row would bury the four fields that actually differ. They are
        carried on the row and copied onto a new printer by the add button.

    #>
    param($Printer)

    $panel = $sync["WPFEntCfgPrinterRows"]
    if (-not $panel) { return }

    $grid = New-WinUtilEntEditorRowGrid -ColumnWidths @("star", "star", "star", "2star", "auto", "56")
    $nameBox = New-WinUtilEntEditorBox -Text ([string]$Printer.Name) -Label "打印机名称"
    $ipBox = New-WinUtilEntEditorBox -Text ([string]$Printer.Ip) -Label "IP 地址"
    $locationBox = New-WinUtilEntEditorBox -Text ([string]$Printer.Location) -Label "位置"
    $driverBox = New-WinUtilEntEditorBox -Text ([string]$Printer.DriverName) -Label "驱动名称"
    $colorBox = New-Object System.Windows.Controls.CheckBox
    $colorBox.Content = "支持彩色"
    $colorBox.IsChecked = [bool]$Printer.SupportColor
    $colorBox.Margin = New-Object System.Windows.Thickness(0, 0, 10, 0)
    $colorBox.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $colorBox.SetResourceReference([System.Windows.Controls.CheckBox]::ForegroundProperty, "MainForegroundColor")

    [System.Windows.Controls.Grid]::SetColumn($nameBox, 0)
    [System.Windows.Controls.Grid]::SetColumn($ipBox, 1)
    [System.Windows.Controls.Grid]::SetColumn($locationBox, 2)
    [System.Windows.Controls.Grid]::SetColumn($driverBox, 3)
    [System.Windows.Controls.Grid]::SetColumn($colorBox, 4)
    $grid.Children.Add($nameBox) | Out-Null
    $grid.Children.Add($ipBox) | Out-Null
    $grid.Children.Add($locationBox) | Out-Null
    $grid.Children.Add($driverBox) | Out-Null
    $grid.Children.Add($colorBox) | Out-Null

    $record = [pscustomobject]@{
        Grid      = $grid
        Name      = $nameBox
        Ip        = $ipBox
        Location  = $locationBox
        Driver    = $driverBox
        Color     = $colorBox
        # Everything the row does not show but still has to write back out
        Data      = $Printer
    }
    $removeButton = New-WinUtilEntEditorRemoveButton -Record $record -List $sync.EntCfgPrinterRows -Panel $panel
    [System.Windows.Controls.Grid]::SetColumn($removeButton, 5)
    $grid.Children.Add($removeButton) | Out-Null

    $panel.Children.Add($grid) | Out-Null
    $sync.EntCfgPrinterRows.Add($record) | Out-Null
}

function Add-WinUtilEntShareEditorRow {

    <#

    .SYNOPSIS
        One editable share row: name, drive letter, paths, account and password

    .DESCRIPTION
        Paths are one per line because a share can be reachable under several names across sites and
        the mapping step tries them in order. The password box is a PasswordBox, not a TextBox, so
        what is on screen is not readable over the operator's shoulder on a shared machine.

    #>
    param($Share)

    $panel = $sync["WPFEntCfgShareRows"]
    if (-not $panel) { return }

    $grid = New-WinUtilEntEditorRowGrid -ColumnWidths @("star", "60", "3star", "star", "star", "56")
    $nameBox = New-WinUtilEntEditorBox -Text ([string]$Share.Name) -Label "共享名称"
    $driveBox = New-WinUtilEntEditorBox -Text ([string]$Share.Drive) -Label "盘符"
    $userBox = New-WinUtilEntEditorBox -Text ([string]$Share.User) -Label "账号"

    $pathBox = New-Object System.Windows.Controls.TextBox
    $pathBox.Text = (@(@($Share.Paths) | ForEach-Object { [string]$_ }) -join "`r`n")
    $pathBox.AcceptsReturn = $true
    $pathBox.TextWrapping = [System.Windows.TextWrapping]::Wrap
    $pathBox.Height = 52
    $pathBox.Margin = New-Object System.Windows.Thickness(0, 0, 8, 0)
    $pathBox.VerticalScrollBarVisibility = [System.Windows.Controls.ScrollBarVisibility]::Auto
    [System.Windows.Automation.AutomationProperties]::SetAutomationId($pathBox, "共享路径")

    $passBox = New-Object System.Windows.Controls.PasswordBox
    $passBox.Password = [string]$Share.Pass
    $passBox.Margin = New-Object System.Windows.Thickness(0, 0, 8, 0)
    $passBox.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    [System.Windows.Automation.AutomationProperties]::SetAutomationId($passBox, "共享密码")

    [System.Windows.Controls.Grid]::SetColumn($nameBox, 0)
    [System.Windows.Controls.Grid]::SetColumn($driveBox, 1)
    [System.Windows.Controls.Grid]::SetColumn($pathBox, 2)
    [System.Windows.Controls.Grid]::SetColumn($userBox, 3)
    [System.Windows.Controls.Grid]::SetColumn($passBox, 4)
    $grid.Children.Add($nameBox) | Out-Null
    $grid.Children.Add($driveBox) | Out-Null
    $grid.Children.Add($pathBox) | Out-Null
    $grid.Children.Add($userBox) | Out-Null
    $grid.Children.Add($passBox) | Out-Null

    $record = [pscustomobject]@{
        Grid   = $grid
        Name   = $nameBox
        Drive  = $driveBox
        Paths  = $pathBox
        User   = $userBox
        Pass   = $passBox
        Data   = $Share
    }
    $removeButton = New-WinUtilEntEditorRemoveButton -Record $record -List $sync.EntCfgShareRows -Panel $panel
    [System.Windows.Controls.Grid]::SetColumn($removeButton, 5)
    $grid.Children.Add($removeButton) | Out-Null

    $panel.Children.Add($grid) | Out-Null
    $sync.EntCfgShareRows.Add($record) | Out-Null
}

function New-WinUtilEntEditorRowGrid {

    <#

    .SYNOPSIS
        A row of columns sized by name rather than by pixel arithmetic

    .DESCRIPTION
        "star", "2star", "auto" and a pixel count. The widths belong here, not on the boxes, because
        a fixed-width TextBox inside a star column overflows its cell and lands on its neighbour -
        and the card has to survive a window that is narrower than the designer expected.

    #>
    param([string[]]$ColumnWidths)

    $grid = New-Object System.Windows.Controls.Grid
    $grid.Margin = New-Object System.Windows.Thickness(0, 3, 0, 3)
    foreach ($spec in @($ColumnWidths)) {
        $column = New-Object System.Windows.Controls.ColumnDefinition
        if ($spec -match "^(\d+)star$") {
            $column.Width = New-Object System.Windows.GridLength([double]$Matches[1], [System.Windows.GridUnitType]::Star)
        } elseif ($spec -eq "star") {
            $column.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
        } elseif ($spec -eq "auto") {
            $column.Width = [System.Windows.GridLength]::Auto
        } elseif ($spec -match "^\d+$") {
            $column.Width = New-Object System.Windows.GridLength([double]$spec, [System.Windows.GridUnitType]::Pixel)
        } else {
            throw "未知的列宽写法「$spec」"
        }
        $grid.ColumnDefinitions.Add($column) | Out-Null
    }

    return $grid
}

function New-WinUtilEntEditorBox {
    param([string]$Text, [string]$Label)

    $box = New-Object System.Windows.Controls.TextBox
    $box.Text = $Text
    $box.Margin = New-Object System.Windows.Thickness(0, 0, 8, 0)
    $box.VerticalContentAlignment = [System.Windows.VerticalAlignment]::Center
    [System.Windows.Automation.AutomationProperties]::SetAutomationId($box, $Label)

    return $box
}

function New-WinUtilEntEditorRemoveButton {
    param($Record, $List, $Panel)

    $button = New-Object System.Windows.Controls.Button
    $button.Content = "删除"
    $button.Padding = New-Object System.Windows.Thickness(8, 2, 8, 2)
    $button.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
    # The theme's button style pins every Button to 200x25. In a 56 pixel column that leaves a
    # box with the label clipped away, so the row reads as an empty rectangle: size to the
    # content instead, and keep a clickable height.
    $button.Width = [double]::NaN
    $button.Height = [double]::NaN
    $button.MinHeight = 26
    $button.MinWidth = 44
    $button.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $button.Tag = @{ Record = $Record; List = $List; Panel = $Panel }
    # The row object travels in the button's own Tag: the panel is rebuilt from the config whenever
    # the tab opens, and a handler that looked rows up by position would delete the wrong one.
    $button.Add_Click({
        $state = $this.Tag
        $null = $state.Panel.Children.Remove($state.Record.Grid)
        $null = $state.List.Remove($state.Record)
    })

    return $button
}

function ConvertTo-WinUtilEntMillimetre {

    <#

    .SYNOPSIS
        Tenths of a millimetre as the operator reads it: millimetres, no trailing zero

    #>
    param($Tenths)

    $value = 0
    if (-not [int]::TryParse(("" + $Tenths).Trim(), [ref]$value)) { return "" }
    $mm = $value / 10.0
    if ($mm -eq [math]::Floor($mm)) { return ([int]$mm).ToString([System.Globalization.CultureInfo]::InvariantCulture) }
    return $mm.ToString("0.#", [System.Globalization.CultureInfo]::InvariantCulture)
}

function ConvertFrom-WinUtilEntMillimetre {

    <#

    .SYNOPSIS
        What the operator typed in millimetres, as tenths

    .DESCRIPTION
        Text that is not a number is handed back unchanged so the validator can say which field is
        wrong; turning it into zero here would report "宽度只能是 10～3276.7 毫米" about a blank box.

    #>
    param([string]$Text)

    $trimmed = ("" + $Text).Trim()
    $mm = 0.0
    if (-not [double]::TryParse($trimmed, [ref]$mm)) { return $trimmed }
    return [int][math]::Round($mm * 10)
}

function Get-WinUtilEntPrinterEditorConfig {

    <#

    .SYNOPSIS
        Everything in the editing controls, as a configuration object

    .DESCRIPTION
        Reads the rows in display order and leaves the values untrimmed and unparsed: normalizing is
        Write-WinUtilEntPrinterConfig's job, and doing it once means the editor and a hand-edited
        file cannot drift apart.

    #>
    $printers = [System.Collections.Generic.List[object]]::new()
    foreach ($row in @($sync.EntCfgPrinterRows)) {
        $source = $row.Data
        $printers.Add((New-Object psobject -Property ([ordered]@{
            Name           = $row.Name.Text
            Ip             = $row.Ip.Text
            PortName       = [string]$source.PortName
            DriverName     = $row.Driver.Text
            DriverZip      = [string]$source.DriverZip
            DriverFile     = [string]$source.DriverFile
            DataFile       = [string]$source.DataFile
            ConfigFile     = [string]$source.ConfigFile
            HelpFile       = [string]$source.HelpFile
            DependentFiles = @(@($source.DependentFiles) | Where-Object { $_ })
            Location       = $row.Location.Text
            SupportColor   = [bool]$row.Color.IsChecked
        })))
    }

    $shares = [System.Collections.Generic.List[object]]::new()
    foreach ($row in @($sync.EntCfgShareRows)) {
        $paths = @($row.Paths.Text -split "`r?`n" | Where-Object { $_.Trim() })
        $shares.Add((New-Object psobject -Property ([ordered]@{
            Name  = $row.Name.Text
            Paths = $paths
            User  = $row.User.Text
            Pass  = $row.Pass.Password
            Drive = $row.Drive.Text
        })))
    }

    return New-Object psobject -Property ([ordered]@{
        formName          = $sync.WPFEntCfgFormName.Text
        formWidthTenthMm  = ConvertFrom-WinUtilEntMillimetre -Text $sync.WPFEntCfgFormWidth.Text
        formHeightTenthMm = ConvertFrom-WinUtilEntMillimetre -Text $sync.WPFEntCfgFormHeight.Text
        colorUserCode     = $sync.WPFEntCfgColorCode.Text
        driverDirNames    = @(@($sync.configs.entprinters.driverDirNames) | Where-Object { $_ })
        printers          = $printers.ToArray()
        shares            = $shares.ToArray()
    })
}

function Set-WinUtilEntPrinterEditorStatus {

    <#

    .SYNOPSIS
        Says what happened to the last save, in the colour of whether it went well

    #>
    param([string[]]$Problems, [string]$Message)

    $status = $sync["WPFEntCfgStatus"]
    if (-not $status) { return }

    if ($Problems -and @($Problems).Count -gt 0) {
        $status.Text = "保存未生效：`n" + (@($Problems) -join "`n")
        $status.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, "ProgressBarErrorColor")
        return
    }

    $status.Text = $Message
    $status.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, "MainForegroundColor")
}

function Get-WinUtilEntPrinterTemplate {

    <#

    .SYNOPSIS
        The configuration a newly added printer copies its hidden driver fields from

    .DESCRIPTION
        New-WinUtilEntPrinterEntry borrows the driver file names off the first printer it is given.
        There is always one: the validator will not let the last printer be deleted, so what is in
        memory is enough, and the built-in copy is there for the case where even that is missing.

    #>
    $cfg = $sync.configs.entprinters
    if (-not $cfg -or -not @($cfg.printers | Where-Object { $_ }).Count) {
        $cfg = $sync.configs.entprintersDefault
    }

    return $cfg
}
