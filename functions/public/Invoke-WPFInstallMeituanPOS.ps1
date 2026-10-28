function Invoke-WPFInstallMeituanPOS {

    <#

    .SYNOPSIS
        Confirms with the user and starts the Meituan POS install job

    #>
    param([string]$Button)

    $answer = Show-WinUtilMessage -Title "安装美团收银" -Button "YesNo" -Icon "Warning" -Message @"
即将安装美团收银（门店版）。

- 优先使用共享目录中的美团收银安装包；没有安装包时会打开美团收银官网，需联系服务商/信息部获取安装包。
- 安装程序为向导式安装，需要管理员权限。
- 安装完成后需要门店激活码，由信息部或美团服务商协助激活。

确定继续吗？
"@
    if ($answer -ne "Yes") { return }

    Start-WinUtilJob -Name "MeituanPOSInstall" -Description "正在安装美团收银" -ScriptBlock {
        Install-WinUtilMeituanPOS
    }
}
