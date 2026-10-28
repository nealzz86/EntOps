function Invoke-WPFDiskScan {

    <#

    .SYNOPSIS
        Scans the fixed junk categories and prints the size next to each checkbox

    #>
    param([string]$Button)

    Start-WinUtilJob -Name "磁盘扫描" -Description "正在扫描垃圾文件占用" -ScriptBlock {
        $defs = Get-WinUtilDiskJunkDefs
        Append-WinUtilDiskLog -Message "开始扫描 $($defs.Count) 类垃圾文件……"

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
            Append-WinUtilDiskLog -Message "$($def.Name)：$(Format-WinUtilJunkSize $bytes)"
        }

        Append-WinUtilDiskLog -Message "扫描完成，合计可清理约 $(Format-WinUtilJunkSize $grand)。勾选项目后点击「清理勾选项」。"
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
        Append-WinUtilDiskLog -Message "请先勾选至少一个要清理的项目（可先点「扫描垃圾占用」查看大小）。" -Level "WARN"
        return
    }

    $answer = Show-WinUtilMessage -Title "磁盘清理" -Button "YesNo" -Icon "Warning" -Message @"
将清理以下 $($selectedIds.Count) 类垃圾文件：

$($selectedNames -join "、")

- 回收站清空后无法找回，请确认无需恢复。
- 正在被占用的文件会自动跳过，不会中断清理。

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
            Append-WinUtilDiskLog -Message "正在清理 $($def.Name) ……"
            try {
                $freed = Clear-WinUtilDiskJunkDef -Def $def
                $grand += $freed
                Invoke-WPFUIThread -Parameters @{ Id = $def.Id } -ScriptBlock {
                    param($Id)
                    $label = $sync["WPFDiskSize$Id"]
                    if ($null -ne $label) { $label.Text = "已清理" }
                }
                Append-WinUtilDiskLog -Message "$($def.Name)：释放 $(Format-WinUtilJunkSize $freed)"
            } catch {
                Append-WinUtilDiskLog -Message "$($def.Name)：清理失败 $($_.Exception.Message)" -Level "ERROR"
            }
        }
        Append-WinUtilDiskLog -Message "✅ 清理完成，共释放约 $(Format-WinUtilJunkSize $grand)。"
    }
}
