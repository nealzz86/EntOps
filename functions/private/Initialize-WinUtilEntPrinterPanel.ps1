function Initialize-WinUtilEntPrinterPanel {

    <#

    .SYNOPSIS
        Fills the printing tab labels from the enterprise printer config

    .DESCRIPTION
        The interface markup carries no machine names, addresses or share accounts: they belong to
        one site only, and the published build is meant to be reusable elsewhere. Whatever the
        config holds is written onto the controls here, and a slot with nothing configured for it
        is hidden rather than showing an example value.

    #>

    $cfg = $sync.configs.entprinters
    if (-not $cfg) { return }

    $printers = @($cfg.printers)
    for ($i = 1; $i -le 2; $i++) {
        $radio = $sync["WPFPrinterSel$i"]
        $label = $sync["WPFPrinterSel${i}Label"]
        if (-not $radio) { continue }

        $printer = $printers[$i - 1]
        if (-not $printer) {
            $radio.Visibility = [System.Windows.Visibility]::Collapsed
            continue
        }
        $radio.Visibility = [System.Windows.Visibility]::Visible
        if ($label) {
            $mode = if ($printer.SupportColor) { "彩色+黑白" } else { "仅黑白，会强制黑白模式" }
            $label.Text = "$($printer.Name)　$($printer.Ip)　（$($printer.Location) · $mode）"
        }
    }

    $colorMode = $sync["WPFPrinterModeColor"]
    if ($colorMode) {
        $colorMode.Content = if ($cfg.colorUserCode) { "彩色（用户代码 $($cfg.colorUserCode)）" } else { "彩色（无用户代码）" }
    }

    $shares = @($cfg.shares)
    for ($i = 1; $i -le 3; $i++) {
        $box = $sync["WPFPrinterShare$i"]
        if (-not $box) { continue }

        $share = $shares[$i - 1]
        if (-not $share) {
            $box.Visibility = [System.Windows.Visibility]::Collapsed
            continue
        }
        $box.Visibility = [System.Windows.Visibility]::Visible
        $path = if (@($share.Paths).Count -gt 0) { [string]$share.Paths[0] } else { "" }
        $box.Content = "$($share.Name)　→ $($share.Drive)　（$path）"
    }

    $installButton = $sync["WPFPrinterInstall"]
    if ($installButton) {
        $installButton.IsEnabled = ($printers.Count -gt 0)
    }
}
