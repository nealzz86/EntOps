function Initialize-WinUtilDiskAnaPanel {

    <#

    .SYNOPSIS
        Fills the disk analysis tab: drive overview rows and the drive selector

    #>

    $panel = $sync.WPFDiskAnaDrives
    $combo = $sync.WPFDiskAnaDrive
    if ($null -eq $panel -or $null -eq $combo) { return }

    $panel.Children.Clear()
    $combo.Items.Clear()

    $systemDrive = $env:SystemDrive.TrimEnd("\")

    foreach ($drive in [System.IO.DriveInfo]::GetDrives()) {
        if ($drive.DriveType -ne "Fixed" -or -not $drive.IsReady) { continue }

        $letter = $drive.Name.TrimEnd("\")
        $usedBytes = $drive.TotalSize - $drive.TotalFreeSpace
        $fraction = 0
        if ($drive.TotalSize -gt 0) { $fraction = $usedBytes / $drive.TotalSize }

        $label = "$letter"
        if ($letter -eq $systemDrive) { $label = "$letter（系统）" }
        $sizeText = "已用 {0:N0} GB / 共 {1:N0} GB · 剩余 {2:N0} GB" -f (
            [Math]::Round($usedBytes / 1GB, 0), [Math]::Round($drive.TotalSize / 1GB, 0), [Math]::Round($drive.TotalFreeSpace / 1GB, 0))

        Add-WinUtilDiskAnaRow -Target $panel -Label $label -SizeText $sizeText -Fraction $fraction `
            -ToolTip "$letter 已用 $([Math]::Round($fraction * 100, 1))%" -OnClick $null

        $combo.Items.Add("$letter\") | Out-Null
        if ($letter -eq $systemDrive) { $combo.SelectedIndex = $combo.Items.Count - 1 }
    }

    if ($combo.SelectedIndex -lt 0 -and $combo.Items.Count -gt 0) { $combo.SelectedIndex = 0 }

    if ($sync.DiskAna) {
        Show-WinUtilDiskAnalysis -Prefix ([string]$sync.DiskAna.Prefix)
    }
}
