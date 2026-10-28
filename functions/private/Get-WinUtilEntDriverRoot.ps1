function Get-WinUtilEntDriverRoot {

    <#

    .SYNOPSIS
        Locates the folder that holds driver.zip / driver2.zip for the enterprise printer tab

    .DESCRIPTION
        The compiled script is distributed next to a drivers folder, but it can also be copied
        anywhere else on its own. Search order: explicit override variable, the environment
        variable, the script's own directory, the current directory.

    #>

    $candidates = @()
    if ($global:WinUtilEntDriverRoot) { $candidates += $global:WinUtilEntDriverRoot }
    $envRoot = [Environment]::GetEnvironmentVariable("WINUTIL_ENT_DRIVERS")
    if ($envRoot) { $candidates += $envRoot }

    if ($PSCommandPath) { $candidates += (Split-Path -Parent $PSCommandPath) }
    $candidates += (Get-WinUtilAppBaseDir)
    $candidates += (Get-Location).Path

    $subDirs = @(".", "drivers", "driver")
    if ($sync -and $sync.configs -and $sync.configs.entprinters) {
        $subDirs = @(".") + @($sync.configs.entprinters.driverDirNames)
    }

    foreach ($root in $candidates) {
        if (-not $root -or -not (Test-Path -LiteralPath $root)) { continue }
        foreach ($sub in $subDirs) {
            $dir = Join-Path $root $sub
            if ((Test-Path -LiteralPath (Join-Path $dir "driver.zip")) -or
                (Test-Path -LiteralPath (Join-Path $dir "driver2.zip"))) {
                return (Resolve-Path -LiteralPath $dir).Path
            }
        }
    }
    return $null
}
