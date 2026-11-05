#===========================================================================
# Tests - XAML Control Wiring

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
    $script:configRoot = Join-Path $script:repoRoot "config"
    $script:functionRoot = Join-Path $script:repoRoot "functions"
    $script:scriptsRoot = Join-Path $script:repoRoot "scripts"
    $script:xamlPath = Join-Path $script:repoRoot "xaml\inputXML.xaml"
    $script:uiScriptPath = Join-Path $script:functionRoot "private\Start-WinUtilUserInterface.ps1"
    $script:buttonScriptPath = Join-Path $script:functionRoot "public\Invoke-WPFButton.ps1"
    $script:xamlText = Get-Content -Path $script:xamlPath -Raw
    $script:xaml = [xml]$script:xamlText
    $script:xamlNamespace = New-Object System.Xml.XmlNamespaceManager -ArgumentList $script:xaml.NameTable
    $script:xamlNamespace.AddNamespace("x", "http://schemas.microsoft.com/winfx/2006/xaml")

    function script:Get-WinUtilConfigObject {
        param([string]$Name)

        Get-Content -Path (Join-Path $script:configRoot "$Name.json") -Raw | ConvertFrom-Json
    }

    function script:Get-WinUtilSourceText {
        Get-ChildItem -Path @($script:functionRoot, $script:scriptsRoot) -Filter *.ps1 -Recurse |
            ForEach-Object { Get-Content -Path $_.FullName -Raw } |
            Out-String
    }

    function script:Get-WinUtilTopLevelFunctionNames {
        Get-ChildItem -Path $script:functionRoot -Filter *.ps1 -Recurse | ForEach-Object {
            $tokens = $null
            $syntaxErrors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$syntaxErrors)
            if ($syntaxErrors.Count -ne 0) {
                throw ($syntaxErrors | Out-String)
            }

            $ast.EndBlock.Statements |
                Where-Object { $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] } |
                ForEach-Object { $_.Name }
        } | Sort-Object -Unique
    }

    function script:Get-WinUtilXamlNamedControls {
        $nodes = $script:xaml.SelectNodes("//*[@Name or @x:Name]", $script:xamlNamespace)
        foreach ($node in $nodes) {
            $controlName = $node.GetAttribute("Name")
            if ([string]::IsNullOrWhiteSpace($controlName)) {
                $controlName = $node.GetAttribute("Name", "http://schemas.microsoft.com/winfx/2006/xaml")
            }

            [pscustomobject]@{
                Name = $controlName
                Type = $node.LocalName
            }
        }
    }

    function script:Get-WinUtilXamlRuntimeNamedControls {
        $nodes = $script:xaml.SelectNodes("//*[@Name]")
        foreach ($node in $nodes) {
            [pscustomobject]@{
                Name = $node.GetAttribute("Name")
                Type = $node.LocalName
            }
        }
    }

    function script:Get-WinUtilGeneratedControlNames {
        $names = New-Object System.Collections.Generic.List[string]
        foreach ($configName in @("appnavigation", "tweaks", "feature", "appx")) {
            $config = Get-WinUtilConfigObject -Name $configName
            foreach ($entry in $config.PSObject.Properties.Name) {
                $names.Add($entry)
            }
        }

        $applications = Get-WinUtilConfigObject -Name "applications"
        foreach ($entry in $applications.PSObject.Properties.Name) {
            $names.Add($entry)
            $names.Add(($entry -replace "-", "_"))
        }

        $names | Sort-Object -Unique
    }

    # Branch labels of the Switch -Wildcard dispatch in Invoke-WPFButton.ps1. A label may carry
    # wildcards ("WPFTab??BT", "WPFFNetTool*"), so literal names and patterns are split apart:
    # a button is routed when a literal branch names it or a wildcard branch matches it.
    function script:Get-WinUtilButtonSwitchBranchLabels {
        $buttonSource = Get-Content -Path $script:buttonScriptPath -Raw
        $switchIndex = $buttonSource.IndexOf("Switch -Wildcard")
        if ($switchIndex -lt 0) {
            throw "Invoke-WPFButton.ps1 no longer routes buttons through a Switch -Wildcard block"
        }

        [regex]::Matches($buttonSource.Substring($switchIndex), '"(WPF[A-Za-z0-9_*?]*)"\s*\{') |
            ForEach-Object { $_.Groups[1].Value } |
            Sort-Object -Unique
    }

    function script:Get-WinUtilButtonSwitchNames {
        @(Get-WinUtilButtonSwitchBranchLabels | Where-Object { $_ -notmatch '[*?]' })
    }

    function script:Get-WinUtilButtonSwitchPatterns {
        @(Get-WinUtilButtonSwitchBranchLabels | Where-Object { $_ -match '[*?]' })
    }

    # Most buttons no longer have a branch of their own: config\routes.json says what they call.
    function script:Get-WinUtilButtonRouteNames {
        $routes = Get-WinUtilConfigObject -Name "routes"
        @($routes.PSObject.Properties.Name)
    }

    function script:Test-WinUtilNameInSet {
        param(
            [Parameter(Mandatory)]
            [string]$Name,

            [Parameter(Mandatory)]
            [string[]]$Set
        )

        foreach ($item in $Set) {
            if ($item -ieq $Name) {
                return $true
            }
        }

        return $false
    }
}

