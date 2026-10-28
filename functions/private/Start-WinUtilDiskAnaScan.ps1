function Start-WinUtilDiskAnaScan {

    <#

    .SYNOPSIS
        Walks one drive once and aggregates the size of every directory into $sync.DiskAna

    .DESCRIPTION
        Runs inside a background job. Direct child entries are pulled per directory so
        reparse points (junctions, mount points) can be skipped: Windows ships directory
        loops like C:\Users\All Users, and a naive -Recurse walk would follow them forever.
        Only direct file bytes are accumulated per folder during the walk, then rolled up
        to every ancestor in a second pass, which keeps the hot loop to one hashtable add
        per file.

    #>
    param([string]$Root)

    Append-WinUtilDiskLog -Message "磁盘分析开始扫描 $Root （大磁盘可能需要几分钟）"

    $rootTrim = $Root.TrimEnd("\")
    $prefixLen = $rootTrim.Length + 1
    $direct = @{}
    $counts = @{}
    $total = [long]0
    $fileCount = 0
    $dirCount = 0
    $top = New-Object System.Collections.Generic.List[hashtable]

    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($Root)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    while ($stack.Count -gt 0) {
        $current = $stack.Pop()
        $dirCount++

        if (-not $direct.ContainsKey($current)) { $direct[$current] = [long]0 }

        foreach ($item in @(Get-ChildItem -LiteralPath $current -Force -ErrorAction SilentlyContinue)) {
            if ($item.PSIsContainer) {
                if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
                $stack.Push($item.FullName)
                continue
            }

            $len = [long]$item.Length
            $direct[$current] += $len
            if (-not $counts.ContainsKey($current)) { $counts[$current] = 0 }
            $counts[$current]++
            $total += $len
            $fileCount++

            if ($len -gt 50MB) {
                $top.Add(@{ Path = $item.FullName; Bytes = $len })
                if ($top.Count -gt 1200) {
                    $keep = @($top | Sort-Object -Property Bytes -Descending | Select-Object -First 300)
                    $top.Clear()
                    foreach ($k in $keep) { $top.Add($k) }
                }
            }
        }

        if ($dirCount % 1000 -eq 0) {
            $pct = [Math]::Min(95, 5 + [int]($sw.Elapsed.TotalSeconds / 2))
            Step-WinUtilJob -Status "磁盘分析：已扫描 $dirCount 个目录 / $fileCount 个文件" -Percent $pct
        }
    }

    # Roll direct bytes up to every ancestor; keys move from full paths to drive-relative.
    $dirs = @{}
    $dirFileCounts = @{}
    foreach ($full in @($direct.Keys)) {
        $bytes = $direct[$full]
        $cnt = 0
        if ($counts.ContainsKey($full)) { $cnt = $counts[$full] }

        if ($full.Length -ge $prefixLen) { $rel = $full.Substring($prefixLen) } else { $rel = "" }

        $p = $rel
        while ($true) {
            if (-not $dirs.ContainsKey($p)) { $dirs[$p] = [long]0 }
            $dirs[$p] += $bytes
            if (-not $dirFileCounts.ContainsKey($p)) { $dirFileCounts[$p] = 0 }
            $dirFileCounts[$p] += $cnt
            if ($p -eq "") { break }
            $i = $p.LastIndexOf("\")
            if ($i -lt 0) { $p = "" } else { $p = $p.Substring(0, $i) }
        }
    }

    $topList = @($top | Sort-Object -Property Bytes -Descending | Select-Object -First 300)
    foreach ($entry in $topList) {
        if ($entry.Path.Length -ge $prefixLen) { $entry.Rel = $entry.Path.Substring($prefixLen) } else { $entry.Rel = $entry.Path }
    }

    $sync.DiskAna = @{
        Root      = $Root
        RootTrim  = $rootTrim
        Dirs      = $dirs
        Counts    = $dirFileCounts
        Top       = $topList
        Total     = $total
        FileCount = $fileCount
        DirCount  = $dirCount
        Seconds   = [Math]::Round($sw.Elapsed.TotalSeconds, 1)
        Prefix    = ""
    }

    Append-WinUtilDiskLog -Message "磁盘分析完成：$Root 共 $fileCount 个文件 / $dirCount 个目录，合计 $(Format-WinUtilJunkSize $total)，耗时 $($sync.DiskAna.Seconds) 秒。"

    Invoke-WPFUIThread -Parameters @{ Prefix = "" } -ScriptBlock {
        param($Prefix)
        Show-WinUtilDiskAnalysis -Prefix $Prefix
    }
}
