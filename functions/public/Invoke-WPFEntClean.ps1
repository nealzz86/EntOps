function Invoke-WPFEntCleanDetect {

    <#

    .SYNOPSIS
        Scans the machine for the three consumer security suites and shows the result

    #>
    param([string]$Button)

    $statusMap = @{ "360" = "WPFEntCleanStatus1"; "kingsoft" = "WPFEntCleanStatus2"; "tencent" = "WPFEntCleanStatus3" }
    $results = @(Get-WinUtilEntAVInstall)

    foreach ($r in $results) {
        if ($r.Found) {
            Write-Host "  [检测] $($r.Name)：已发现 → $($r.Evidence -join '；')" -ForegroundColor Yellow
        } else {
            Write-Host "  [检测] $($r.Name)：未发现" -ForegroundColor Green
        }
        $name = $statusMap[$r.Key]
        if ($name -and $sync.$name) {
            $sync.$name.Text = if ($r.Found) { "已检测到（$($r.Evidence.Count) 处痕迹）" } else { "未检测到" }
            $sync.$name.Foreground = if ($r.Found) { [System.Windows.Media.Brushes]::OrangeRed } else { [System.Windows.Media.Brushes]::Green }
        }
    }
}

function Invoke-WPFEntCleanRun {

    <#

    .SYNOPSIS
        Confirms the selection on the UI thread and starts the security-suite cleanup job

    #>
    param([string]$Button)

    $keys = @()
    if ($sync.WPFEntClean360.IsChecked)    { $keys += "360" }
    if ($sync.WPFEntCleanKingsoft.IsChecked) { $keys += "kingsoft" }
    if ($sync.WPFEntCleanTencent.IsChecked)  { $keys += "tencent" }

    if ($keys.Count -eq 0) {
        Write-Host "请至少勾选一个要清理的安全软件。" -ForegroundColor Yellow
        return
    }

    $forceMode = [bool]$sync.WPFEntCleanModeForce.IsChecked
    $products = @($sync.configs.entclean.products | Where-Object { $keys -contains $_.key })
    $names = ($products | ForEach-Object { $_.name }) -join "、"
    $modeText = if ($forceMode) { "强制删除模式（不运行官方卸载程序，直接清除进程/服务/文件/注册表）" } else { "标准模式（先尝试官方卸载程序，再清除残留）" }

    $confirm = Show-WinUtilMessage -Message "即将清理：$names`n`n$modeText`n`n注意：`n- 这会移除系统安全防护，清理后 Windows Defender 将自动接管防护。`n- 建议清理完成后重启计算机。`n- 金山毒霸仅清理杀毒组件，不会删除 WPS 组件；腾讯仅清理电脑管家（QQPCMgr），不影响 QQ/微信。`n- 360 会删除 C:\Program Files (x86)\360 整个目录（含该目录下的 360 系软件）。`n`n确定继续吗？" `
        -Title "安全软件彻底清理" -Button "YesNo" -Icon "Warning"
    if ($confirm -ne "Yes") { return }

    Start-WinUtilJob -Name "安全软件清理" -Parameters @{ Keys = $keys; ForceMode = $forceMode } -ScriptBlock {
        param($Keys, $ForceMode)
        Remove-WinUtilEntAVProducts -Keys $Keys -ForceMode $ForceMode
    }
}
