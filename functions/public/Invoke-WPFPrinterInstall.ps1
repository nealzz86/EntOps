function Invoke-WPFPrinterInstall {

    <#

    .SYNOPSIS
        Reads the printer tab selections on the UI thread and starts the install job

    .PARAMETER Button
        Unused; present so the generic button router can pass it through

    #>
    param([string]$Button)

    $cfg = $sync.configs.entprinters
    $printerIndex = if ($sync.WPFPrinterSel2.IsChecked) { 1 } else { 0 }
    $printer = $cfg.printers[$printerIndex]

    $wantColor = [bool]$sync.WPFPrinterModeColor.IsChecked
    $mode = "BLACK"
    $userCode = ""
    if ($wantColor) {
        if ($printer.SupportColor) {
            $mode = "COLOR"
            $userCode = $cfg.colorUserCode
        } else {
            Write-Host "  [提示] $($printer.Name) 仅支持黑白，已自动按黑白模式安装。"
        }
    }

    Start-WinUtilJob -Name "打印机安装" -Parameters @{
        Printer        = $printer
        Mode           = $mode
        UserCode       = $userCode
        SetDefault     = [bool]$sync.WPFPrinterSetDefault.IsChecked
        TestPage       = [bool]$sync.WPFPrinterTestPage.IsChecked
    } -ScriptBlock {
        param($Printer, $Mode, $UserCode, $SetDefault, $TestPage)
        Install-WinUtilPrinter -Printer $Printer -Mode $Mode -UserCode $UserCode `
            -SetDefault $SetDefault -TestPage $TestPage
    }
}

function Invoke-WPFShareMapOnly {

    <#

    .SYNOPSIS
        Maps only the checked shared folders, without touching printers

    #>
    param([string]$Button)

    $shareIndices = @()
    if ($sync.WPFPrinterShare1.IsChecked) { $shareIndices += 0 }
    if ($sync.WPFPrinterShare2.IsChecked) { $shareIndices += 1 }
    if ($sync.WPFPrinterShare3.IsChecked) { $shareIndices += 2 }

    if ($shareIndices.Count -eq 0) {
        Write-Host "请至少勾选一个要映射的共享文件夹。"
        return
    }

    Start-WinUtilJob -Name "共享映射" -Parameters @{ Indices = $shareIndices } -ScriptBlock {
        param($Indices)
        Write-Host "========== 共享文件夹映射 =========="
        Map-WinUtilShares -Indices $Indices
        Write-Host "✅ 共享文件夹映射完成，可在「此电脑」中查看新增的网络驱动器。"
    }
}
