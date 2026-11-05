function Invoke-WPFEntPrinterConfigAddPrinter {

    <#

    .SYNOPSIS
        Appends a blank printer row to the configuration editor

    .PARAMETER Button
        Unused; present so the generic button router can pass it through

    #>
    param([string]$Button)

    Add-WinUtilEntPrinterEditorRow -Printer (New-WinUtilEntPrinterEntry -Template (Get-WinUtilEntPrinterTemplate))
    Set-WinUtilEntPrinterEditorStatus -Message "新增的打印机还未保存。"
}

function Invoke-WPFEntPrinterConfigAddShare {

    <#

    .SYNOPSIS
        Appends a blank share row to the configuration editor

    .PARAMETER Button
        Unused; present so the generic button router can pass it through

    #>
    param([string]$Button)

    Add-WinUtilEntShareEditorRow -Share (New-WinUtilEntShareEntry)
    Set-WinUtilEntPrinterEditorStatus -Message "新增的共享文件夹还未保存。"
}

function Invoke-WPFEntPrinterConfigSave {

    <#

    .SYNOPSIS
        Validates the editor and writes this machine's printer and share configuration

    .DESCRIPTION
        Runs on the interface thread: it is a file write of a few kilobytes, and putting it in a job
        would make the operator wait behind the progress bar for something that finishes before the
        bar could paint. On success both printing pages are rebuilt from the saved configuration -
        the rows here and the choice lists on the 「打印共享」 page - so nothing on screen is left
        describing a config that no longer applies.

    .PARAMETER Button
        Unused; present so the generic button router can pass it through

    #>
    param([string]$Button)

    $problems = @(Write-WinUtilEntPrinterConfig -Config (Get-WinUtilEntPrinterEditorConfig))
    if ($problems.Count -gt 0) {
        Set-WinUtilEntPrinterEditorStatus -Problems $problems
        foreach ($problem in $problems) {
            Write-Host "  [配置未保存] $problem"
        }
        return
    }

    # Rebuilds the rows as well, which clears any status line from the previous attempt
    Update-WinUtilEntPrinterUiFromConfig
    Set-WinUtilEntPrinterEditorStatus -Message "已保存到 $(Get-WinUtilEntPrinterConfigPath)，「打印共享」页的列表已同步更新。"
    Write-Host "  本机打印与共享配置已保存。"
}

function Invoke-WPFEntPrinterConfigReset {

    <#

    .SYNOPSIS
        Discards this machine's configuration so the built-in one applies again

    .PARAMETER Button
        Unused; present so the generic button router can pass it through

    #>
    param([string]$Button)

    $path = Get-WinUtilEntPrinterConfigPath
    if (-not (Test-Path -LiteralPath $path)) {
        Set-WinUtilEntPrinterEditorStatus -Message "这台电脑没有保存过自己的配置，当前就是内置配置。"
        return
    }

    $answer = Show-WinUtilMessage `
        -Message "删除本机保存的打印机与共享配置（$path），恢复为程序内置配置？`n界面上未保存的修改也会一并丢失。" `
        -Title "恢复内置配置？" `
        -Button "YesNo" `
        -Icon "Warning"
    if ($answer -ne "Yes") {
        Write-Host "已取消，本机配置未改动。"
        return
    }

    Remove-WinUtilEntPrinterConfig
    Update-WinUtilEntPrinterUiFromConfig
    Set-WinUtilEntPrinterEditorStatus -Message "已删除本机配置，当前使用程序内置配置。"
    Write-Host "  已恢复内置打印与共享配置。"
}
