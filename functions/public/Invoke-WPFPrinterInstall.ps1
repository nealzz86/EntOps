function Invoke-WPFPrinterInstall {

    <#

    .SYNOPSIS
        Reads the printer tab selections on the UI thread and starts the install job

    .PARAMETER Button
        Unused; present so the generic button router can pass it through

    #>
    param([string]$Button)

    $cfg = $sync.configs.entprinters
    $printerIndex = Get-WinUtilSelectedPrinterIndex
    $printer = if ($printerIndex -ge 0) { @($cfg.printers)[$printerIndex] } else { $null }
    if (-not $printer) {
        Write-Host "  没有选中的打印机，请先在「本机打印与共享配置」里添加。"
        return
    }

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

function Invoke-WPFPrinterFormColorOnly {

    <#

    .SYNOPSIS
        Re-applies the receipt paper form and the colour lockdown to an installed printer

    .DESCRIPTION
        For the machine that already has the printer — a reimaged desk, a driver that reset itself,
        a colleague who re-added it by hand. It runs the tail of the install only, so nothing here
        touches the port or the driver package.

    .PARAMETER Button
        Unused; present so the generic button router can pass it through

    #>
    param([string]$Button)

    $cfg = $sync.configs.entprinters
    $printerIndex = Get-WinUtilSelectedPrinterIndex
    $printer = if ($printerIndex -ge 0) { @($cfg.printers)[$printerIndex] } else { $null }
    if (-not $printer) {
        Write-Host "  没有选中的打印机，请先在「本机打印与共享配置」里添加。"
        return
    }

    $answer = Show-WinUtilMessage `
        -Message "只重设「$($printer.Name)」的易快报纸张与颜色模式，不改动端口和驱动。`n配置纸张需要重启 Print Spooler 服务，这会中断这台电脑正在进行的其他打印任务。是否继续？" `
        -Title "仅设置纸张与颜色？" `
        -Button "YesNo" `
        -Icon "Warning"
    if ($answer -ne "Yes") {
        Write-Host "已取消，未改动打印机设置。"
        return
    }

    Start-WinUtilJob -Name "纸张与颜色重设" -Parameters @{ Printer = $printer } -ScriptBlock {
        param($Printer)

        Add-WinUtilEntNatives
        Write-Host "========== 仅设置易快报纸张与颜色 =========="
        Write-Host "打印机名称：$($Printer.Name)"
        Write-Host "模式      ：$(if ($Printer.SupportColor) { '彩色机型，不强制黑白' } else { '黑白机型，强制 dmColor=MONOCHROME' })"
        Write-Host "======================================================"

        if (-not [EntSpool]::PrinterExists($Printer.Name)) {
            Write-Host "  [错误] 本机没有名为「$($Printer.Name)」的打印机。请先点「开始安装打印机」完成安装。"
            Step-WinUtilJob -Status "未找到打印机" -Percent 100 -State Error
            Write-WinUtilLog -Level "ERROR" -Component "Printers" -Message "Paper/color reset refused, printer not installed: $($Printer.Name)"
            return
        }

        Step-WinUtilJob -Status "1/2 · 配置易快报打印模式中…" -Percent 0
        if (-not (Set-WinUtilPrinterPaperAndColor -Printer $Printer)) {
            Write-Host "  [错误] 易快报纸张配置失败，颜色模式已经生效。可重启电脑后重试。"
            Step-WinUtilJob -Status "纸张配置失败" -Percent 100 -State Error
            Write-WinUtilLog -Level "ERROR" -Component "Printers" -Message "Paper form registration failed: $($Printer.Name)"
            return
        }

        Step-WinUtilJob -Status "2/2 · 启用传统打印对话框…" -Percent 60
        $entCfg = $sync.configs.entprinters
        Enable-WinUtilLegacyPrintDialog -FormName $entCfg.formName | Out-Null

        Step-WinUtilJob -Status "完成" -Percent 100
        $sizeText = "$([int]($entCfg.formWidthTenthMm / 10))×$([int]($entCfg.formHeightTenthMm / 10))mm"
        Write-Host ""
        Write-Host "======================================================"
        Write-Host "              ✅ 纸张与颜色已重设"
        Write-Host "======================================================"
        Write-Host "1. 打印时纸张下拉框应显示「$($entCfg.formName)」"
        Write-Host "2. 如仍看不到，请在打印对话框选择「自定义纸张尺寸」手动输入 $sizeText"
        Write-Host "3. 本次只改纸张与颜色，端口和驱动没有动"
        Write-Host "如有问题，请联系信息部，谢谢！"
        Write-Host "======================================================"
        Write-WinUtilLog -Level "INFO" -Component "Printers" -Message "Paper/color reset finished: $($Printer.Name)"
    }
}

function Invoke-WPFShareMapOnly {

    <#

    .SYNOPSIS
        Maps only the checked shared folders, without touching printers

    #>
    param([string]$Button)

    $shareIndices = @(Get-WinUtilSelectedShareIndices)

    if ($shareIndices.Count -eq 0) {
        Write-Host "请至少勾选一个要映射的共享文件夹。"
        return
    }

    Start-WinUtilJob -Name "共享映射" -Parameters @{ Indices = $shareIndices } -ScriptBlock {
        param($Indices)
        Write-Host "========== 共享文件夹映射 =========="
        Mount-WinUtilShares -Indices $Indices
        Write-Host "✅ 共享文件夹映射完成，可在「此电脑」中查看新增的网络驱动器。"
    }
}