Describe "Interface startup failures" {
    BeforeAll {
        function Measure-WinUtilStep { param($Scope, $Name, $ScriptBlock) $null = $Scope, $Name; & $ScriptBlock }
        function Write-WinUtilLog { param($Level, $Component, $Message) $null = $Level, $Component, $Message }
    }

    BeforeEach {
        . $script:uiScriptPath
        # The startup path decides the render mode before it parses any XAML, so the file that
        # defines it has to be loaded here or the function-not-found error hides the real one.
        . (Join-Path $script:functionRoot "private\Set-WinUtilRenderMode.ps1")
        $script:sync = [Hashtable]::Synchronized(@{
            StepTimings = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())
            preferences = @{ theme = "Auto" }
        })
        $script:inputXML = '<NotAWindow xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" />'

        Mock Measure-WinUtilStep { & $ScriptBlock }
        Mock Write-WinUtilLog { }
        Mock Write-Host { }
    }

    It "throws when the XAML cannot create the window" {
        { Start-WinUtilUserInterface } | Should -Throw "Failed to parse the XAML content*"

        Should -Invoke Write-WinUtilLog -Times 1 -Exactly -ParameterFilter {
            $Level -eq "ERROR" -and $Component -eq "UI"
        }
    }

    It "exits a direct file process but returns to an in-memory caller after an interface failure" {
        $mainScript = Get-Content -Path (Join-Path $script:scriptsRoot "main.ps1") -Raw

        $mainScript | Should -Match '\$uiFailed = \$true[\s\S]*if \(\$uiFailed\) \{\s*\$global:LASTEXITCODE = 1\s*if \(\$script:WinUtilIsFileProcess\) \{ exit 1 \}\s*return 1'
    }
}

