function Get-WinUtilAppBaseDir {

    <#

    .SYNOPSIS
        Folder the tool was launched from: script directory, packaged exe directory, or cwd

    #>

    # A packaged exe unpacks its drivers and tools next to nothing on disk, so once that cache
    # exists it is the base directory the side-by-side lookups should resolve against
    if ($sync -and $sync.PayloadDir -and (Test-Path -LiteralPath $sync.PayloadDir)) {
        return $sync.PayloadDir
    }

    if ($PSScriptRoot) { return $PSScriptRoot }
    try {
        $boot = [Environment]::GetCommandLineArgs()[0]
        if ($boot -and (Test-Path -LiteralPath $boot)) {
            $parent = Split-Path -Parent $boot
            if ($parent) { return $parent }
        }
    } catch { }
    return (Get-Location).Path
}
