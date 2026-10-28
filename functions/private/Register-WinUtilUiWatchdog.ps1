function Register-WinUtilUiWatchdog {

    <#

    .SYNOPSIS
        Watches from outside the interface thread whether it still runs and whether it still draws

    .DESCRIPTION
        A window the user calls frozen has two very different causes. The interface thread can be
        inside a call that never returns - the taskbar and the print APIs are cross-process and have
        no timeout of their own - or the thread can be perfectly healthy while the display driver
        stopped handing frames to the screen. Both look identical from the outside, so a report that
        only says "frozen" cannot be acted on.

        The heartbeat measures the two separately: it posts a request for a frame and waits to see
        that request run, then checks whether a frame actually came back. A thread that does not
        answer is only reportable, so it goes in the log with the job and the progress text it was
        showing. A compositor that stops while the thread answers is repairable, and the round that
        proves it switches the process to software rendering.

        The loop runs on a runspace of its own, the way the overlay render does. A scriptblock handed
        to a plain .NET timer would be invoked on a foreign thread and takes the process down with
        it; a runspace executes its own scriptblocks on its own thread, which is the supported shape.

    .PARAMETER IntervalSeconds
        How often to take the temperature. Each round deliberately draws one frame to have something
        to count, so this is kept gentle - a forced repaint every five seconds.

    .PARAMETER StallSeconds
        How long the interface thread may ignore a posted frame request before it is called stalled

    #>
    param(
        [int]$IntervalSeconds = 5,
        [int]$StallSeconds = 6
    )

    if (-not (Test-WinUtilUIAlive)) { return }
    if ($sync.UiWatchdogShell) { return }

    $sync.UiRenderFrames = 0
    $sync.UiLastPing = $null
    $sync.UiOffScreen = $false
    $sync.UiWatchdogStalled = $false
    $sync.UiQuietTicks = 0

    # One render pass per frame the compositor starts. Visual.Rendered would say the same thing and
    # is unreachable from PowerShell because it is a protected event.
    $sync.UiFrameCounter = [System.EventHandler]{ $sync.UiRenderFrames++ }
    [System.Windows.Media.CompositionTarget]::add_Rendering($sync.UiFrameCounter)

    $sync.UiWatchdogStop = [System.Threading.ManualResetEvent]::new($false)

    $loop = {
        param($Watch)

        $stopEvent = $Watch.Stop
        $stallMs = $Watch.StallSeconds * 1000
        $roundMs = $Watch.IntervalSeconds * 1000

        while (-not $stopEvent.WaitOne($roundMs)) {
            try {
                if ($sync.ShuttingDown -or -not (Test-WinUtilUIAlive)) { continue }

                $framesBefore = $sync.UiRenderFrames
                $ping = [guid]::NewGuid().ToString()
                $sync.UiLastPing = $null

                # Invalidating on purpose is what tells "there was nothing new to draw" apart from
                # "drawing stopped working".
                Invoke-WPFUIThread -Async -Parameters @{ Ping = $ping } -ScriptBlock {
                    param($Ping)
                    $sync.Form.InvalidateVisual()
                    $sync.UiOffScreen = ($sync.Form.WindowState -ne [Windows.WindowState]::Normal)
                    $sync.UiLastPing = $Ping
                }

                $waited = 0
                while ($waited -lt $stallMs) {
                    if ($sync.UiLastPing -eq $ping) { break }
                    Start-Sleep -Milliseconds 200
                    $waited += 200
                }

                if ($sync.UiLastPing -ne $ping) {
                    if (-not $sync.UiWatchdogStalled) {
                        $sync.UiWatchdogStalled = $true
                        $task = if ($sync.ActiveJobLabel) { $sync.ActiveJobLabel } else { "空闲" }
                        Write-WinUtilLog -Level "ERROR" -Component "UI" -Message (
                            "界面线程 $([int]$Watch.StallSeconds) 秒没有处理排到它队列里的操作（当时任务：$task，最后一步：$($sync.LastStepStatus)）。" +
                            "画面会停在最后一帧、点击不生效，说明界面线程卡在了一个不返回的外部调用里（任务栏、打印服务这类跨进程调用没有超时）。")
                    }
                    continue
                }

                if ($sync.UiWatchdogStalled) {
                    $sync.UiWatchdogStalled = $false
                    Write-WinUtilLog -Level "WARN" -Component "UI" -Message "界面线程已恢复响应。"
                }

                # A window that is minimised or hidden is not expected to produce frames.
                if ($sync.UiOffScreen) {
                    $sync.UiQuietTicks = 0
                    continue
                }

                if ($sync.UiRenderFrames -le $framesBefore) {
                    $sync.UiQuietTicks++
                    if ($sync.UiQuietTicks -ge $Watch.Rounds -and -not $sync.SoftwareRender) {
                        $quietSeconds = $sync.UiQuietTicks * [int]$Watch.IntervalSeconds
                        $sync.UiQuietTicks = 0
                        Set-WinUtilRenderMode -Reason "界面线程正常，但连续约 $quietSeconds 秒没有渲染出一帧"
                    }
                } else {
                    $sync.UiQuietTicks = 0
                }
            } catch {
                Write-WinUtilLog -Level "WARN" -Component "UI" -Message "界面看门狗本轮检查失败：$($_.Exception.Message)"
            }
        }
    }

    $watch = @{
        Stop           = $sync.UiWatchdogStop
        IntervalSeconds = $IntervalSeconds
        StallSeconds    = $StallSeconds
        Rounds          = 2
    }

    $runspace = [runspacefactory]::CreateRunspace((New-WinUtilSessionState))
    $runspace.ThreadOptions = "ReuseThread"
    $runspace.Open()

    $shell = [powershell]::Create()
    $shell.Runspace = $runspace
    [void]$shell.AddScript($loop).AddParameter("Watch", $watch)

    $sync.UiWatchdogShell = $shell
    $sync.UiWatchdogRunspace = $runspace
    $sync.UiWatchdogHandle = $shell.BeginInvoke()
}

function Stop-WinUtilUiWatchdog {
    <#
        .SYNOPSIS
            Tells the interface heartbeat to stop

        .DESCRIPTION
            Only the stop signal is sent, and the frame counter is unhooked: nothing here waits for
            the loop thread, because this runs on the interface thread and waiting on a thread that
            may be inside a stalled dispatcher check is exactly how a shutdown becomes a freeze.
            The runspace is left for the process to reclaim on the way out.
    #>

    $stop = $sync.UiWatchdogStop
    $sync.UiWatchdogStop = $null
    if ($stop) {
        try { $null = $stop.Set() } catch { }
    }

    $counter = $sync.UiFrameCounter
    $sync.UiFrameCounter = $null
    if ($counter) {
        try { [System.Windows.Media.CompositionTarget]::remove_Rendering($counter) } catch { }
    }
}