Describe "XAML document" {
    It "loads inputXML.xaml as a WPF window XML document" {
        $script:xaml.DocumentElement.LocalName | Should -Be "Window"
    }

    It "contains expected core controls" {
        $xamlNames = @(Get-WinUtilXamlRuntimeNamedControls | ForEach-Object { $_.Name })
        $requiredControls = @(
            "WPFMainGrid",
            "NavDockPanel",
            "GridBesideNavDockPanel",
            "WPFTabNav",
            "WPFTab1",
            "WPFTab2",
            "WPFTab3",
            "WPFTab4",
            "WPFTab5",
            "WPFTab6",
            "WPFTab1BT",
            "WPFTab2BT",
            "WPFTab3BT",
            "WPFTab4BT",
            "WPFTab5BT",
            "SearchBar",
            "SearchBarIcon",
            "SearchBarClearButton",
            "WPFSearchChips",
            # The category chips the fork ships: every one of these is wired from
            # $sync.AppCategoryChips in Start-WinUtilUserInterface.ps1, so a rename breaks filtering
            "WPFSearchChipAll",
            "WPFSearchChipComms",
            "WPFSearchChipOffice",
            "WPFSearchChipUtilities",
            "WPFSearchChipInput",
            "WPFSearchChipNetwork",
            "WPFSearchChipMedia",
            "WPFSearchChipRemote",
            "WPFSearchChipDev",
            "WPFSearchChipPos",
            "appscategory",
            "appspanel",
            "tweakspanel",
            "featurespanel",
            "appxpanel",
            "WPFstandard",
            "WPFminimal",
            "WPFAdvanced",
            "WPFClearTweaksSelection",
            "WPFGetInstalledTweaks",
            "WPFAppxRemoval",
            "WPFTweaksbutton",
            "WPFUndoall",
            "WPFUpdatesdefault",
            "WPFUpdatessecurity",
            "WPFUpdatesdisable",
            "WPFDefaultAppxSelection",
            "WPFGetInstalledAppx",
            "WPFSelectAllAppx",
            "WPFClearAppxSelection",
            "WPFBackToTweaks",
            "WPFInstallSelectedAppx",
            "WPFRemoveSelectedAppx"
        )

        $missingControls = @($requiredControls | Where-Object { -not (Test-WinUtilNameInSet -Name $_ -Set $xamlNames) })
        if ($missingControls.Count -gt 0) {
            throw ($missingControls -join "`n")
        }
    }



    It "presents the three Updates profiles with accurate action labels" {
        $updatesTab = $script:xaml.SelectSingleNode('//*[local-name()="TabItem"][@Name="WPFTab4"]')
        $profileGrid = $updatesTab.SelectSingleNode('.//*[local-name()="UniformGrid"]')
        $expectedButtons = @{
            WPFUpdatessecurity = "应用推荐设置"
            WPFUpdatesdefault = "恢复默认设置"
            WPFUpdatesdisable = "禁用更新"
        }

        $profileGrid.GetAttribute("Columns") | Should -Be "3"
        foreach ($buttonName in $expectedButtons.Keys) {
            $button = $updatesTab.SelectSingleNode(".//*[local-name()='Button'][@Name='$buttonName']")
            $button.GetAttribute("Content") | Should -Be $expectedButtons[$buttonName]
        }
        $updatesTab.SelectSingleNode('.//*[@Name="updatespanel"]') | Should -BeNullOrEmpty
    }

    It "contains Win11 Creator controls used by the ISO workflow" {
        $xamlNames = @(Get-WinUtilXamlRuntimeNamedControls | ForEach-Object { $_.Name })
        $requiredControls = @(
            "Win11ISOPanel",
            "WPFWin11ISOSelectSection",
            "WPFWin11ISOPath",
            "WPFWin11ISOBrowseButton",
            "WPFWin11ISOFileInfo",
            "WPFWin11ISODownloadLink",
            "WPFWin11ISOSteps",
            "WPFWin11ISOBackButton",
            "WPFWin11ISOForwardButton",
            "WPFWin11ISOWorkingSection",
            "WPFWin11ISOWorkingLabel",
            "WPFWin11ISOWorkingSpinner",
            "WPFWin11ISODonePanel",
            "WPFWin11ISODoneLabel",
            "WPFWin11ISOMountButton",
            "WPFWin11ISOInjectDrivers",
            "WPFWin11ISOVerifyResultPanel",
            "WPFWin11ISOMountDriveLetter",
            "WPFWin11ISOImageFile",
            "WPFWin11ISOEditionComboBox",
            "WPFWin11ISOModifySection",
            "WPFWin11ISOModifyButton",
            "WPFWin11ISOOutputSection",
            "WPFWin11ISOCleanResetButton",
            "WPFWin11ISOChooseISOButton",
            "WPFWin11ISOChooseUSBButton",
            "WPFWin11ISOOptionUSB",
            "WPFWin11ISOUSBDriveComboBox",
            "WPFWin11ISORefreshUSBButton",
            "WPFWin11ISOWriteUSBButton",
            "WPFWin11ISOStatusLog"
        )

        $missingControls = @($requiredControls | Where-Object { -not (Test-WinUtilNameInSet -Name $_ -Set $xamlNames) })
        if ($missingControls.Count -gt 0) {
            throw ($missingControls -join "`n")
        }
    }

    It "names the Win11 Creator wizard controls for screen readers" {
        $expectedNames = @{
            WPFWin11ISOBackButton = "Previous Step"
            WPFWin11ISOForwardButton = "Next Step"
            WPFWin11ISOPath = "ISO file"
            WPFWin11ISOEditionComboBox = "Windows edition"
            WPFWin11ISOUSBDriveComboBox = "USB drive"
            WPFWin11ISOStatusLog = "Status Log"
        }

        foreach ($controlName in $expectedNames.Keys) {
            $control = $script:xaml.SelectSingleNode("//*[@Name='$controlName']")
            $control.GetAttribute("AutomationProperties.Name") | Should -Be $expectedNames[$controlName]
        }
    }

    It "defines core tabs in the expected order" {
        $tabItems = @($script:xaml.SelectNodes('//*[local-name()="TabControl"][@Name="WPFTabNav"]/*[local-name()="TabItem"]'))
        $actualTabs = @($tabItems | ForEach-Object { "$($_.GetAttribute("Name")):$($_.GetAttribute("Header"))" })
        $expectedTabs = @(
            "WPFTab1:安装",
            "WPFTab2:优化",
            "WPFTab3:配置",
            "WPFTab4:更新",
            "WPFTab5:Win11ISO（镜像制作）",
            "WPFTab6:AppX",
            "WPFTab7:打印共享",
            "WPFTab8:安全清理",
            "WPFTab9:概览",
            "WPFTab10:磁盘分析",
            "WPFTab11:网络诊断",
            "WPFTab12:装机体检",
            "WPFTab13:打印与共享设置"
        )

        if (@($actualTabs).Count -ne $expectedTabs.Count) {
            throw "Expected $($expectedTabs.Count) tabs but found $(@($actualTabs).Count): $($actualTabs -join ', ')"
        }

        for ($index = 0; $index -lt $expectedTabs.Count; $index++) {
            if ($actualTabs[$index] -ne $expectedTabs[$index]) {
                throw "Tab order mismatch at index ${index}: expected $($expectedTabs[$index]), found $($actualTabs[$index])"
            }
        }
    }



    It "gives every fixed-size UniformGrid enough cells for its children" {
        # A UniformGrid with both Rows and Columns written out overflows silently: children past
        # Rows*Columns get drawn outside the panel, so the card border stops early and the page's
        # ScrollViewer never learns the content grew taller. That is how the overview's last two
        # quick-action tiles ended up cut in half with no way to scroll to them.
        $overflowing = [System.Collections.Generic.List[string]]::new()
        foreach ($grid in $script:xaml.SelectNodes('//*[local-name()="UniformGrid"]')) {
            $rows = $grid.GetAttribute("Rows")
            $columns = $grid.GetAttribute("Columns")
            if (-not $rows -or -not $columns) { continue }   # one side auto-calculates: cannot overflow

            $count = 0
            foreach ($child in $grid.ChildNodes) { if ($child.NodeType -eq "Element") { $count++ } }
            if ($count -gt ([int]$rows * [int]$columns)) {
                $overflowing.Add("UniformGrid Rows=$rows Columns=$columns holds $count children")
            }
        }

        $overflowing.Count | Should -Be 0 -Because ($overflowing -join "; ")
    }

    It "centers top bar controls vertically" {
        # NavDockPanel is no longer part of the top bar: the console redesign moved it into the
        # sidebar as a vertical nav rail. The top bar row now holds the page title, the search bar
        # and the window action buttons, so those are the groups that must centre themselves.
        $pageTitle = $script:xaml.SelectSingleNode('//*[local-name()="TextBlock"][@Name="WPFPageTitle"]')
        $titlePanel = $pageTitle.ParentNode
        $searchBox = $script:xaml.SelectSingleNode('//*[local-name()="TextBox"][@Name="SearchBar"]')
        $searchBorder = $searchBox.ParentNode.ParentNode
        $minimizeButton = $script:xaml.SelectSingleNode('//*[local-name()="Button"][@Name="WPFMinimizeButton"]')
        $actionPanel = $minimizeButton.ParentNode
        $topBarButtonNames = @(
            "ThemeButton",
            "FontScalingButton",
            "SettingsButton",
            "WPFMinimizeButton",
            "WPFMaximizeButton",
            "WPFCloseButton"
        )

        $titlePanel.LocalName | Should -Be "StackPanel"
        $searchBorder.LocalName | Should -Be "Border"
        $actionPanel.LocalName | Should -Be "StackPanel"

        # Pin what these groups are before pinning where they sit: the action row lays its six
        # buttons out side by side and the title block stacks, and neither reads correctly unless
        # the group itself is centred inside the bar
        $titlePanel.GetAttribute("Orientation") | Should -Be "Vertical"
        $actionPanel.GetAttribute("Orientation") | Should -Be "Horizontal"

        $titlePanel.GetAttribute("VerticalAlignment") | Should -Be "Center"
        $searchBorder.GetAttribute("VerticalAlignment") | Should -Be "Center"
        $actionPanel.GetAttribute("VerticalAlignment") | Should -Be "Center"

        foreach ($buttonName in $topBarButtonNames) {
            $button = $script:xaml.SelectSingleNode("//*[local-name()='Button'][@Name='$buttonName']")
            $button.GetAttribute("VerticalAlignment") | Should -Be "Center"
        }
    }





    It "scopes toggle button styles without leaking into combo boxes" {
        $resources = $script:xaml.SelectSingleNode('//*[local-name()="Window.Resources"]')
        $implicitToggleStyles = @($resources.SelectNodes('./*[local-name()="Style"][@TargetType="ToggleButton" or @TargetType="{x:Type ToggleButton}"][not(@x:Key)]', $script:xamlNamespace))
        $tabStyle = $resources.SelectSingleNode('./*[local-name()="Style"][@x:Key="TabToggleButton"]', $script:xamlNamespace)
        $navToggleStyle = $resources.SelectSingleNode('./*[local-name()="Style"][@x:Key="NavItemToggleStyle"]', $script:xamlNamespace)
        $chipToggleStyle = $resources.SelectSingleNode('./*[local-name()="Style"][@x:Key="FilterChipToggleStyle"]', $script:xamlNamespace)
        $comboToggleStyle = $resources.SelectSingleNode('./*[local-name()="Style"][@x:Key="ComboBoxToggleButtonStyle"]', $script:xamlNamespace)
        $comboStyle = $resources.SelectSingleNode('./*[local-name()="Style"][@TargetType="ComboBox"]')
        $comboToggle = $comboStyle.SelectSingleNode('.//*[local-name()="ToggleButton"][@Name="ToggleButton"]')
        $comboItemStyle = $resources.SelectSingleNode('./*[local-name()="Style"][@TargetType="ComboBoxItem"]')
        $navButtons = @($script:xaml.SelectNodes('//*[local-name()="StackPanel"][@Name="NavDockPanel"]/*[local-name()="ToggleButton"]'))
        $chipButtons = @($script:xaml.SelectNodes('//*[local-name()="WrapPanel"][@Name="WPFSearchChips"]/*[local-name()="ToggleButton"]'))

        $implicitToggleStyles | Should -BeNullOrEmpty
        $tabStyle | Should -Not -BeNullOrEmpty
        $navToggleStyle | Should -Not -BeNullOrEmpty
        $chipToggleStyle | Should -Not -BeNullOrEmpty
        $comboToggleStyle | Should -Not -BeNullOrEmpty
        # The combo box keeps its own keyed toggle style, so neither the nav rail nor the filter
        # chips can restyle the dropdown button through an implicit lookup
        $comboToggle.GetAttribute("Style") | Should -Be "{StaticResource ComboBoxToggleButtonStyle}"
        $comboItemStyle | Should -Not -BeNullOrEmpty
        # Thirteen pages, but AppX is reached from the removal button instead of the nav rail
        $navButtons.Count | Should -Be 12
        foreach ($navButton in $navButtons) {
            $navButton.GetAttribute("Style") | Should -Be "{StaticResource NavItemToggleStyle}"
        }
        $chipButtons.Count | Should -Be 10
        foreach ($chipButton in $chipButtons) {
            $chipButton.GetAttribute("Style") | Should -Be "{StaticResource FilterChipToggleStyle}"
        }
    }

    It "uses state-aware maximize and restore icons" {
        $themes = Get-WinUtilConfigObject -Name "themes"
        $minimizeButton = $script:xaml.SelectSingleNode('//*[local-name()="Button"][@Name="WPFMinimizeButton"]')
        $maximizeButton = $script:xaml.SelectSingleNode('//*[local-name()="Button"][@Name="WPFMaximizeButton"]')
        $closeButton = $script:xaml.SelectSingleNode('//*[local-name()="Button"][@Name="WPFCloseButton"]')
        $maximizeStyle = $maximizeButton.SelectSingleNode('./*[local-name()="Button.Style"]/*[local-name()="Style"]')
        $maximizeIcon = $maximizeStyle.SelectSingleNode('./*[local-name()="Setter"][@Property="Content"]')
        $maximizedTrigger = $maximizeStyle.SelectSingleNode('./*[local-name()="Style.Triggers"]/*[local-name()="DataTrigger"][@Value="Maximized"]')
        $restoreIcon = $maximizedTrigger.SelectSingleNode('./*[local-name()="Setter"][@Property="Content"]')

        foreach ($button in @($minimizeButton, $maximizeButton, $closeButton)) {
            $button.GetAttribute("FontFamily") | Should -Be "Segoe MDL2 Assets"
            $button.GetAttribute("FontSize") | Should -Be "{DynamicResource CloseIconFontSize}"
            $button.GetAttribute("Margin") | Should -BeIn @("0", "0,0,0,0")
        }

        $minimizeButton.GetAttribute("Content") | Should -Be ([string][char]0xE921)
        $maximizeIcon.GetAttribute("Value") | Should -Be ([string][char]0xE922)
        $restoreIcon.GetAttribute("Value") | Should -Be ([string][char]0xE923)
        $closeButton.GetAttribute("Content") | Should -Be ([string][char]0xE8BB)
        $maximizeStyle.GetAttribute("BasedOn") | Should -Be "{StaticResource HoverButtonStyle}"
        [int]$themes.shared.CloseIconFontSize | Should -BeLessThan ([int]$themes.shared.SettingsIconFontSize)
    }
}

