function Invoke-WPFInstallUpgrade {
    <#

    .SYNOPSIS
        Upgrades every package that has an update available

    .DESCRIPTION
        Runs on the worker like any other package work, so the progress bar, the taskbar item
        and the log report it the same way an install does.

    #>

    # The radio button belongs to the interface thread; this body runs on a worker. The
    # preference it maintains carries the same answer and is what every other workflow reads.
    if ($sync.preferences.packagemanager -eq "Choco") {
        Step-WinUtilJob -Status "正在准备 Chocolatey" -State "Indeterminate"
        Install-WinUtilChoco

        Write-WinUtilLog -Component "Install" -Message "Upgrading all Chocolatey packages."
        Step-WinUtilJob -Status "正在升级所有 Chocolatey 包" -State "Indeterminate"

        # "all" is choco's own name for every installed package, so this stays one call
        $result = Measure-WinUtilStep -Scope "Install" -Name "choco upgrade all" -ScriptBlock {
            Install-WinUtilProgramChoco -Action Upgrade -Programs @("all")
        }
        Complete-WinUtilPackageRun -Action "Upgrade" -Results @($result)
        return
    }

    Step-WinUtilJob -Status "正在准备 WinGet" -State "Indeterminate"
    Install-WinUtilWinget

    Write-WinUtilLog -Component "Install" -Message "Upgrading all WinGet packages."
    Step-WinUtilJob -Status "正在升级所有 WinGet 包" -State "Indeterminate"

    # Let WinGet resolve every package against its recorded source. Parsing its localized,
    # width-truncated table loses identifiers and source information.
    $result = Measure-WinUtilStep -Scope "Install" -Name "winget upgrade --all" -ScriptBlock {
        Install-WinUtilProgramWinget -Action Upgrade -Programs @("all")
    }
    Complete-WinUtilPackageRun -Action "Upgrade" -Results @($result)
}
