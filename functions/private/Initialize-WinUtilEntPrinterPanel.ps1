function Initialize-WinUtilEntPrinterPanel {

    <#

    .SYNOPSIS
        Fills the printing tab from the enterprise printer config

    .DESCRIPTION
        The interface markup carries no machine names, addresses or share accounts: they belong to
        one site only, and the published build is meant to be reusable elsewhere. Whatever the
        config holds is written onto the controls here, and the choice lists are regenerated on
        every visit to the tab so an edit made in the configuration editor shows up at once.

    #>

    $cfg = $sync.configs.entprinters
    if (-not $cfg) { return }

    # Rows are filtered before generating so the control index and the config index stay the same
    $printers = @($cfg.printers | Where-Object { $_ })
    $shares = @($cfg.shares | Where-Object { $_ })
    Update-WinUtilEntPrinterSelection -Printers $printers -Shares $shares

    $colorMode = $sync["WPFPrinterModeColor"]
    if ($colorMode) {
        $colorMode.Content = if ($cfg.colorUserCode) { "彩色（用户代码 $($cfg.colorUserCode)）" } else { "彩色（无用户代码）" }
    }

    $installButton = $sync["WPFPrinterInstall"]
    if ($installButton) {
        $installButton.IsEnabled = ($printers.Count -gt 0)
    }
    $formButton = $sync["WPFPrinterFormColorOnly"]
    if ($formButton) {
        $formButton.IsEnabled = ($printers.Count -gt 0)
    }
    $mapButton = $sync["WPFShareMapOnly"]
    if ($mapButton) {
        $mapButton.IsEnabled = ($shares.Count -gt 0)
    }

    Show-WinUtilEntPrinterEditor -Config $cfg
}
