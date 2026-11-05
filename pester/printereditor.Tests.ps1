#===========================================================================
# Tests - 打印机与共享文件夹的自定义配置（动态列表 + 界面内编辑器）
#===========================================================================

<#
    Both lists used to be written into the markup: two printers, three shares, and a site with
    three printers had to be given a rebuilt program. They are generated from the configuration now,
    and the configuration is edited on the machine itself. That moves the risk from "the markup is
    too small" to "the code that generates and reads the controls disagrees", so most of what
    follows is the two sides being held against each other. The millimetre conversion is the one
    piece a user types by hand, so it is tested as the pure function it is.
#>

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
    $script:xamlSource = Get-Content -LiteralPath (Join-Path $repoRoot "xaml\inputXML.xaml") -Raw -Encoding UTF8
    $script:panelSource = Get-Content -LiteralPath (Join-Path $repoRoot "functions\private\EntPrinterPanel.ps1") -Raw -Encoding UTF8
    $script:editorSource = Get-Content -LiteralPath (Join-Path $repoRoot "functions\private\EntPrinterEditor.ps1") -Raw -Encoding UTF8
    $script:initSource = Get-Content -LiteralPath (Join-Path $repoRoot "functions\private\Initialize-WinUtilEntPrinterPanel.ps1") -Raw -Encoding UTF8
    $script:tabContentSource = Get-Content -LiteralPath (Join-Path $repoRoot "functions\private\Initialize-WinUtilTabContent.ps1") -Raw -Encoding UTF8
    $script:handlerSource = Get-Content -LiteralPath (Join-Path $repoRoot "functions\public\Invoke-WPFPrinterInstall.ps1") -Raw -Encoding UTF8
    $script:editorHandlerSource = Get-Content -LiteralPath (Join-Path $repoRoot "functions\public\Invoke-WPFEntPrinterEditor.ps1") -Raw -Encoding UTF8

    $script:routes = Get-Content -LiteralPath (Join-Path $repoRoot "config\routes.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    $script:commands = @((Get-Content -LiteralPath (Join-Path $repoRoot "config\commands.json") -Raw -Encoding UTF8 | ConvertFrom-Json).commands)

    . (Join-Path $repoRoot "functions\private\EntPrinterEditor.ps1")
}

Describe "选择列表按配置条数生成" {
    It "接口标记里不再有写死的打印机与共享槽位" {
        # -Match, not -Contain: Pester enumerates the haystack, and a string is one item, so a
        # -Not -Contain over source text passes without looking at anything.
        foreach ($name in @("WPFPrinterSel1", "WPFPrinterSel2", "WPFPrinterShare1", "WPFPrinterShare2", "WPFPrinterShare3")) {
            $script:xamlSource | Should -Not -Match ([regex]::Escape("Name=""$name""")) -Because "$name 是固定槽位，数量应由配置决定"
        }

        $script:xamlSource | Should -Match ([regex]::Escape('Name="WPFPrinterSelPanel"'))
        $script:xamlSource | Should -Match ([regex]::Escape('Name="WPFShareSelPanel"'))
    }

    It "读取选择的只有生成控件的那份代码" {
        # A handler that still reaches for $sync.WPFPrinterSel2 would read a control that no longer
        # exists and install the first printer whatever the operator ticked.
        $script:handlerSource | Should -Not -Match 'WPFPrinterSel\d'
        $script:handlerSource | Should -Not -Match 'WPFPrinterShare\d'
        $script:handlerSource | Should -Match 'Get-WinUtilSelectedPrinterIndex'
        $script:handlerSource | Should -Match 'Get-WinUtilSelectedShareIndices'
    }

    It "没有任何选择时停下来，而不是默认装第一台" {
        # $sync.WPFPrinterSel1 style defaults would install a machine nobody picked
        $script:handlerSource | Should -Match '没有选中的打印机'
        # -1 is the "nothing chosen" answer, and it must not be silently turned into index 0
        $script:panelSource | Should -Match 'return -1'
    }

    It "每个控件记住自己来自配置的第几条" {
        # Rebuilding skips a blank row, so the position in the panel is not the config index; only
        # the index stamped onto the control keeps a share mapped to the right drive letter.
        $script:panelSource | Should -Match '\$radio\.Tag = \$index'
        $script:panelSource | Should -Match '\$box\.Tag = \$index'
        $script:panelSource | Should -Match '\[int\]\$radio\.Tag'
        $script:panelSource | Should -Match '\[int\]\$box\.Tag'
    }

    It "操作页只填选择列表，编辑器由设置页自己加载" {
        # 两页共用同一份配置，但各填各的控件：操作页重绘勾选列表，设置页重绘编辑行。
        # 谁多调了一次，另一页的控件在还没被构建时就会读到 null。
        $script:initSource | Should -Match 'Update-WinUtilEntPrinterSelection'
        $script:initSource | Should -Not -Match 'Show-WinUtilEntPrinterEditor'
        $script:editorSource | Should -Match 'function Initialize-WinUtilEntPrinterSettings'
        $script:tabContentSource | Should -Match '"PrintShare" \{\s*Initialize-WinUtilEntPrinterPanel\b'
        $script:tabContentSource | Should -Match '"EntPrinterSettings" \{\s*Initialize-WinUtilEntPrinterSettings\b'
    }
}

