function Update-WinUtilEntPrinterSelection {

    <#

    .SYNOPSIS
        Builds the printer radio buttons and share checkboxes from the configuration

    .DESCRIPTION
        A site can have any number of printers and shares, and the count changes when the operator
        edits the configuration on the machine itself, so the choices are generated here rather than
        being written into the markup. The previous selection is carried across a rebuild: after
        adding a printer the operator should still be choosing the printer they were choosing.

    .PARAMETER Printers
        The configured printers, in display order

    .PARAMETER Shares
        The configured shared folders, in display order

    #>
    param($Printers, $Shares)

    $radioPanel = $sync["WPFPrinterSelPanel"]
    $checkPanel = $sync["WPFShareSelPanel"]
    if (-not $radioPanel -or -not $checkPanel) { return }

    $selectedPrinter = Get-WinUtilSelectedPrinterIndex
    $selectedShares = @(Get-WinUtilSelectedShareIndices)

    $radioPanel.Children.Clear()
    $checkPanel.Children.Clear()
    $sync.EntPrinterRadios = [System.Collections.Generic.List[object]]::new()
    $sync.EntShareChecks = [System.Collections.Generic.List[object]]::new()

    # Each control carries the config index it was built from, so a blank row in the middle cannot
    # shift what the other rows point at.
    $printerList = @($Printers)
    for ($index = 0; $index -lt $printerList.Count; $index++) {
        $printer = $printerList[$index]
        if (-not $printer) { continue }

        $mode = if ($printer.SupportColor) { "彩色+黑白" } else { "仅黑白，会强制黑白模式" }
        $radio = New-Object System.Windows.Controls.RadioButton
        $radio.GroupName = "EntPrinterSelect"
        $radio.Margin = New-Object System.Windows.Thickness(0, 3, 0, 3)
        $radio.SetResourceReference([System.Windows.Controls.RadioButton]::ForegroundProperty, "MainForegroundColor")
        $radio.Tag = $index

        $label = New-Object System.Windows.Controls.TextBlock
        $label.Text = "$($printer.Name)　$($printer.Ip)　（$($printer.Location) · $mode）"
        $label.TextWrapping = [System.Windows.TextWrapping]::Wrap
        $radio.Content = $label

        $radio.IsChecked = ($index -eq $selectedPrinter)
        $radioPanel.Children.Add($radio) | Out-Null
        $sync.EntPrinterRadios.Add($radio) | Out-Null
    }

    $shareList = @($Shares)
    for ($index = 0; $index -lt $shareList.Count; $index++) {
        $share = $shareList[$index]
        if (-not $share) { continue }

        $path = if (@($share.Paths).Count -gt 0) { [string]$share.Paths[0] } else { "" }
        $box = New-Object System.Windows.Controls.CheckBox
        $box.Content = "$($share.Name)　→ $($share.Drive)　（$path）"
        $box.Margin = New-Object System.Windows.Thickness(0, 3, 0, 3)
        $box.SetResourceReference([System.Windows.Controls.CheckBox]::ForegroundProperty, "MainForegroundColor")
        $box.Tag = $index
        # Nothing chosen yet means every share is wanted, which is what a fresh machine expects
        $box.IsChecked = ($selectedShares.Count -eq 0 -or $index -in $selectedShares)

        $checkPanel.Children.Add($box) | Out-Null
        $sync.EntShareChecks.Add($box) | Out-Null
    }

    # A rebuild can lose the selection entirely when the printer that was chosen has been deleted,
    # and a list with no radio ticked would leave the install button with nothing to install.
    $anySelected = $false
    foreach ($radio in $sync.EntPrinterRadios) {
        if ($radio.IsChecked) { $anySelected = $true }
    }
    if (-not $anySelected -and $sync.EntPrinterRadios.Count -gt 0) {
        $sync.EntPrinterRadios[0].IsChecked = $true
    }
}

function Get-WinUtilSelectedPrinterIndex {

    <#

    .SYNOPSIS
        The config index of the printer the interface is choosing, or -1 when there is none

    .DESCRIPTION
        Returning -1 rather than 0 is deliberate: defaulting to the first printer would install a
        machine the operator never picked.

    #>
    foreach ($radio in @($sync.EntPrinterRadios)) {
        if ($radio.IsChecked) { return [int]$radio.Tag }
    }
    return -1
}

function Get-WinUtilSelectedShareIndices {

    <#

    .SYNOPSIS
        The config indexes of the ticked shares

    #>
    $indices = [System.Collections.Generic.List[int]]::new()
    foreach ($box in @($sync.EntShareChecks)) {
        if ($box.IsChecked) { $indices.Add([int]$box.Tag) | Out-Null }
    }
    return $indices.ToArray()
}
