function Set-WinUtilTaskbaritem {
    <#

    .SYNOPSIS
        Modifies the Taskbaritem of the WPF Form

    .PARAMETER value
        Value can be between 0 and 1, 0 being no progress done yet and 1 being fully completed
        Value does not affect item without setting the state to 'Normal', 'Error' or 'Paused'
        Set-WinUtilTaskbaritem -value 0.5

    .PARAMETER state
        State can be 'None' > No progress, 'Indeterminate' > inf. loading gray, 'Normal' > Gray, 'Error' > Red, 'Paused' > Yellow
        no value needed:
        - Set-WinUtilTaskbaritem -state "None"
        - Set-WinUtilTaskbaritem -state "Indeterminate"
        value needed:
        - Set-WinUtilTaskbaritem -state "Error"
        - Set-WinUtilTaskbaritem -state "Normal"
        - Set-WinUtilTaskbaritem -state "Paused"

    .PARAMETER overlay
        Overlay icon to display on the taskbar item, there are the presets 'None', 'logo' and 'checkmark' or you can specify a path/link to an image file.
        CTT logo preset:
        - Set-WinUtilTaskbaritem -overlay "logo"
        Checkmark preset:
        - Set-WinUtilTaskbaritem -overlay "checkmark"
        Warning preset:
        - Set-WinUtilTaskbaritem -overlay "warning"
        No overlay:
        - Set-WinUtilTaskbaritem -overlay "None"
        Custom icon (needs to be supported by WPF):
        - Set-WinUtilTaskbaritem -overlay "C:\path\to\icon.png"

    .PARAMETER description
        Description to display on the taskbar item preview
        Set-WinUtilTaskbaritem -description "This is a description"
    #>
    param (
        [string]$state,
        [double]$value,
        [string]$overlay,
        [string]$description
    )

    # The taskbar belongs to explorer: every write here is a cross-process call the shell answers
    # when it gets around to it, and while it is busy the interface thread waits inside that call.
    # That is a frozen window with nothing on screen to explain it, so one slow write is enough to
    # stop using the taskbar for the rest of the run. The progress bar in the window says the same.
    if ($sync.TaskbarUnusable) { return }
    if ($null -eq $sync["Form"] -or $null -eq $sync["Form"].TaskbarItemInfo) { return }

    $writeClock = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        Update-WinUtilTaskbaritem @PSBoundParameters
    } finally {
        $writeClock.Stop()
        if ($writeClock.ElapsedMilliseconds -gt 1000) {
            $sync.TaskbarUnusable = $true
            Write-WinUtilLog -Level "WARN" -Component "UI" -Message (
                "任务栏进度接口一次用了 $($writeClock.ElapsedMilliseconds) ms，本次运行不再更新任务栏图标（窗口内的进度条不受影响）。")
        }
    }
}

function Update-WinUtilTaskbaritem {
    <#
        .SYNOPSIS
            Writes the taskbar item, skipping anything that already says that

        .DESCRIPTION
            Kept separate from Set-WinUtilTaskbaritem so the timing and the giving-up decision sit
            in one place around every call into the shell.
    #>
    param (
        [string]$state,
        [double]$value,
        [string]$overlay,
        [string]$description
    )

    $last = $sync.TaskbarWritten
    if ($null -eq $last) {
        $last = @{ State = $null; Value = $null; Overlay = $null; Description = $null }
        $sync.TaskbarWritten = $last
    }

    if ($PSBoundParameters.ContainsKey('value')) {
        $last.Value = $value
        $sync["Form"].taskbarItemInfo.ProgressValue = $value
    }

    if ($state -and $state -ne $last.State) {
        $last.State = $state
        switch ($state) {
            'None' { $sync["Form"].taskbarItemInfo.ProgressState = "None" }
            'Indeterminate' { $sync["Form"].taskbarItemInfo.ProgressState = "Indeterminate" }
            'Normal' { $sync["Form"].taskbarItemInfo.ProgressState = "Normal" }
            'Error' { $sync["Form"].taskbarItemInfo.ProgressState = "Error" }
            'Paused' { $sync["Form"].taskbarItemInfo.ProgressState = "Paused" }
            default { throw "[Set-WinUtilTaskbarItem] Invalid state" }
        }
    }

    if ($overlay -and $overlay -ne $last.Overlay) {
        $last.Overlay = $overlay
        switch ($overlay) {
            'logo' {
                if (-not $sync["logorender"]) {
                    Initialize-WinUtilTaskbarOverlayAssets -IncludeLogo $true -IncludeStatusAssets $false
                }
                $sync["Form"].taskbarItemInfo.Overlay = $sync["logorender"]
            }
            'checkmark' {
                if (-not $sync["checkmarkrender"]) {
                    Initialize-WinUtilTaskbarOverlayAssets -IncludeLogo $false -IncludeStatusAssets $true
                }
                $sync["Form"].taskbarItemInfo.Overlay = $sync["checkmarkrender"]
            }
            'warning' {
                if (-not $sync["warningrender"]) {
                    Initialize-WinUtilTaskbarOverlayAssets -IncludeLogo $false -IncludeStatusAssets $true
                }
                $sync["Form"].taskbarItemInfo.Overlay = $sync["warningrender"]
            }
            'None' {
                $sync["Form"].taskbarItemInfo.Overlay = $null
            }
            default {
                if (Test-Path $overlay) {
                    $sync["Form"].taskbarItemInfo.Overlay = $overlay
                }
            }
        }
    }

    if ($description -and $description -ne $last.Description) {
        $last.Description = $description
        $sync["Form"].taskbarItemInfo.Description = $description
    }
}