Describe "配置编辑器" {
    It "四个按钮都有路由，且都不占用任务槽" {
        foreach ($entry in @(@{ Button = "WPFEntCfgAddPrinter"; Function = "Invoke-WPFEntPrinterConfigAddPrinter" },
                            @{ Button = "WPFEntCfgAddShare"; Function = "Invoke-WPFEntPrinterConfigAddShare" },
                            @{ Button = "WPFEntCfgSave"; Function = "Invoke-WPFEntPrinterConfigSave" },
                            @{ Button = "WPFEntCfgReset"; Function = "Invoke-WPFEntPrinterConfigReset" })) {
            $route = $script:routes.PSObject.Properties[$entry.Button].Value
            $route | Should -Not -BeNullOrEmpty -Because "$($entry.Button) 需要在 routes.json 里声明"
            $route.function | Should -Be $entry.Function
            # 任务槽只有一个：编辑器按钮若被包进任务，点保存会撞上正在跑的安装任务
            $route.work | Should -BeNullOrEmpty

            $script:editorHandlerSource | Should -Match "function $($entry.Function)"
        }
    }

    It "命令面板能搜到编辑器，且指向设置页" {
        $buttons = @($script:commands | ForEach-Object { $_.button })
        foreach ($button in @("WPFEntCfgAddPrinter", "WPFEntCfgAddShare", "WPFEntCfgSave", "WPFEntCfgReset")) {
            $buttons | Should -Contain $button
            $command = @($script:commands | Where-Object { $_.button -eq $button })[0]
            # 按钮搬去哪个页面，面板就得先跳哪个页面：指向操作页的话搜到也按不着
            $command.tab | Should -Be "WPFTab13BT"
            $command.group | Should -Be "打印与共享设置"
        }
    }

    It "编辑控件只在设置页，操作页上一个都不留" {
        [xml] $doc = $script:xamlSource
        $settings = $doc.SelectSingleNode('//*[local-name()="TabItem"][@Name="WPFTab13"]')
        $operation = $doc.SelectSingleNode('//*[local-name()="TabItem"][@Name="WPFTab7"]')
        $settings | Should -Not -BeNullOrEmpty -Because "「打印与共享设置」是编辑器唯一的位置"
        $operation | Should -Not -BeNullOrEmpty
        foreach ($name in @("WPFEntCfgPrinterRows", "WPFEntCfgShareRows", "WPFEntCfgFormName", "WPFEntCfgSave", "WPFEntCfgReset")) {
            # ".//" rather than "//": the search has to start at this tab, otherwise every tab
            # reports the whole window and both sides of the assertion match the same node.
            $xpath = './/*[@Name="' + $name + '"]'
            $settings.SelectSingleNode($xpath) | Should -Not -BeNullOrEmpty -Because "$name 应在设置页"
            $operation.SelectSingleNode($xpath) | Should -BeNullOrEmpty -Because "$name 已从操作页搬走"
        }
    }

    It "侧栏把设置页排在「打印共享」正下方" {
        # 分开的两页要能一眼找到彼此：排在最后一个页面后面，谁都不会想到配置在那里
        [xml] $doc = $script:xamlSource
        $navNames = @($doc.SelectNodes('//*[local-name()="StackPanel"][@Name="NavDockPanel"]/*[local-name()="ToggleButton"]') |
            ForEach-Object { $_.GetAttribute("Name") })
        $navNames | Should -Contain "WPFTab13BT"
        $index = [array]::IndexOf($navNames, "WPFTab7BT")
        $index | Should -BeGreaterThan -1
        $navNames[$index + 1] | Should -Be "WPFTab13BT"
    }

    It "设置页保存后两页一起刷新" {
        # 只重画编辑器的话，操作页的勾选列表还留着刚被删掉的那台打印机，下一次安装就按一个不存在的名字
        $script:editorSource | Should -Match 'function Update-WinUtilEntPrinterUiFromConfig'
        $update = (@($script:editorSource -split "function Update-WinUtilEntPrinterUiFromConfig")[1] -split '\nfunction ')[0]
        $update | Should -Match 'Initialize-WinUtilEntPrinterPanel'
        $update | Should -Match 'Initialize-WinUtilEntPrinterSettings'
        foreach ($handler in @("Invoke-WPFEntPrinterConfigSave", "Invoke-WPFEntPrinterConfigReset")) {
            $body = (@($script:editorHandlerSource -split "function $handler")[1] -split '\nfunction ')[0]
            $body | Should -Match 'Update-WinUtilEntPrinterUiFromConfig'
        }
    }

    It "只往本机配置目录写，绝不碰仓库里的配置" {
        foreach ($source in @($script:editorSource, $script:editorHandlerSource)) {
            $source | Should -Not -Match 'entprinters\.json'
            $source | Should -Not -Match 'config\\'
            $source | Should -Not -Match 'Set-Content|Out-File|Add-Content'
        }
        # 唯一的写入口，路径来自那个把文件放在用户配置目录里的函数
        $script:editorHandlerSource | Should -Match 'Write-WinUtilEntPrinterConfig'
        $script:editorHandlerSource | Should -Match 'Remove-WinUtilEntPrinterConfig'
    }

    It "校验不通过时先说清楚，界面不重建" {
        $save = (@($script:editorHandlerSource -split "function Invoke-WPFEntPrinterConfigSave")[1] -split "function Invoke-WPFEntPrinterConfigReset")[0]
        # 失败分支只报告问题就返回：重建会把刚敲到一半的内容抹掉，那比保存失败更让人恼火
        $failBranch = $save.Substring(0, $save.IndexOf("Update-WinUtilEntPrinterUiFromConfig"))
        $failBranch | Should -Match 'if \(\$problems\.Count -gt 0\)'
        $failBranch | Should -Match 'Set-WinUtilEntPrinterEditorStatus -Problems'
        $failBranch | Should -Match 'return'
    }

    It "删除按钮带着自己要删的那一行" {
        # Rows shift as soon as one is removed, so a handler that counted positions would delete the
        # neighbour of the row the operator pointed at.
        $script:editorSource | Should -Match '\$state\.List\.Remove\(\$state\.Record\)'
        $script:editorSource | Should -Not -Match 'Children\.RemoveAt'
    }

    It "删除按钮不吃主题的固定尺寸" {
        # 主题的按钮样式把所有按钮钉成 200x25：放进 56 像素的列里，文字被裁走，看上去就是一个空白框
        $remove = (@($script:editorSource -split "function New-WinUtilEntEditorRemoveButton")[1] -split '\nfunction ')[0]
        $remove | Should -Match '\$button\.Width = \[double\]::NaN'
        $remove | Should -Match '\$button\.Height = \[double\]::NaN'
        $remove | Should -Match '\$button\.MinHeight'
    }

    It "共享密码用密码框，不用明文文本框" {
        $script:editorSource | Should -Match 'System\.Windows\.Controls\.PasswordBox'
        $script:editorSource | Should -Match '\$row\.Pass\.Password'
    }

    It "两页标记里都没有内网机器名与凭据" {
        # 这两页的文案是给任何单位用的，具体站点由各自的配置文件提供。出厂默认 IP（芯烨/爱普生）是打印机
        # 本身的属性，不是现场信息，所以留在界面上。
        [xml] $doc = $script:xamlSource
        foreach ($tabName in @("WPFTab7", "WPFTab13")) {
            $tab = $doc.SelectSingleNode('//*[local-name()="TabItem"][@Name="' + $tabName + '"]')
            $tab | Should -Not -BeNullOrEmpty
            $tab.OuterXml | Should -Not -Match '\\\\[a-zA-Z0-9_.-]+\\' -Because "$tabName 不应写死 \\\\服务器\共享"
        }
    }
}

