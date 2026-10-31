function Invoke-WPFButton {

    <#

    .SYNOPSIS
        Routes a button press, deciding whether it is interface work or a job

    .DESCRIPTION
        This is the one place that classifies a button. Anything that changes the system runs
        through Start-WinUtilJob, which means it gets the busy flag, the progress bar, the
        taskbar item, the console banner and the log lines without each workflow arranging that
        for itself. Anything that only changes what the interface is showing runs here and now,
        because pushing it onto a worker would just make it slower.

    .PARAMETER Button
        The name of the button that was clicked

    #>

    Param ([string]$Button)

    # Clear the progress left behind by the previous job, but never while one is running
    if (-not $sync.ActiveJob) {
        Step-WinUtilJob -Hide
    }

    $featureEntry = $sync.configs.feature.$Button
    $route = Get-WinUtilButtonRoute -Button $Button

    # Feature installation owns its selection validation and snapshots the selection before it
    # starts a job. Wrapping it here would turn its "nothing selected" return into job success.
    $isConfigWork = $featureEntry -and $Button -ne "WPFFeatureInstall" -and
        ($Button -notlike "WPFPanel*" -or $featureEntry.function)

    # Which buttons change the system is declared beside what they run, in config\routes.json.
    # It has to stay a declaration and not "everything reaches here": window chrome and popup
    # toggles are routed through this function as well, because every Button in $sync is wired
    # to it, and turning those into jobs would block the interface on a click that paints a panel.
    if ($isConfigWork -or $route.work -eq $true) {
        # Confirmed here, on the interface thread, before the worker exists: a modal dialog raised
        # inside a job has no window of its own to hold it, and the user would be asked after the
        # work had already started.
        $actionConfirmed = $true
        if ($route.confirm) {
            $actionConfirmed = [bool](& $route.confirm)
            if (-not $actionConfirmed) {
                return
            }
        }

        Start-WinUtilJob -Name (Get-WinUtilButtonLabel -Button $Button) -Parameters @{
            Button = $Button
            Confirmed = $actionConfirmed
        } -ScriptBlock {
            param($Button, $Confirmed)

            Invoke-WPFButtonAction -Button $Button -Confirmed:$Confirmed
        }
        return
    }

    # A handler that throws on the interface thread would otherwise reach the user as a bare
    # message with no indication of which control produced it
    try {
        Invoke-WPFButtonAction -Button $Button
    } catch {
        Write-WinUtilErrorRecord -ErrorRecord $_ -Component "UI" -Context "Button '$Button'"
    }
}

function Get-WinUtilButtonRoute {

    <#

    .SYNOPSIS
        Returns the config\routes.json entry for a button, or null when it has none

    .DESCRIPTION
        One entry per button: the function it calls, the arguments it calls it with, whether the
        click changes the system and whether it has to be confirmed first. A button is allowed to
        declare only part of that - the wildcard families and the handful of controls whose action
        is a line of code rather than a function call stay in Invoke-WPFButtonAction.

    #>

    param([string]$Button)

    return $sync.configs.routes.$Button
}

function Get-WinUtilButtonLabel {
    <#
    .SYNOPSIS
        Returns the name a button's job should be reported under.

    .DESCRIPTION
        Whatever the button says is what the progress bar, the banner and the log say, so the
        wording never drifts from the interface and there is no second list to maintain. Falls
        back to the button name when there is nothing to read.
    #>
    param([string]$Button)

    $content = $sync.configs.feature.$Button.Content
    if (-not [string]::IsNullOrWhiteSpace($content)) {
        return $content
    }

    $control = $sync.$Button
    if ($control -and $control.Content) {
        $text = if ($control.Content -is [string]) { $control.Content } else { $control.Content.Text }
        if (-not [string]::IsNullOrWhiteSpace($text)) {
            return ([string]$text).Trim()
        }
    }

    $fallback = ($Button -replace '^WPF', '')
    if ([string]::IsNullOrWhiteSpace($fallback)) {
        return "WinUtil"
    }
    return $fallback
}

