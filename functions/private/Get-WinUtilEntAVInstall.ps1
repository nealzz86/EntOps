function Resolve-WinUtilEntCleanPath {

    <#

    .SYNOPSIS
        Expands the $PFX86 / $PF / $PD tokens used by entclean.json into absolute paths

    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $map = @{
        '$PFX86' = [Environment]::GetFolderPath('ProgramFilesX86')
        '$PF'    = [Environment]::GetFolderPath('ProgramFiles')
        '$PD'    = [Environment]::GetFolderPath('CommonApplicationData')
    }
    foreach ($token in $map.Keys) {
        if ($Path.StartsWith($token, [StringComparison]::OrdinalIgnoreCase)) {
            $Path = $map[$token] + $Path.Substring($token.Length)
            break
        }
    }
    return [System.Environment]::ExpandEnvironmentVariables($Path)
}

function Get-WinUtilEntAVInstall {

    <#

    .SYNOPSIS
        Detects whether each entclean.json product is present on this machine

    .DESCRIPTION
        Looks at the three uninstall registries, the configured install directories and the
        running processes. Returns one object per product: Key, Name, Found, Evidence,
        UninstallEntry (DisplayName + UninstallString + registry path when found).

    #>
    param(
        [int]$Limit = 3
    )

    $products = @($sync.configs.entclean.products)
    $uninstallRoots = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall"
    )
    $uninstallEntries = @()
    foreach ($root in $uninstallRoots) {
        if (-not (Test-Path $root)) { continue }
        $uninstallEntries += @(Get-ChildItem $root -ErrorAction SilentlyContinue | ForEach-Object {
            $p = Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue
            if ($p -and $p.DisplayName) {
                [pscustomobject]@{
                    DisplayName = [string]$p.DisplayName
                    UninstallString = [string]$p.UninstallString
                    QuietUninstallString = [string]$p.QuietUninstallString
                    RegPath = $_.PSPath
                }
            }
        })
    }

    $running = @()
    try {
        $running = @(Get-Process -ErrorAction SilentlyContinue | ForEach-Object {
            $n = $_.ProcessName
            $ext = ""
            try { if ($_.Path) { $ext = $_.Path } } catch { }
            if ($n) { [pscustomobject]@{ Name = $n; Path = $ext } }
        })
    } catch { }

    foreach ($product in $products) {
        $evidence = @()
        $entryHits = @($uninstallEntries | Where-Object { $_.DisplayName -imatch $product.displayNameRegex })
        foreach ($e in $entryHits) { $evidence += "卸载注册表：$($e.DisplayName)" }

        $dirs = @($product.installDirs | ForEach-Object { Resolve-WinUtilEntCleanPath $_ } | Where-Object { Test-Path -LiteralPath $_ })
        foreach ($d in $dirs) { $evidence += "安装目录：$d" }

        $procHits = @($running | Where-Object {
            $byName = $product.processNames -contains ($_.Name + ".exe")
            $byPath = $false
            if ($_.Path) {
                foreach ($d in ($product.installDirs | ForEach-Object { Resolve-WinUtilEntCleanPath $_ })) {
                    if ($d.Length -gt 3 -and $_.Path.StartsWith($d, [StringComparison]::OrdinalIgnoreCase)) { $byPath = $true; break }
                }
            }
            $byName -or $byPath
        })
        foreach ($pr in ($procHits | Select-Object -First $Limit)) { $evidence += "运行进程：$($pr.Name)" }

        [pscustomobject]@{
            Key           = $product.key
            Name          = $product.name
            Found         = ($evidence.Count -gt 0)
            Evidence      = $evidence
            UninstallEntry = if ($entryHits.Count -gt 0) { $entryHits[0] } else { $null }
        }
    }
}