Describe "毫米与 0.1 毫米互换" {
    It "配置里的 0.1 毫米显示成毫米" {
        ConvertTo-WinUtilEntMillimetre -Tenths 1400 | Should -Be "140"
        ConvertTo-WinUtilEntMillimetre -Tenths 2159 | Should -Be "215.9"
        ConvertTo-WinUtilEntMillimetre -Tenths 100 | Should -Be "10"
    }

    It "读不懂的值显示成空白，而不是 0" {
        # 0 会让人以为纸张真是 0 毫米，而实际情况是这个字段是坏的
        ConvertTo-WinUtilEntMillimetre -Tenths "abc" | Should -Be ""
        ConvertTo-WinUtilEntMillimetre -Tenths $null | Should -Be ""
    }

    It "输入的毫米换算回 0.1 毫米" {
        ConvertFrom-WinUtilEntMillimetre -Text "140" | Should -Be 1400
        ConvertFrom-WinUtilEntMillimetre -Text "215.9" | Should -Be 2159
        ConvertFrom-WinUtilEntMillimetre -Text " 80.4 " | Should -Be 804
    }

    It "非数字原样交回给校验" {
        # 在这里变成 0 的话，报出来的就是「宽度只能是 10～3276.7 毫米」，而真正的问题是填错了字
        ConvertFrom-WinUtilEntMillimetre -Text "140mm" | Should -Be "140mm"
        ConvertFrom-WinUtilEntMillimetre -Text "" | Should -Be ""
    }

    It "来回换算不丢精度" {
        foreach ($tenths in @(100, 1400, 2159, 32767)) {
            $mm = ConvertTo-WinUtilEntMillimetre -Tenths $tenths
            ConvertFrom-WinUtilEntMillimetre -Text $mm | Should -Be $tenths
        }
    }
}
