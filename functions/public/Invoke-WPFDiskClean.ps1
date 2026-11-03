function Invoke-WPFDiskScan {

    <#

    .SYNOPSIS
        Scans the fixed junk categories and prints the size next to each checkbox

    #>
    param([string]$Button)

    Start-WinUtilJob -Name "磁盘扫描" -Description "正在扫描垃圾文件占用" -ScriptBlock {
        $defs = Get-WinUtilDiskJunkDefs
        Write-WinUtilDiskLog -Message "开始扫描 $($defs.Count) 类垃圾文件……"

        $grand = [long]0
        $index = 0
        foreach ($def in $defs) {
            $index++
            Step-WinUtilJob -Status "正在扫描 $($def.Name)" -Percent (10 + [int](85 * $index / $defs.Count))
            $bytes = [long]0
            try { $bytes = Measure-WinUtilDiskJunkDef -Def $def } catch { }
            $grand += $bytes

            Invoke-WPFUIThread -Parameters @{ Id = $def.Id; Size = (Format-WinUtilJunkSize $bytes) } -ScriptBlock {
                param($Id, $Size)
                $label = $sync["WPFDiskSize$Id"]
                if ($null -ne $label) { $label.Text = $Size }
            }
            Write-WinUtilDiskLog -Message "$($def.Name)：$(Format-WinUtilJunkSize $bytes)"
        }

        Write-WinUtilDiskLog -Message "扫描完成，合计可清理约 $(Format-WinUtilJunkSize $grand)。勾选项目后点击「清理勾选项」。"
    }
}

function Invoke-WPFDiskClean {

    <#

    .SYNOPSIS
        Confirms and cleans the checked junk categories

    #>
    param([string]$Button)

    $boxes = @{
        TempUser = "WPFDiskTempUser"; TempSys  = "WPFDiskTempSys"
        Recycle  = "WPFDiskRecycle";  Update   = "WPFDiskUpdate"
        Browser  = "WPFDiskBrowser";  Dumps    = "WPFDiskDumps"
        Thumb    = "WPFDiskThumb";    Shaders  = "WPFDiskShaders"
        WeChat   = "WPFDiskWeChat";   Ding     = "WPFDiskDing"
        Wps      = "WPFDiskWps";      WinOld   = "WPFDiskWinOld"
        AiChat   = "WPFDiskAiChat";   AiCoder  = "WPFDiskAiCoder"
        AiUpdater = "WPFDiskAiUpdater"; AiModels = "WPFDiskAiModels"
        LocalCache = "WPFDiskLocalCache"; LocalNet = "WPFDiskLocalNet"
        LocalDev = "WPFDiskLocalDev"
    }

    $selectedIds = @()
    $selectedNames = @()
    foreach ($def in (Get-WinUtilDiskJunkDefs)) {
        $box = $sync[$boxes[$def.Id]]
        if ($box -and $box.IsChecked) {
            $selectedIds += $def.Id
            $selectedNames += $def.Name
        }
    }

    if ($selectedIds.Count -eq 0) {
        Write-WinUtilDiskLog -Message "请先勾选至少一个要清理的项目（可先点「扫描垃圾占用」查看大小）。" -Level "WARN"
        return
    }

    $notes = @(
        "回收站清空后无法找回，请确认无需恢复。"
        "正在被占用的文件会自动跳过，不会中断清理。"
    )
    if ($selectedIds -contains "AiUpdater") { $notes += "「应用更新安装包残留」删的是已下载的升级包，应用下次检查更新时会重新下载。" }
    if ($selectedIds -contains "AiModels") { $notes += "「本地大模型文件」删掉后需要重新下载，通常几 GB 到几十 GB，请先确认模型还能拿到。" }
    if ($selectedIds -contains "LocalDev") { $notes += "「开发与自动化缓存」删掉后 pip/npm/uv/Playwright 要联网重新下载，单位离线环境请确认这台机器不再构建。" }
    if ($selectedIds -contains "LocalCache") { $notes += "「AppData\Local 应用缓存」只动标准缓存与日志子目录，应用首次启动会稍慢一点。" }

    $answer = Show-WinUtilMessage -Title "磁盘清理" -Button "YesNo" -Icon "Warning" -Message @"
将清理以下 $($selectedIds.Count) 类垃圾文件：

$($selectedNames -join "、")

- $($notes -join "`n- ")

确定开始清理吗？
"@
    if ($answer -ne "Yes") { return }

    Start-WinUtilJob -Name "磁盘清理" -Description "正在清理垃圾文件" -Parameters @{
        Ids = $selectedIds
    } -ScriptBlock {
        param($Ids)

        $wanted = @(Get-WinUtilDiskJunkDefs | Where-Object { $Ids -contains $_.Id })
        $grand = [long]0
        $index = 0
        foreach ($def in $wanted) {
            $index++
            Step-WinUtilJob -Status "正在清理 $($def.Name)" -Percent (10 + [int](85 * $index / $wanted.Count))
            Write-WinUtilDiskLog -Message "正在清理 $($def.Name) ……"
            try {
                $freed = Clear-WinUtilDiskJunkDef -Def $def
                $grand += $freed
                Invoke-WPFUIThread -Parameters @{ Id = $def.Id } -ScriptBlock {
                    param($Id)
                    $label = $sync["WPFDiskSize$Id"]
                    if ($null -ne $label) { $label.Text = "已清理" }
                }
                Write-WinUtilDiskLog -Message "$($def.Name)：释放 $(Format-WinUtilJunkSize $freed)"
            } catch {
                Write-WinUtilDiskLog -Message "$($def.Name)：清理失败 $($_.Exception.Message)" -Level "ERROR"
            }
        }
        Write-WinUtilDiskLog -Message "✅ 清理完成，共释放约 $(Format-WinUtilJunkSize $grand)。"
    }
}