function Invoke-WPFButtonAction {

    <#

    .SYNOPSIS
        Invokes the function associated with the clicked button

    .DESCRIPTION
        The work itself. Called by Invoke-WPFButton, either directly or from inside a job, so it
        must not concern itself with progress, busy state or banners.

    .PARAMETER Button
        The name of the button that was clicked

    #>

    Param (
        [string]$Button,
        [switch]$Confirmed
    )

    # Check if button is defined in feature config with function or InvokeScript
    if ($sync.configs.feature.$Button) {
        $buttonConfig = $sync.configs.feature.$Button

        # If button has a function defined, call it
        if ($buttonConfig.function) {
            $functionName = $buttonConfig.function
            if (Get-Command $functionName -ErrorAction SilentlyContinue) {
                & $functionName
                return
            }
        }

        # If button has InvokeScript defined, execute the scripts
        if ($buttonConfig.InvokeScript -and $buttonConfig.InvokeScript.Count -gt 0) {
            foreach ($script in $buttonConfig.InvokeScript) {
                if (-not [string]::IsNullOrWhiteSpace($script)) {
                    Invoke-Command -ScriptBlock ([scriptblock]::Create($script)) -ErrorAction Stop
                }
            }
            return
        }
    }

    # The button's own declaration in config\routes.json: which function to call and with what.
    $route = Get-WinUtilButtonRoute -Button $Button
    if ($route -and $route.function) {
        if (-not (Get-Command $route.function -ErrorAction SilentlyContinue)) {
            Write-WinUtilLog -Level "WARN" -Component "UI" -Message "按钮「$Button」声明的处理函数 $($route.function) 不存在，点击无效。"
            return
        }

        $arguments = @{}
        if ($route.arguments) {
            foreach ($argument in $route.arguments.PSObject.Properties) {
                $arguments[$argument.Name] = $argument.Value
            }
        }

        # Only a route that asks to be confirmed receives the answer, so the click cannot silently
        # skip a handler that takes no such parameter
        if ($route.confirm) {
            $arguments.Confirmed = [bool]$Confirmed
        }

        & $route.function @arguments
        return
    }

    # What stays in code: the wildcard families, whose key is a shape rather than a button name,
    # the window chrome, and the three selection loops that walk the AppX hashtable. A route is
    # allowed to declare only "work", which lands here as well - WPFGetInstalledAppx does.
    Switch -Wildcard ($Button) {
        "WPFTab?BT" {Invoke-WPFTab $Button}
        "WPFTab??BT" {Invoke-WPFTab $Button}
        # The tool rows all end in the tool name, so one branch covers fourteen of them and a new
        # row only has to add a case inside Invoke-WPFNetTool
        "WPFFNetTool*" {Invoke-WPFNetTool -Button $Button}
        "WPFSelectAllAppx" {
            $sync.configs.appxHashtable.Keys | ForEach-Object {$sync.$_.IsChecked = $true}
        }
        "WPFClearAppxSelection" {
            $sync.configs.appxHashtable.Keys | ForEach-Object {$sync.$_.IsChecked = $false}
        }
        "WPFGetInstalledAppx" {
            $installedAppxPackages = Get-WinUtilInstalledAPPX
            Invoke-WPFUIThread -Parameters @{ Installed = $installedAppxPackages } -ScriptBlock {
                param($Installed)
                foreach ($appx in $sync.configs.appxHashtable.GetEnumerator()) {
                    if ($appx.Value.PackageId -in $Installed) {
                        $sync.$($appx.Key).IsChecked = $true
                    }
                }
            }
        }
        # Closing may be declined, or leave a job running that outlives the window, so the
        # goodbye belongs at the point the process actually ends rather than here
        "WPFCloseButton" {$sync.Form.Close()}
        "WPFMinimizeButton" {[Windows.SystemCommands]::MinimizeWindow($sync.Form)}
        "WPFMaximizeButton" {
            if ($sync.Form.WindowState -eq [Windows.WindowState]::Normal) {
                [Windows.SystemCommands]::MaximizeWindow($sync.Form)
            } else {
                [Windows.SystemCommands]::RestoreWindow($sync.Form)
            }
        }
        "WPFselectedAppsButton" {$sync.selectedAppsPopup.IsOpen = -not $sync.selectedAppsPopup.IsOpen}
        # Every control reaches this function, so a button that matches nothing here, in
        # feature.json and in routes.json is a wiring mistake rather than an idle control - and
        # the only way to find one by hand is to click it and watch nothing happen.
        default {
            Write-WinUtilLog -Level "WARN" -Component "UI" -Message "按钮「$Button」没有声明处理方式，点击后什么都没发生。"
        }
    }
}