Describe "XAML and sync wiring" {
    It "wires generated config panels to existing target grids" {
        $xamlNames = @(Get-WinUtilXamlRuntimeNamedControls | ForEach-Object { $_.Name })
        $uiLines = Get-Content -Path $script:uiScriptPath
        $invalidTargets = New-Object System.Collections.Generic.List[string]

        foreach ($line in $uiLines) {
            if ($line.TrimStart().StartsWith("#")) {
                continue
            }

            $match = [regex]::Match(
                $line,
                'Invoke-WPFUIElements\s+-configVariable\s+\$sync\.configs\.([A-Za-z0-9_]+)\s+-targetGridName\s+"([^"]+)"'
            )
            if (-not $match.Success) {
                continue
            }

            $configName = $match.Groups[1].Value
            $targetGridName = $match.Groups[2].Value
            if (-not (Test-Path -Path (Join-Path $script:configRoot "$configName.json"))) {
                $invalidTargets.Add("$configName references missing config file")
            }

            if (-not (Test-WinUtilNameInSet -Name $targetGridName -Set $xamlNames)) {
                $invalidTargets.Add("$configName target grid '$targetGridName' was not found in XAML")
            }
        }

        if ($invalidTargets.Count -gt 0) {
            throw ($invalidTargets -join "`n")
        }
    }

    It "references only XAML, generated, or intentionally dynamic sync members" {
        $sourceText = Get-WinUtilSourceText
        $xamlNames = @(Get-WinUtilXamlRuntimeNamedControls | ForEach-Object { $_.Name })
        $generatedNames = @(Get-WinUtilGeneratedControlNames)
        $dynamicStateNames = @(
            "Form",
            "configs",
            "preferences",
            "runspace",
            "Buttons",
            "PSScriptRoot",
            "version",
            "IsLocalCompile",
            "winutildir",
            "logPath",
            "transcriptPath",
            "ActiveJob",
            "ActiveJobToken",
            # Job display name captured by Start-WinUtilJob.ps1 so the UI watchdog can report it
            "ActiveJobLabel",
            "LastJobResult",
            # Intrinsic to the synchronized hashtable rather than WinUtil state; the job layer
            # locks on it to claim and release the active job slot
            "SyncRoot",
            "UIRunspace",
            "UIDispatchDelegate",
            "StepTimings",
            "LoggedErrors",
            "StartedAt",
            "SessionState",
            "TabWarmupQueue",
            "BackgroundQueues",
            "ConsoleProgressState",
            "LastInputAt",
            "ActiveShells",
            "RunspacePoolLock",
            "AssetRenderLock",
            "ShuttingDown",
            "ForceClose",
            "FinishInConsole",
            "PendingCloseWork",
            "StopWatchdogTimer",
            "IconFetchRunning",
            "selected",
            "selectedAppx",
            "selectedApps",
            "selectedTweaks",
            "selectedToggles",
            "selectedFeatures",
            "currentTab",
            "selectedAppsStackPanel",
            "selectedAppsstackPanel",
            "selectedAppsPopup",
            "appPopup",
            "appPopupSelectedApp",
            "ItemsControl",
            "ImportInProgress",
            "ScriptsInstallPrograms",
            "keys",
            "ContainsKey",
            "GetEnumerator",
            "Remove",
            "logorender",
            "checkmarkrender",
            "warningrender",
            "InitializedTabs",
            "AppCategoryChips",
            "SelectedAppCategories",
            "AppCategoryAutoExpanded",
            "RenderedAssetCache",
            "ToggleStatusCache",
            "InstallAppRenderQueue",
            "InstallAppEntriesRendered",
            "FontScaleFactor",
            "Win11ISOImageInfo",
            "Win11ISODriveLetter",
            "Win11ISOWimPath",
            "Win11ISOImagePath",
            "Win11ISOWorkDir",
            "Win11ISOContentsDir",
            "Win11ISOExistingWorkRetryPending",
            "Win11ISOProductFamily",
            "Win11ISOUSBDisks",
            # Disk analysis page state, owned by Initialize-WinUtilDiskAnaPanel.ps1 and the scan
            "DiskAna",
            # Set in scripts/start.ps1 when the script runs inside the packaged .exe host
            "IsExeHost",
            # Unpacked payload directory, published by scripts/main.ps1 for Get-WinUtilAppBaseDir.ps1
            "PayloadDir",
            # Offline flag mirrored into the runspace state by New-WinUtilSessionState.ps1
            "PARAM_OFFLINE",
            # Last job step timestamp/status, written by Step-WinUtilJob.ps1 and read by the watchdog
            "LastStepAt",
            "LastStepStatus",
            # The progress update the interface thread last started painting, so a stall in the log
            # can say whether the update was still queued or the thread hung inside one
            "UiLastUiOperation",
            # Software-render fallback flag, set by Set-WinUtilRenderMode.ps1 for Remote Desktop
            "SoftwareRender",
            # Interface watchdog bookkeeping, all owned by Register-WinUtilUiWatchdog.ps1
            "UiWatchdogHandle",
            "UiWatchdogRunspace",
            "UiWatchdogShell",
            "UiWatchdogStop",
            "UiWatchdogStalled",
            "UiFrameCounter",
            "UiRenderFrames",
            "UiLastPing",
            "UiQuietTicks",
            "UiOffScreen",
            # Taskbar pin state, de-duplicated inside Set-WinUtilTaskbaritem.ps1
            "TaskbarWritten",
            "TaskbarUnusable",
            # Network diagnostics page state: health summary and live host table
            "NetDiagHealth",
            "NetDiagLiveHosts",
            # OUI vendor lookup cache and its source label, filled by NetDiagTools.ps1
            "NetOuiTable",
            "NetOuiSource",
            # pktmon capture session, owned by PktmonCapture.ps1
            "PktmonFile",
            "PktmonRunning",
            "PktmonStarted",
            # Command palette result list and keyboard selection, owned by Invoke-WPFCommandPalette.ps1
            "PaletteMatches",
            "PaletteIndex",
            # Generated printing-tab controls, rebuilt from the config on every visit: the selection
            # lists and the configuration editor's rows
            "EntPrinterRadios",
            "EntShareChecks",
            "EntCfgPrinterRows",
            "EntCfgShareRows"
        )
        $allowedNames = @($xamlNames + $generatedNames + $dynamicStateNames) | Sort-Object -Unique
        $bracketReferences = @(
            [regex]::Matches($sourceText, '\$sync\[\s*["'']([A-Za-z_][A-Za-z0-9_]*)["'']\s*\]') |
                ForEach-Object { $_.Groups[1].Value }
        )
        $dotReferences = @(
            [regex]::Matches($sourceText, '\$sync\.([A-Za-z_][A-Za-z0-9_]*)') |
                ForEach-Object { $_.Groups[1].Value }
        )
        $literalReferences = @($bracketReferences + $dotReferences) | Sort-Object -Unique

        $invalidReferences = @(
            $literalReferences | Where-Object { -not (Test-WinUtilNameInSet -Name $_ -Set $allowedNames) }
        )
        if ($invalidReferences.Count -gt 0) {
            throw ($invalidReferences -join "`n")
        }
    }
}

