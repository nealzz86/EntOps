function Set-WinUtilPrinterPaperAndColor {

    <#

    .SYNOPSIS
        Applies the custom receipt paper form and the mono lock to a printer that already exists

    .DESCRIPTION
        The tail of the install, pulled out so a machine that already has the printer can be re-set
        without re-running the port and driver work. Both entry points go through here: the paper
        name, the DEVMODE sizes and the spooler restart live in one place, so the standalone button
        cannot drift away from whatever the full install ends up writing.
        Runs inside a WinUtil job, so it must not touch WPF controls directly. Returns $true once
        the form is registered and $false when the driver refused it, leaving the caller to say
        what a refusal means for its own flow.

    .PARAMETER Printer
        Printer config object from configs.entprinters.printers

    #>
    param([Parameter(Mandatory)] $Printer)

    $cfg = $sync.configs.entprinters
    Add-WinUtilEntNatives

    # 黑白机强制 dmColor=MONOCHROME
    if (-not $Printer.SupportColor) {
        [EntSpool]::SetColorMode($Printer.Name, $false)
        Write-WinUtilEntNativeLog
    }

    $widthMm = [int] ($cfg.formWidthTenthMm / 10)
    $heightMm = [int] ($cfg.formHeightTenthMm / 10)
    $formOk = [EntSpool]::RegisterPaperForm($Printer.Name, $cfg.formName, [int] $cfg.formWidthTenthMm, [int] $cfg.formHeightTenthMm)
    Write-WinUtilEntNativeLog
    if (-not $formOk) { return $false }

    Write-Host "  正在重启 Print Spooler 服务以刷新缓存（会中断本机进行中的打印任务）..."
    try {
        Restart-Service -Name Spooler -Force -ErrorAction Stop
        Write-Host "  Print Spooler 服务已重启，缓存已刷新。"
    } catch {
        Write-Host "  [警告] 重启 Spooler 失败：$($_.Exception.Message)"
    }
    Write-Host "  提示：如打印首选项下拉框未显示该纸张，请在应用中选择「自定义纸张尺寸」手动输入 ${widthMm}×${heightMm}mm。"

    return $true
}

function Enable-WinUtilLegacyPrintDialog {

    <#

    .SYNOPSIS
        Switches Windows over to the classic print dialog, the one that lists custom paper sizes

    .DESCRIPTION
        The modern flyout dialog only offers the handful of sizes it knows about, so a form
        registered through AddForm never shows up in it. Setting the HKLM key brings back the
        classic dialog, which builds its paper list from the driver's form table. Needs
        administrator rights; a refusal is reported as a warning because the printer itself is
        already usable by then.

    .PARAMETER FormName
        Paper form name to mention in the success line, so the operator knows what to look for

    #>
    param([string] $FormName = "")

    try {
        $printKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Print"
        if (-not (Test-Path -LiteralPath $printKey)) { New-Item -Path $printKey -Force | Out-Null }
        Set-ItemProperty -LiteralPath $printKey -Name "UseLegacyPrintDialog" -Value 1 -Type DWord
        $tail = if ($FormName) { "，纸张下拉框应能看到「$FormName」。" } else { "。" }
        Write-Host "  已启用传统打印对话框（UseLegacyPrintDialog=1）$tail"
        return $true
    } catch {
        Write-Host "  [警告] 启用传统打印对话框失败：$($_.Exception.Message)"
        return $false
    }
}
