function Invoke-WPFBaselineCheck {

    <#

    .SYNOPSIS
        Runs the machine against the site baseline and fills in the checklist page

    .DESCRIPTION
        The reading happens in a job: a share that no longer answers can hold a path check for
        tens of seconds, and the interface cannot be the thing waiting on it. Nothing here changes
        the system - the fixing belongs to the buttons each failing row points at.

    #>

    param([string]$Button)

    $config = $sync.configs.baseline
    if ($null -eq $config -or -not $config.checks) {
        Show-WinUtilBaselineResults -Rows @() -EmptyText "未找到体检配置：程序目录缺少 config\baseline.json 或其 checks 列表为空。"
        return
    }

    if ($sync.WPFBaselineUpdated) { $sync.WPFBaselineUpdated.Text = "体检中……" }

    Start-WinUtilJob -Name "Baseline" -Description "正在核对装机基线" -ScriptBlock {
        try {
            $facts = Get-WinUtilBaselineFacts
            $result = Get-WinUtilBaselineResult -Config $sync.configs.baseline -Facts $facts

            if ($result.Problem) {
                Show-WinUtilBaselineResults -Rows @() -EmptyText "体检未完成 —— $($result.Problem)"
                return
            }

            Show-WinUtilBaselineResults -Rows $result.Rows
            Invoke-WPFUIThread -Parameters @{ Result = $result } -ScriptBlock {
                param($Result)
                $sync.WPFBaselineVerdict.Text = $Result.Verdict
                $sync.WPFBaselinePass.Text = [string]$Result.Summary.Pass
                $sync.WPFBaselineWarn.Text = [string]$Result.Summary.Warn
                $sync.WPFBaselineFail.Text = [string]$Result.Summary.Fail
                $sync.WPFBaselineUpdated.Text = "体检完成　$((Get-Date).ToString('HH:mm:ss'))　共 $($Result.Summary.Total) 项"
            }
        } catch {
            $failure = $_.Exception.Message
            Write-WinUtilLog -Level "WARN" -Component "Baseline" -Message "Baseline check failed: $failure"
            Show-WinUtilBaselineResults -Rows @() -EmptyText "体检失败：$failure"
            Invoke-WPFUIThread -ScriptBlock {
                if ($sync.WPFBaselineUpdated) { $sync.WPFBaselineUpdated.Text = "体检失败" }
            }
        }
    }
}
