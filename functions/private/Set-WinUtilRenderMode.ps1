function Set-WinUtilRenderMode {

    <#

    .SYNOPSIS
        Decides how WPF gets its pixels, and uses the CPU when the session is remote

    .DESCRIPTION
        On a console machine WPF composites through the video driver. Over remote desktop, and on
        most virtual machines, that driver is a shared throttled pipe: the process stays alive and
        its interface thread keeps answering, but the screen holds the last frame it was ever
        handed, which is exactly what a user reports as "the whole window froze and clicking does
        nothing". Drawing in software costs a little CPU and cannot stall on a driver.

        A remote session is recognised from SESSIONNAME, which the terminal-services redirector
        sets for the interactive session it created. ENTOPS_SOFTWARE_RENDER=0 opts a machine out
        when its remote driver is known to be healthy.

    .PARAMETER Reason
        Text recorded in the log for why software rendering was chosen. Setting it forces the
        switch even on a console session, which is what the interface watchdog does when frames
        stop arriving while the thread is fine.

    #>
    param([string]$Reason = "")

    if ($env:ENTOPS_SOFTWARE_RENDER -eq "0") { return }

    $session = [string]$env:SESSIONNAME
    $remote = $session -and $session -notmatch "^(Console|Services)"
    if (-not $remote -and -not $Reason) { return }

    try {
        # ProcessRenderMode is typed by System.Windows.Interop.RenderMode, not an enum under Media
        [System.Windows.Media.RenderOptions]::ProcessRenderMode = [System.Windows.Interop.RenderMode]::SoftwareOnly
        $sync.SoftwareRender = $true
        Write-WinUtilLog -Component "UI" -Message (
            "已改用软件渲染（{0}）。远程桌面/虚拟机的显卡加速通道会把画面卡成最后一帧，CPU 合成不会。" -f $(
                if ($Reason) { $Reason } else { "远程会话 $session" }))
    } catch {
        Write-WinUtilLog -Level "WARN" -Component "UI" -Message "切换软件渲染失败：$($_.Exception.Message)"
    }
}
