function Invoke-WPFDiskAnaScan {

    <#

    .SYNOPSIS
        Starts a full drive scan for the disk analysis tab

    #>
    param([string]$Button)

    $selected = $null
    if ($sync.WPFDiskAnaDrive) { $selected = $sync.WPFDiskAnaDrive.SelectedItem }
    if (-not $selected) {
        $sync.WPFDiskAnaNote.Text = "请先选择要分析的磁盘。"
        return
    }

    $root = [string]$selected
    $sync.WPFDiskAnaPath.Text = "$root　·　扫描中……"
    $sync.WPFDiskAnaNote.Text = "正在后台扫描，完成后自动显示结果；扫描期间可切换页面。"

    Start-WinUtilJob -Name "磁盘分析" -Description "正在分析磁盘占用" -Parameters @{ Root = $root } -ScriptBlock {
        param($Root)
        try {
            Start-WinUtilDiskAnaScan -Root $Root
        } catch {
            Append-WinUtilDiskLog -Message "磁盘分析失败：$($_.Exception.Message)" -Level "ERROR"
        }
    }
}

function Invoke-WPFDiskAnaUp {

    <#

    .SYNOPSIS
        Moves one level up in the scanned directory tree

    #>
    param([string]$Button)

    $st = $sync.DiskAna
    if ($null -eq $st) {
        $sync.WPFDiskAnaNote.Text = "还没有扫描结果，请先「开始全盘扫描」。"
        return
    }

    $prefix = [string]$st.Prefix
    if ($prefix -eq "") { return }

    $i = $prefix.LastIndexOf("\")
    $newPrefix = if ($i -lt 0) { "" } else { $prefix.Substring(0, $i) }
    Show-WinUtilDiskAnalysis -Prefix $newPrefix
}

function Invoke-WPFDiskAnaDrill {

    <#

    .SYNOPSIS
        Drills into one scanned directory; called from the analysis row click handlers

    #>
    param([string]$RelPath)

    $st = $sync.DiskAna
    if ($null -eq $st -or -not $st.Dirs.ContainsKey($RelPath)) { return }

    Show-WinUtilDiskAnalysis -Prefix $RelPath
}
