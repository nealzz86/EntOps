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
        After the spooler reloads, the effective defaults are read back from the driver and
        reported: a write that the driver silently rejects is told to the operator as a refusal,
        not as a finished job.

    .PARAMETER Printer
        Printer config object from configs.entprinters.printers

    #>
    param([Parameter(Mandatory)] $Printer)

    $cfg = $sync.configs.entprinters
    Add-WinUtilEntNatives

    # 黑白机强制 dmColor=MONOCHROME
    $wantMono = -not $Printer.SupportColor
    if ($wantMono) {
        [EntSpool]::SetColorMode($Printer.Name, $false)
        Write-WinUtilEntNativeLog
    }

    $widthMm = [int] ($cfg.formWidthTenthMm / 10)
    $heightMm = [int] ($cfg.formHeightTenthMm / 10)
    $formOk = [EntSpool]::RegisterPaperForm($Printer.Name, $cfg.formName, [int] $cfg.formWidthTenthMm, [int] $cfg.formHeightTenthMm, $(if ($wantMono) { 1 } else { 0 }))
    Write-WinUtilEntNativeLog
    if (-not $formOk) { return $false }

    Write-Host "  正在重启 Print Spooler 服务以刷新缓存（会中断本机进行中的打印任务）..."
    try {
        Restart-Service -Name Spooler -Force -ErrorAction Stop
        Write-Host "  Print Spooler 服务已重启，缓存已刷新。"
    } catch {
        Write-Host "  [警告] 重启 Spooler 失败：$($_.Exception.Message)"
    }

    # 写入调用返回成功不等于驱动认账：V4 驱动会在自己那份 DEVMODE 上把不要的字段改回去，
    # 界面必须报驱动实际生效的值，否则运维会拿着"配置完成"去现场才发现下拉框里根本没有那张纸。
    $eff = @()
    foreach ($attempt in 1..3) {
        $eff = ([EntSpool]::ReadEffectiveDefaults($Printer.Name) -split '\|')
        if ($eff.Count -ge 5 -and $eff[0] -ne 'error') { break }
        if ($eff.Count -lt 5 -or $eff[0] -eq 'error') { Start-Sleep -Milliseconds 800 }
    }

    if ($eff.Count -lt 5 -or $eff[0] -eq 'error') {
        Write-Host "  [提示] 无法回读驱动的默认设置（$($eff -join ' ')），请按上面提示自行确认。"
        return $true
    }

    $effColor = [int] $eff[0]
    $effWidth = [int] $eff[2]
    $effHeight = [int] $eff[3]

    if ($wantMono) {
        if ($effColor -eq 1) { Write-Host "  黑白已生效：这台打印机现在默认单色输出。" }
        else { Write-Host "  [警告] 黑白未生效，驱动回读仍是彩色（dmColor=$effColor）。这台设备的驱动不认队列默认值里的颜色字段，需要在业务软件的打印设置里逐次选黑白。" }
    }

    if ($effWidth -eq [int] $cfg.formWidthTenthMm -and $effHeight -eq [int] $cfg.formHeightTenthMm) {
        Write-Host "  默认纸张已生效：${widthMm}×${heightMm}mm。"
    } else {
        $effMm = "$([math]::Round($effWidth / 10))×$([math]::Round($effHeight / 10))mm"
        Write-Host "  [注意] 「$($cfg.formName)」已登记进打印服务器的纸张表，但驱动回读的默认纸张仍是 $effMm，没有采纳 ${widthMm}×${heightMm}mm。"
        Write-Host "  这类 V4 驱动只把出厂清单里的纸张交给应用程序，所以 Windows 打印首选项的下拉框选不到这张自定义纸——是驱动限制，不是本机没配置。"
        Write-Host "  两个办法：① 在业务软件的打印设置里手动输入 ${widthMm}×${heightMm}mm（选「自定义纸张尺寸」）；② 装这台机型对应的专用驱动，通用驱动通常不容纳自定义纸。"
    }

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
