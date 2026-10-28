function Start-WinUtilUserInterface {
    <#
        .SYNOPSIS
            Builds the WinUtil window, wires its event handlers and runs it to completion

        .DESCRIPTION
            This is the whole interface. It runs on the dedicated STA interface runspace that
            main.ps1 starts, so the thread that owns the window does nothing but paint and
            dispatch: every long operation goes to the worker pool through Start-WinUtilJob.

            The call blocks until the window is closed, and the interface runspace is the only
            place that is allowed to touch controls directly.
    #>

    $buildClock = [System.Diagnostics.Stopwatch]::StartNew()

    Measure-WinUtilStep -Scope "UI" -Name "load WPF assemblies" -ScriptBlock {
        [void][System.Reflection.Assembly]::LoadWithPartialName('presentationframework')
    }

    # Decided before the window exists, and before anything has been composited: in a remote
    # session WPF draws through the display driver, and that pipe can stop handing out frames while
    # the process and its thread keep running - which the user reports as a frozen window.
    Set-WinUtilRenderMode

    [xml]$XAML = $inputXML

    # Read the XAML file
    $readerOperationSuccessful = $false # There's more cases of failure then success.
    $readerFailure = $null
    $reader = (New-Object System.Xml.XmlNodeReader $xaml)
    try {
        Measure-WinUtilStep -Scope "UI" -Name "parse XAML" -ScriptBlock {
            $sync["Form"] = [Windows.Markup.XamlReader]::Load( $reader )
        }
        $readerOperationSuccessful = $true
    } catch [System.Management.Automation.MethodInvocationException] {
        $readerFailure = $_
        Write-Host "XAML 代码存在问题，请检查这个控件附近的语法。" -ForegroundColor Red
        Write-Host $error[0].Exception.Message -ForegroundColor Red

        If ($error[0].Exception.Message -like "*button*") {
            write-Host "请确保 `$inputXML 里的 &lt;button 不要带 Click=ButtonClick 属性，PowerShell 不能直接处理它。`n`n`n`n" -ForegroundColor Red
        }
    } catch {
        $readerFailure = $_
        Write-Host "无法加载 Windows.Markup.XamlReader，请检查语法，并确认 .NET 已安装。" -ForegroundColor Red
    }

    if (-NOT ($readerOperationSuccessful)) {
        Write-Host "使用 Windows.Markup.XamlReader 的 Load 方法解析 XAML 失败。" -ForegroundColor Red
        Write-Host "Quitting WinUtil..." -ForegroundColor Red
        Write-WinUtilLog -Level "ERROR" -Component "UI" -Message "Failed to parse the XAML content. WinUtil cannot start."
        throw [System.InvalidOperationException]::new("Failed to parse the XAML content. WinUtil cannot start.", $readerFailure.Exception)
    }

    # Setup the Window to follow listen for windows Theme Change events and update the winutil theme
    # throttle logic needed, because windows seems to send more than one theme change event per change
    $themeState = @{ LastChange = [datetime]::MinValue }
    $debounceInterval = [timespan]::FromSeconds(2)
    $sync.Form.Add_Loaded({
        $interopHelper = New-Object System.Windows.Interop.WindowInteropHelper $sync.Form
        $hwndSource = [System.Windows.Interop.HwndSource]::FromHwnd($interopHelper.Handle)
        $hwndSource.AddHook({
            param (
                [System.IntPtr]$hwnd,
                [int]$msg,
                [System.IntPtr]$wParam,
                [System.IntPtr]$lParam,
                [ref]$handled
            )
            $null = $hwnd, $wParam, $lParam
            # Check for the Event WM_SETTINGCHANGE (0x1001A) and validate that Button shows the icon for "Auto" => [char]0xF08C
            if (($msg -eq 0x001A) -and $sync.ThemeButton.Content -eq [char]0xF08C) {
                $currentTime = [datetime]::Now
                if ($currentTime - $themeState.LastChange -gt $debounceInterval) {
                    Invoke-WinutilThemeChange -theme "Auto"
                    $themeState.LastChange = $currentTime
                    # [ref] out-parameter: assigning to $handled would only replace the local
                    $handled.Value = $true
                }
            }
            return 0
        })
    })

    Measure-WinUtilStep -Scope "UI" -Name "apply theme" -ScriptBlock {
        Invoke-WinutilThemeChange -theme $sync.preferences.theme
    }

    # No tab content is built before first paint. Invoke-WPFTab builds whichever tab it
    # activates, and ContentRendered activates the default one.
    $sync.InitializedTabs = @{}

    #===========================================================================
    # Store Form Objects In PowerShell
    #===========================================================================

    Measure-WinUtilStep -Scope "UI" -Name "map named controls" -ScriptBlock {
        $xaml.SelectNodes("//*[@Name]") | ForEach-Object {$sync["$("$($psitem.Name)")"] = $sync["Form"].FindName($psitem.Name)}
    }

    # Built here so it carries this runspace's session state: posted work then runs as ordinary
    # interface code, not a much slower cross-runspace nested pipeline. Invoke-WPFUIThread is the
    # caller-facing side.
    $sync.UIDispatchDelegate = [System.Func[object, object]]{
        param($Work)

        try {
            $body = [scriptblock]::Create($Work.Body)
            $parameters = $Work.Parameters
            if ($parameters -and $parameters.Count -gt 0) {
                & $body @parameters
            } else {
                & $body
            }
        } catch {
            if ($Work.PropagateErrors) {
                throw
            }
            # Fire-and-forget work has no waiting caller to report its failure.
            Write-WinUtilErrorRecord -ErrorRecord $_ -Component "UI" -Context "Interface work"
        }
    }

    Measure-WinUtilStep -Scope "UI" -Name "wire static button clicks" -ScriptBlock {
        # CheckBox and RadioButton also derive from ButtonBase, so the exact type name is what
        # decides, not -is
        $clickableTypes = [System.Collections.Generic.HashSet[string]]::new([string[]]@("Button", "ToggleButton"), [StringComparer]::OrdinalIgnoreCase)
        $alreadyWired = [System.Collections.Generic.HashSet[string]]::new([string[]]@($sync.Buttons), [StringComparer]::OrdinalIgnoreCase)

        $clickHandler = {
            [System.Object]$Sender = $args[0]
            Invoke-WPFButton $Sender.name
        }

        foreach ($entry in @($sync.GetEnumerator())) {
            $control = $entry.Value
            if ($null -eq $control -or -not $clickableTypes.Contains($control.GetType().Name)) {
                continue
            }
            if (-not $alreadyWired.Add([string]$entry.Key)) {
                continue
            }

            $control.Add_Click($clickHandler)
            $sync.Buttons.Add($entry.Key) | Out-Null
        }
    }

    #===========================================================================
    # Setup and Show the Form
    #===========================================================================

    # Progress bar in taskbaritem > Set-WinUtilProgressbar
    $sync["Form"].TaskbarItemInfo = New-Object System.Windows.Shell.TaskbarItemInfo
    Set-WinUtilTaskbaritem -state "None"

    # Wired before the window is shown, so work queued during startup already knows to stand
    # aside for anything the user does
    Register-WinUtilInputWatch

    # Set the titlebar
    $sync["Form"].title = $sync["Form"].title + " " + $sync.version
    # Set the commands that will run when the form is closed
    $sync["Form"].Add_Closing({
        param($eventSender, $closingArgs)
        $null = $eventSender

        # A capture outlives nothing worth the risk: the driver would keep writing with no
        # interface left to stop it
        if ($sync.PktmonRunning) {
            Stop-WinUtilPktmonImmediately
        }

        # The pool cannot be torn down under work that is still running: the runspace error that
        # follows is unhandled and ends the process
        if ($sync.ActiveJob -and -not $sync.ForceClose) {
            $closingArgs.Cancel = $true
            Invoke-WinUtilCloseRequest -RunningJob $(if ($sync.ActiveJobLabel) { $sync.ActiveJobLabel } else { $sync.ActiveJob })
            return
        }

        # The window is really going: nothing should still be waiting on a heartbeat that would read
        # the shutdown as a stall
        Stop-WinUtilUiWatchdog

        # Work that is meant to outlive the window needs the pool it is running on. main.ps1
        # waits for it and shuts the pool down once it is done.
        if ($sync.FinishInConsole) {
            Write-WinUtilLog -Component "UI" -Message "Window closing, leaving $($sync.ActiveJob) to finish in the console."
            return
        }

        # main.ps1 owns pool shutdown after the window has finished closing. Doing it from this
        # dispatcher callback can deadlock with a worker that is in its UI-thread cleanup block.
        Write-WinUtilLog -Component "UI" -Message "Window closing; the main thread will shut down the worker pool."
    })

    # Attach the event handler to the Click event
    $sync.SearchBarClearButton.Add_Click({
        $sync.SearchBar.Text = ""
        $sync.SearchBarClearButton.Visibility = "Collapsed"

        # Focus the search bar after clearing the text
        $sync.SearchBar.Focus()
        $sync.SearchBar.SelectAll()
    })

    # add some shortcuts for people that don't like clicking
    function Invoke-WinUtilFontScaleStep([double]$Step) { $sync.FontScalingSlider.Value = [math]::Max(0.75, [math]::Min(2.0, $sync.FontScalingSlider.Value + $Step)); Invoke-WinUtilFontScaling -ScaleFactor $sync.FontScalingSlider.Value }

    $commonKeyEvents = {
        if ($sync.ActiveJob) {
            return
        }

        # Handle key presses of single keys
        switch ($_.Key) {
            "Escape" { $sync.SearchBar.Text = "" }
        }
        # Handle Alt key combinations for navigation
        if ($_.KeyboardDevice.Modifiers -eq "Alt") {
            $keyEventArgs = $_
            switch ($_.SystemKey) {
                "I" { Invoke-WPFButton "WPFTab1BT"; $keyEventArgs.Handled = $true } # Navigate to Install tab and suppress Windows Warning Sound
                "T" { Invoke-WPFButton "WPFTab2BT"; $keyEventArgs.Handled = $true } # Navigate to Tweaks tab
                "C" { Invoke-WPFButton "WPFTab3BT"; $keyEventArgs.Handled = $true } # Navigate to Config tab
                "U" { Invoke-WPFButton "WPFTab4BT"; $keyEventArgs.Handled = $true } # Navigate to Updates tab
                "W" { Invoke-WPFButton "WPFTab5BT"; $keyEventArgs.Handled = $true } # Navigate to Win11ISO tab
            }
        }
        # Handle Ctrl key combinations for specific actions
        if ($_.KeyboardDevice.Modifiers -eq "Ctrl") {
            $keyEventArgs = $_
            switch ($_.Key) {
                "F" { $sync.SearchBar.Focus() } # Focus on the search bar
                "Q" { $this.Close() } # Close the application
            }
        }
        $ctrlShiftModifiers = [Windows.Input.ModifierKeys]::Control -bor [Windows.Input.ModifierKeys]::Shift
        if ($_.KeyboardDevice.Modifiers -eq "Ctrl" -or $_.KeyboardDevice.Modifiers -eq $ctrlShiftModifiers) {
            $keyEventArgs = $_
            switch ($_.Key) {
                { $_ -in "OemPlus", "Add" } { Invoke-WinUtilFontScaleStep 0.05; $keyEventArgs.Handled = $true }
                { $_ -in "OemMinus", "Subtract" } { Invoke-WinUtilFontScaleStep -0.05; $keyEventArgs.Handled = $true }
            }
        }
    }
    $sync["Form"].Add_PreViewKeyDown($commonKeyEvents)
    $sync["Form"].Add_PreviewMouseWheel({
        if ([Windows.Input.Keyboard]::Modifiers -eq "Ctrl") { Invoke-WinUtilFontScaleStep $(if ($_.Delta -gt 0) { 0.05 } else { -0.05 }); $_.Handled = $true }
    })

    $sync["Form"].Add_MouseLeftButtonDown({
        Invoke-WPFPopup -Action "Hide" -Popups @("Settings", "Theme", "FontScaling")
        $sync["Form"].DragMove()
    })

    $sync["Form"].Add_MouseDoubleClick({
        if ($_.OriginalSource.Name -eq "NavDockPanel" -or
            $_.OriginalSource.Name -eq "GridBesideNavDockPanel") {
                if ($sync["Form"].WindowState -eq [Windows.WindowState]::Normal) {
                    [Windows.SystemCommands]::MaximizeWindow($sync.Form)
                }
                else{
                    [Windows.SystemCommands]::RestoreWindow($sync.Form)
                }
        }
    })

    $sync["Form"].Add_Deactivated({
        Invoke-WPFPopup -Action "Hide" -Popups @("Settings", "Theme", "FontScaling")
    })

    $sync["Form"].Add_ContentRendered({
        # Load the Windows Forms assembly
        Add-Type -AssemblyName System.Windows.Forms
        $primaryScreen = [System.Windows.Forms.Screen]::PrimaryScreen
        # Check if the primary screen is found
        if ($primaryScreen) {
            # Extract screen width and height for the primary monitor
            $screenWidth = $primaryScreen.Bounds.Width
            $screenHeight = $primaryScreen.Bounds.Height
            $sync.Form.MinWidth = [Math]::Min([double]$sync.Form.MinWidth, [double]$screenWidth)

            # Compare with the primary monitor size
            if ($sync.Form.ActualWidth -gt $screenWidth -or $sync.Form.ActualHeight -gt $screenHeight) {
                $sync.Form.Left = 0
                $sync.Form.Top = 0
                $sync.Form.Width = $screenWidth
                $sync.Form.Height = $screenHeight
            }
        }

        if ($PARAM_OFFLINE) {
            # Show offline banner
            $sync.WPFOfflineBanner.Visibility = [System.Windows.Visibility]::Visible

            # Disable the install tab
            $sync.WPFTab1BT.IsEnabled = $false
            $sync.WPFTab1BT.Opacity = 0.5
            $sync.WPFTab1BT.ToolTip = "安装应用需要网络连接。"

            # The install action buttons are generated with the Install tab, so
            # Initialize-WinUtilInstallTabControls disables them when that tab is built

            # Show offline indicator
            Write-Host "检测到离线模式，已禁用安装标签页。" -ForegroundColor Yellow

            # Optionally switch to a different tab if install tab was going to be default
            Invoke-WPFTab "WPFTab9BT" -Yield  # Overview still opens; install is disabled inside it
        }
        else {
            # Online - ensure install tab is enabled
            $sync.WPFTab1BT.IsEnabled = $true
            $sync.WPFTab1BT.Opacity = 1.0
            $sync.WPFTab1BT.ToolTip = $null
            Invoke-WPFTab "WPFTab9BT" -Yield  # Enterprise consoles open on the dashboard
        }

        $sync["Form"].Focus()
        $sync["Form"].Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [action]{ Initialize-WinUtilRunspacePool | Out-Null }) | Out-Null
        $sync["Form"].Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [action]{
            Set-WinUtilTaskbaritem -overlay "logo"
        }) | Out-Null
        $sync["Form"].Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [action]{ Start-WinUtilTabWarmup }) | Out-Null
    })

    # The SearchBarTimer is used to delay the search operation until the user has stopped typing for a short period
    # This prevents the ui from stuttering when the user types quickly as it dosnt need to update the ui for every keystroke

    $searchBarTimer = New-Object System.Windows.Threading.DispatcherTimer
    $searchBarTimer.Interval = [TimeSpan]::FromMilliseconds(300)
    $searchBarTimer.IsEnabled = $false

    $searchBarTimer.add_Tick({
        $searchBarTimer.Stop()
        switch ($sync.currentTab) {
            "Install" {
                Find-AppsByNameOrDescription -SearchString $sync.SearchBar.Text -Categories $sync.SelectedAppCategories.ToArray()
            }
            "Tweaks" {
                Find-TweaksByNameOrDescription -SearchString $sync.SearchBar.Text
            }
            "AppX" {
                Find-TweaksByNameOrDescription -SearchString $sync.SearchBar.Text
            }
        }
    })
    $sync["SearchBar"].Add_TextChanged({
        if ($sync.SearchBar.Text -ne "") {
            $sync.SearchBarClearButton.Visibility = "Visible"
            $sync.SearchBarIcon.Visibility = "Collapsed"
        } else {
            $sync.SearchBarClearButton.Visibility = "Collapsed"
            $sync.SearchBarIcon.Visibility = "Visible"
        }

        if ($searchBarTimer.IsEnabled) {
            $searchBarTimer.Stop()
        }
        $searchBarTimer.Start()
    })

    # Category filter chips. The chip carries its category in Tag, so one handler covers all of them.
    $sync.AppCategoryChips = @(
        @{ Name = "WPFSearchChipAll";       Category = "" }
        @{ Name = "WPFSearchChipComms";     Category = "通讯协作" }
        @{ Name = "WPFSearchChipOffice";    Category = "文档办公" }
        @{ Name = "WPFSearchChipUtilities"; Category = "常用工具" }
        @{ Name = "WPFSearchChipInput";     Category = "输入法" }
        @{ Name = "WPFSearchChipNetwork";   Category = "网络工具" }
        @{ Name = "WPFSearchChipMedia";     Category = "影音娱乐" }
        @{ Name = "WPFSearchChipRemote";    Category = "远程运维" }
        @{ Name = "WPFSearchChipDev";       Category = "开发工具" }
        @{ Name = "WPFSearchChipPos";       Category = "门店收银" }
    )
    $sync.SelectedAppCategories = [System.Collections.Generic.List[string]]::new()

    foreach ($appCategoryChip in $sync.AppCategoryChips) {
        $sync[$appCategoryChip.Name].Tag = $appCategoryChip.Category
        $sync[$appCategoryChip.Name].Add_Click({ Invoke-WinUtilAppCategoryChip -Chip $this })
    }

    $sync["Form"].Add_Loaded({
        param($e)
        $null = $e
        $sync.Form.MinWidth = "1150"
        $sync["Form"].MaxWidth = [Double]::PositiveInfinity
        $sync["Form"].MaxHeight = [Double]::PositiveInfinity
    })

    Measure-WinUtilStep -Scope "UI" -Name "build nav logo" -ScriptBlock {
        $NavLogoPanel = $sync["Form"].FindName("NavLogoPanel")
        $NavLogoPanel.Children.Add((Invoke-WinUtilAssets -Type "logo" -Size 25)) | Out-Null
    }

    $sync["Form"].Add_Activated({
        Set-WinUtilTaskbaritem -overlay "logo"
    })

    $sync["ThemeButton"].Add_Click({
        Invoke-WPFPopup -PopupActionTable @{ "Settings" = "Hide"; "Theme" = "Toggle"; "FontScaling" = "Hide" }
    })
    $sync["AutoThemeMenuItem"].Add_Click({
        Invoke-WPFPopup -Action "Hide" -Popups @("Theme")
        Invoke-WinutilThemeChange -theme "Auto"
    })
    $sync["DarkThemeMenuItem"].Add_Click({
        Invoke-WPFPopup -Action "Hide" -Popups @("Theme")
        Invoke-WinutilThemeChange -theme "Dark"
    })
    $sync["LightThemeMenuItem"].Add_Click({
        Invoke-WPFPopup -Action "Hide" -Popups @("Theme")
        Invoke-WinutilThemeChange -theme "Light"
    })

    $sync["SettingsButton"].Add_Click({
        Invoke-WPFPopup -PopupActionTable @{ "Settings" = "Toggle"; "Theme" = "Hide"; "FontScaling" = "Hide" }
    })
    $sync["ImportMenuItem"].Add_Click({
        Invoke-WPFPopup -Action "Hide" -Popups @("Settings")
        Invoke-WPFImpex -type "import"
    })
    $sync["ExportMenuItem"].Add_Click({
        Invoke-WPFPopup -Action "Hide" -Popups @("Settings")
        Invoke-WPFImpex -type "export"
    })
    $sync["ExportEnvironmentReportMenuItem"].Add_Click({
        Invoke-WPFPopup -Action "Hide" -Popups @("Settings")
        Invoke-WPFExportEnvironmentReport
    })
    $sync["AboutMenuItem"].Add_Click({
        Invoke-WPFPopup -Action "Hide" -Popups @("Settings")

        $authorInfo = @"
工具     : 企业运维工具（EntOps）
二次开发 : <a href="https://github.com/nealzz86">github.com/nealzz86</a>
上游项目 : <a href="https://github.com/ChrisTitusTech/winutil">ChrisTitusTech/winutil</a>（原作者 <a href="https://github.com/ChrisTitusTech">@ChrisTitusTech</a>）
版本     : $($sync.version)
"@
        Show-CustomDialog -Title "关于" -Message $authorInfo
    })
    $sync["DocumentationMenuItem"].Add_Click({
        Invoke-WPFPopup -Action "Hide" -Popups @("Settings")
        Start-Process "https://winutil.christitus.com/"
    })
    $sync["SponsorMenuItem"].Add_Click({
        Invoke-WPFPopup -Action "Hide" -Popups @("Settings")

        $authorInfo = @"
<a href="https://github.com/sponsors/ChrisTitusTech">Current sponsors for ChrisTitusTech:</a>
"@
        $authorInfo += "`n"
        try {
            $sponsors = Invoke-WinUtilSponsors
            foreach ($sponsor in $sponsors) {
                $authorInfo += "<a href=`"https://github.com/sponsors/ChrisTitusTech`">$sponsor</a>`n"
            }
        } catch {
            $authorInfo += "An error occurred while fetching or processing the sponsors: $_`n"
        }
        Show-CustomDialog -Title "赞助" -Message $authorInfo -EnableScroll $true
    })

    # Font Scaling Event Handlers
    $sync["FontScalingButton"].Add_Click({
        Invoke-WPFPopup -PopupActionTable @{ "Settings" = "Hide"; "Theme" = "Hide"; "FontScaling" = "Toggle" }
    })

    $sync["FontScalingSlider"].Add_ValueChanged({
        param($slider)
        $percentage = [math]::Round($slider.Value * 100)
        $sync.FontScalingValue.Text = "$percentage%"
    })

    $sync["FontScalingResetButton"].Add_Click({
        $sync.FontScalingSlider.Value = 1.0
        $sync.FontScalingValue.Text = "100%"
    })

    $sync["FontScalingApplyButton"].Add_Click({
        $scaleFactor = $sync.FontScalingSlider.Value
        Invoke-WinUtilFontScaling -ScaleFactor $scaleFactor
        Invoke-WPFPopup -Action "Hide" -Popups @("FontScaling")
    })

    # Win11ISO Tab button handlers
    $sync["WPFWin11ISOBrowseButton"].Add_Click({
        Invoke-WinUtilISOBrowse
    })

    $sync["WPFWin11ISODownloadLink"].Add_Click({
        Start-Process "https://www.microsoft.com/software-download/windows11"
    })

    $sync["WPFWin11ISOMountButton"].Add_Click({
        Invoke-WinUtilISOMountAndVerify
    })

    $sync["WPFWin11ISOModifyButton"].Add_Click({
        Invoke-WinUtilISOModify
    })

    $sync["WPFWin11ISOChooseISOButton"].Add_Click({
        $sync["WPFWin11ISOOptionUSB"].Visibility = "Collapsed"
        Invoke-WinUtilISOExport
    })

    $sync["WPFWin11ISOChooseUSBButton"].Add_Click({
        $sync["WPFWin11ISOOptionUSB"].Visibility = "Visible"
        Invoke-WinUtilISORefreshUSBDrives
    })

    $sync["WPFWin11ISORefreshUSBButton"].Add_Click({
        Invoke-WinUtilISORefreshUSBDrives
    })

    $sync["WPFWin11ISOWriteUSBButton"].Add_Click({
        Invoke-WinUtilISOWriteUSB
    })

    $sync["WPFWin11ISOCleanResetButton"].Add_Click({
        Invoke-WinUtilISOCleanAndReset
    })

    $sync["WPFWin11ISOBackButton"].Add_Click({
        $sync["WPFWin11ISOSelectSection"].IsSelected = $true
    })

    $sync["WPFWin11ISOForwardButton"].Add_Click({
        $sync["WPFWin11ISOModifySection"].IsSelected = $true
    })

    $buildClock.Stop()
    Write-WinUtilLog -Level "DEBUG" -Component "UI" -Message "Interface built in $($buildClock.ElapsedMilliseconds) ms, showing the window."
    Write-WinUtilTimingSummary -Scope "UI" -TotalMilliseconds $buildClock.ElapsedMilliseconds

    # Input priority runs behind everything already queued, so this fires at the first moment
    # the window could actually service a click
    $sync["Form"].Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Input, [action]{
        $sinceStart = [int]((Get-Date) - $sync.StartedAt).TotalMilliseconds
        Write-WinUtilLog -Level "DEBUG" -Component "UI" -Message "timing: interface ready for input $sinceStart ms after start."
    }) | Out-Null

    Register-WinUtilUiWatchdog

    $sync["Form"].ShowDialog() | Out-Null

    # Nothing may be posted to a dispatcher that has stopped
    Stop-WinUtilUiWatchdog

    # ShowDialog returns once the window is gone; stop the dispatcher so this runspace can close
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown()
}
