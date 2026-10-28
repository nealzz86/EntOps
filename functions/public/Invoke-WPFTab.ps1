function Invoke-WPFTab {

    <#

    .SYNOPSIS
        Sets the selected tab to the tab that was clicked

    .PARAMETER ClickedTab
        The name of the tab that was clicked

    .PARAMETER Yield
        Build the tab's content in slices, letting the interface answer between them. For the
        tab opened at startup, where the window is already on screen and filling in gradually
        reads better than holding the thread until it is complete.

    #>

    Param (
        [Parameter(Mandatory,position=0)]
        [string]$ClickedTab,

        [switch]$Yield
    )

    $tabNumber = [int]($ClickedTab -replace "WPFTab","" -replace "BT","") - 1

    Measure-WinUtilStep -Scope "Tab" -Name "$ClickedTab select" -ScriptBlock {
        $filter = Get-WinUtilVariables -Type ToggleButton | Where-Object {$psitem -like "WPFTab*BT"}
        $sync.WPFTabNav.Items[$tabNumber].IsSelected = $true
        ($sync.GetEnumerator()).where{$psitem.Key -in $filter} | ForEach-Object {
            if ($ClickedTab -ne $PSItem.name) {
                $sync[$PSItem.Name].IsChecked = $false
            } else {
                $sync["$ClickedTab"].IsChecked = $true
            }
        }
        # Semantic key, not the localized Header: tab content initialization, background render
        # gating and search filtering all compare this value against English keys, and the CN
        # pack's Chinese headers ("安装", "优化") never matched them.
        $sync.currentTab = switch ($tabNumber) {
            0 { "Install" }
            1 { "Tweaks" }
            2 { "Config" }
            3 { "Updates" }
            4 { "Win11ISO" }
            5 { "AppX" }
            6 { "PrintShare" }
            7 { "EntClean" }
            8 { "Overview" }
            9 { "DiskAna" }
            10 { "NetDiag" }
            default { $sync.WPFTabNav.Items[$tabNumber].Header }
        }

        # Top bar shows where the user is, the way an admin console does
        $pageHeader = switch ($sync.currentTab) {
            "Install"  { @("软件安装", "按分类勾选应用，一键批量安装") }
            "Tweaks"   { @("系统优化", "推荐预设与逐项调优开关") }
            "Config"   { @("功能配置", "系统组件与功能开关") }
            "Updates"  { @("更新管理", "Windows 更新策略与离线更新") }
            "Win11ISO" { @("Win10/11 镜像制作", "官方 ISO 验证、修改与写出") }
            "AppX"     { @("AppX 移除", "选择要移除的预装应用包") }
            "PrintShare" { @("打印共享", "共享打印机连接与信息部排障") }
            "EntClean" { @("安全清理", "360/毒霸/电脑管家残留彻底清理") }
            "Overview" { @("概览", "设备状态与常用入口") }
            "DiskAna"  { @("磁盘分析", "磁盘空间占用下钻与大文件定位") }
            "NetDiag"  { @("网络诊断", "连通性、扫描、测速与抓包分析") }
            default    { @([string]$sync.WPFTabNav.Items[$tabNumber].Header, "") }
        }
        if ($sync.ContainsKey("WPFPageTitle") -and $sync.WPFPageTitle) {
            $sync.WPFPageTitle.Text = $pageHeader[0]
        }
        if ($sync.ContainsKey("WPFPageSubtitle") -and $sync.WPFPageSubtitle) {
            $sync.WPFPageSubtitle.Text = $pageHeader[1]
        }
    }

    Measure-WinUtilStep -Scope "Tab" -Name "$ClickedTab content" -ScriptBlock {
        Initialize-WinUtilTabContent -TabName $sync.currentTab -Yield:$Yield
    }

    Measure-WinUtilStep -Scope "Tab" -Name "$ClickedTab filter reset" -ScriptBlock {
        $searchText = if ($null -ne $sync.SearchBar) { $sync.SearchBar.Text } else { "" }
        if ($sync.currentTab -eq "Install") {
            $selectedCategories = if ($sync.SelectedAppCategories) { $sync.SelectedAppCategories.ToArray() } else { @() }
            Find-AppsByNameOrDescription -SearchString $searchText -Categories $selectedCategories
        } elseif ($sync.currentTab -eq "Tweaks" -or $sync.currentTab -eq "AppX") {
            Find-TweaksByNameOrDescription -SearchString $searchText
        }
    }

    Measure-WinUtilStep -Scope "Tab" -Name "$ClickedTab search bar" -ScriptBlock {
        # Show search bar in Install, Tweaks, and AppX tabs
        $searchIcon = ($sync.Form.FindName("SearchBar").Parent.Children | Where-Object { $_ -is [System.Windows.Controls.TextBlock] -and $_.Text -eq [char]0xE721 })[0]
        if ($tabNumber -eq 0 -or $tabNumber -eq 1 -or $tabNumber -eq 5) {
            $sync.SearchBar.Visibility = "Visible"
            if ($searchIcon) { $searchIcon.Visibility = "Visible" }
        } else {
            $sync.SearchBar.Visibility = "Collapsed"
            if ($searchIcon) { $searchIcon.Visibility = "Collapsed" }
            $sync.SearchBarClearButton.Visibility = "Collapsed"
        }
    }
}
