function Invoke-WinUtilCloseRequest {
    <#
        .SYNOPSIS
            Asks what to do about work that is still running when the window is closed

        .DESCRIPTION
            A half finished install or tweak run is not ended without asking. Either it finishes
            without the window, reporting to the console and then exiting, or it is stopped and
            everything closes now.

        .PARAMETER RunningJob
            The name of the job in flight, so the question names what is at stake.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$RunningJob
    )

    # The question carries the meaning rather than naming buttons: Windows labels them in its own
    # language, so "Yes" in the text would not match a button reading "Ja".
    $answer = Show-WinUtilMessage -Button "YesNoCancel" -Icon "Warning" -Title "「$RunningJob」仍在运行" -Message @"
$RunningJob 尚未完成。

是否关闭窗口，让它在控制台中继续执行？

完成后 WinUtil 会自动退出。若不这样做，任务将被
停止并立即全部关闭。选择「取消」可保持 WinUtil 打开。
"@

    switch ("$answer") {
        "Yes" {
            Write-WinUtilLog -Component "UI" -Message "Close requested: closing the window, $RunningJob continues in the console."
            $sync.FinishInConsole = $true
            $sync.ForceClose = $true

            Write-Host ""
            Write-Host "WinUtil 窗口已关闭。$RunningJob 仍在此处运行，完成后本窗口将自动关闭。" -ForegroundColor Cyan
            Write-Host ""

            # Posted rather than closed from inside the handler that is already unwinding
            Request-WinUtilWindowClose
        }
        "No" {
            Write-WinUtilLog -Component "UI" -Message "Close requested: stopping $RunningJob."
            Step-WinUtilJob -Status "正在停止 $RunningJob" -State "Indeterminate"
            $sync.ForceClose = $true

            # Close the window first. The main thread owns pool shutdown after ShowDialog
            # returns, so the worker can finish its UI-dispatching finally block before the UI
            # runspace is disposed. Waiting for it here would deadlock the dispatcher.
            Request-WinUtilWindowClose
        }
        default {
            Write-WinUtilLog -Component "UI" -Message "Close cancelled, $RunningJob is still running."
        }
    }
}

function Request-WinUtilWindowClose {
    <#
        .SYNOPSIS
            Closes the window from outside the handler that is currently cancelling the close

    #>
    if (-not (Test-WinUtilUIAlive)) {
        return
    }

    $sync.Form.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [action]{
        $sync.Form.Close()
    }) | Out-Null
}

function Wait-WinUtilRemainingWork {
    <#
        .SYNOPSIS
            Waits for work that outlived the window, reporting to the console

        .DESCRIPTION
            Runs on the main thread once the interface has gone. The job is still on the worker
            pool and keeps logging, so this only waits and keeps the wait visible.

        .PARAMETER TimeoutMinutes
            Upper bound, so a worker that never returns cannot keep the process alive.
    #>
    param(
        # Double rather than int: an int silently truncates a fractional value to zero, which
        # turns the bound into "do not wait at all"
        [double]$TimeoutMinutes = 120
    )

    if (-not $sync.FinishInConsole -or -not $sync.ActiveJob) {
        return
    }

    $job = $sync.ActiveJob
    Write-WinUtilLog -Component "UI" -Message "Window closed, waiting for $job to finish."
    Write-Host "Waiting for $job to finish..." -ForegroundColor Cyan

    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sync.ActiveJob -and $clock.Elapsed.TotalMinutes -lt $TimeoutMinutes) {
        Start-Sleep -Milliseconds 250
    }

    # The job's last progress line is still open, so anything after it needs a fresh line
    Complete-WinUtilConsoleProgress

    if ($sync.ActiveJob) {
        Write-WinUtilLog -Level "WARN" -Component "UI" -Message "$job did not finish within $TimeoutMinutes minutes, exiting anyway."
        Write-Host "$job is taking longer than $TimeoutMinutes minutes. Exiting." -ForegroundColor Yellow
        return
    }

    Write-WinUtilLog -Component "UI" -Message "$job finished after the window closed, in $([int]$clock.Elapsed.TotalSeconds)s."
    Write-Host "$job finished. Closing." -ForegroundColor Green
}
