function Invoke-WPFInstallSunlogin {

    <#

    .SYNOPSIS
        Confirms with the user and starts the Sunlogin enterprise client install job

    #>
    param([string]$Button)

    $answer = Show-WinUtilMessage -Title "安装向日葵企业版" -Button "YesNo" -Icon "Warning" -Message @"
即将安装向日葵远程控制·企业版（SOS 被控端，v1.2.1.61234）。

- 优先使用共享目录根目录中的安装包；没有安装包时需要电脑能访问外网，从贝锐官方服务器下载。
- 安装程序为向导式安装，需要管理员权限，请按提示完成。
- 安装完成后需生成识别码或绑定葵码，由信息部在向日葵管理平台确认后才能被远程控制。

确定继续吗？
"@
    if ($answer -ne "Yes") { return }

    Start-WinUtilJob -Name "SunloginInstall" -Description "正在安装向日葵企业版" -ScriptBlock {
        Install-WinUtilSunloginEnterprise
    }
}
