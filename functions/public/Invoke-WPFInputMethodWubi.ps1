function Invoke-WPFInputMethodWubi {
    <#
    .SYNOPSIS
        Adds the built-in Microsoft Wubi input method for the current user

    .DESCRIPTION
        Windows ships 微软五笔 in-box with the Simplified Chinese edition, so this only registers
        its TIP in the user's language list: no download, works fully offline. Runs inside a job
        started by the feature.json button.
    #>

    # Microsoft Wubi TIP registered under the zh-CN (0804) language
    $wubiTip = "0804:{8213C993-DFC2-44D9-A8D9-0443382B0170}{E6ECEB2F-3D7A-4F20-8550-6D7104F08005}"

    try {
        $list = Get-WinUserLanguageList -ErrorAction Stop
    } catch {
        Show-WinUtilMessage -Title "微软五笔" -Message "读取当前用户的输入法列表失败：$_" -Icon Error | Out-Null
        return
    }

    $zh = $list | Where-Object { $_.LanguageTag -eq "zh-Hans-CN" } | Select-Object -First 1
    if (-not $zh) {
        # English-locale machines: add Simplified Chinese (basic input ships in-box) and put it
        # after the existing languages so the display language does not change
        try {
            $zhList = New-WinUserLanguageList "zh-Hans-CN" -ErrorAction Stop
            $zh = $zhList[0]
            $list.Add($zh) | Out-Null
        } catch {
            Show-WinUtilMessage -Title "微软五笔" -Message "为当前用户添加简体中文输入法失败：$_" -Icon Error | Out-Null
            return
        }
    }

    if ($zh.InputMethodTips -contains $wubiTip) {
        Show-WinUtilMessage -Title "微软五笔" -Message "微软五笔输入法已经在列表中，无需重复添加。`n`n点击任务栏的输入法图标即可切换到微软五笔。" | Out-Null
        return
    }

    try {
        $zh.InputMethodTips.Add($wubiTip)
        Set-WinUserLanguageList $list -Force -ErrorAction Stop
        Show-WinUtilMessage -Title "微软五笔" -Message "已添加微软五笔输入法。`n`n点击任务栏输入法图标，或在「设置 > 时间和语言 > 语言和区域」中切换到微软五笔即可使用。" | Out-Null
    } catch {
        Show-WinUtilMessage -Title "微软五笔" -Message "添加微软五笔失败：$_" -Icon Error | Out-Null
    }
}