Describe "WPF handler wiring" {
    It "calls only defined Invoke-WPF functions" {
        $sourceText = Get-WinUtilSourceText
        $functionNames = @(Get-WinUtilTopLevelFunctionNames)
        $featureFunctions = @(
            (Get-WinUtilConfigObject -Name "feature").PSObject.Properties |
                Where-Object { $_.Value.function -and $_.Value.function -like "Invoke-WPF*" } |
                ForEach-Object { $_.Value.function }
        )
        $invokedFunctions = @(
            [regex]::Matches($sourceText, '\b(Invoke-WPF[A-Za-z0-9]+)\b') |
                ForEach-Object { $_.Groups[1].Value }
            $featureFunctions
        ) | Sort-Object -Unique

        $missingFunctions = @(
            $invokedFunctions | Where-Object { -not (Test-WinUtilNameInSet -Name $_ -Set $functionNames) }
        )
        if ($missingFunctions.Count -gt 0) {
            throw ($missingFunctions -join "`n")
        }
    }

    It "routes static WPF buttons through Invoke-WPFButton or explicit handlers" {
        $runtimeControls = @(Get-WinUtilXamlRuntimeNamedControls)
        $buttonControls = @(
            $runtimeControls |
                Where-Object { $_.Name -like "WPF*" -and $_.Type -in @("Button", "ToggleButton") }
        )
        $buttonSwitchNames = @((Get-WinUtilButtonSwitchNames) + (Get-WinUtilButtonRouteNames))
        $buttonSwitchPatterns = @(Get-WinUtilButtonSwitchPatterns)
        $featureNames = @((Get-WinUtilConfigObject -Name "feature").PSObject.Properties.Name)
        $uiScript = Get-Content -Path $script:uiScriptPath -Raw
        $unhandledButtons = New-Object System.Collections.Generic.List[string]

        foreach ($button in $buttonControls) {
            # Tab buttons (WPFTab9BT ... WPFTab11BT) and the network tool rows are never named
            # one by one; the dispatch reaches them through a wildcard branch instead.
            $hasWildcardRoute = @($buttonSwitchPatterns | Where-Object { $button.Name -like $_ }).Count -gt 0
            $hasSwitchHandler = (Test-WinUtilNameInSet -Name $button.Name -Set $buttonSwitchNames) -or $hasWildcardRoute
            $hasFeatureHandler = Test-WinUtilNameInSet -Name $button.Name -Set $featureNames
            $escapedName = [regex]::Escape($button.Name)
            $explicitHandlerPattern = '\$sync\s*(?:\[\s*["'']' + $escapedName + '["'']\s*\]|\.' + $escapedName + ')\.Add_Click'
            $hasExplicitHandler = $uiScript -imatch $explicitHandlerPattern

            # The category chips share one handler, wired from the list that names them
            $hasChipHandler = $uiScript -imatch ('@\{\s*Name\s*=\s*"' + $escapedName + '"')

            if (-not ($hasSwitchHandler -or $hasFeatureHandler -or $hasExplicitHandler -or $hasChipHandler)) {
                $unhandledButtons.Add($button.Name)
            }
        }

        if ($unhandledButtons.Count -gt 0) {
            throw ($unhandledButtons -join "`n")
        }
    }

    It "invokes existing WPF button names" {
        $sourceText = Get-WinUtilSourceText
        $xamlNames = @(Get-WinUtilXamlRuntimeNamedControls | ForEach-Object { $_.Name })
        $generatedNames = @(Get-WinUtilGeneratedControlNames)
        $validButtonNames = @($xamlNames + $generatedNames) | Sort-Object -Unique
        $buttonNames = @(
            [regex]::Matches($sourceText, 'Invoke-WPFButton\s+["'']([^"'']+)["'']') |
                ForEach-Object { $_.Groups[1].Value }
        ) | Sort-Object -Unique

        $missingButtons = @(
            $buttonNames | Where-Object { -not (Test-WinUtilNameInSet -Name $_ -Set $validButtonNames) }
        )
        if ($missingButtons.Count -gt 0) {
            throw ($missingButtons -join "`n")
        }
    }
}
