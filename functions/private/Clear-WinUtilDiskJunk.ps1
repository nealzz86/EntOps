function Clear-WinUtilDiskJunkDef {

    <#

    .SYNOPSIS
        Cleans one junk category and returns the bytes freed

    .DESCRIPTION
        Locked files are skipped rather than failing the pass. The update cache needs the
        Windows Update services stopped for the delete window; the recycle bin goes through
        the shell so per-drive hidden settings keep working.

    #>
    param([hashtable]$Def)

    $before = Measure-WinUtilDiskJunkDef -Def $Def

    if ($Def.Special -eq "Recycle") {
        Clear-RecycleBin -Force -ErrorAction SilentlyContinue
        return $before
    }

    $servicesStopped = @()
    if ($Def.Special -eq "Update") {
        foreach ($svcName in @("wuauserv", "bits", "dosvc")) {
            $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
            if ($svc -and $svc.Status -eq "Running") {
                Stop-Service -Name $svcName -Force -ErrorAction SilentlyContinue
                $servicesStopped += $svcName
            }
        }
    }

    try {
        foreach ($root in @($Def.Roots)) {
            foreach ($dir in @(Get-Item -Path $root -Force -ErrorAction SilentlyContinue)) {
                if (-not $dir.PSIsContainer) { continue }

                # Windows.old belongs to TrustedInstaller; ownership must move before an
                # administrator can delete it at all.
                if ($Def.Takeown) {
                    Append-WinUtilDiskLog -Message "$($Def.Name)：正在取得所有权（$($dir.FullName)），可能需要几分钟……"
                    & takeown.exe /F $dir.FullName /R /D Y 2>&1 | Out-Null
                    & icacls.exe $dir.FullName /GRANT "*S-1-5-32-544:(OI)(CI)F" /T /C /Q 2>&1 | Out-Null
                }

                Get-ChildItem -LiteralPath $dir.FullName -Force -ErrorAction SilentlyContinue | ForEach-Object {
                    Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        }
    } finally {
        foreach ($svcName in $servicesStopped) {
            Start-Service -Name $svcName -ErrorAction SilentlyContinue
        }
    }

    $after = Measure-WinUtilDiskJunkDef -Def $Def
    $freed = $before - $after
    if ($freed -lt 0) { $freed = 0 }
    return $freed
}
