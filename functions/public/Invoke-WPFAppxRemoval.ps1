function Invoke-WPFAppxRemoval {
    <#

    .SYNOPSIS
        Removes the selected AppX packages

    #>

    if ($null -eq $sync.selectedAppx -or $sync.selectedAppx.Count -eq 0) {
        Show-WinUtilMessage -Message "未选择 AppX 软件包" -Title "错误" -Button "OK" -Icon "Error"
        return
    }

    Start-WinUtilJob -Name "AppX" -Description "正在移除 AppX 包" -Parameters @{
        Selected = @($sync.selectedAppx)
        Apps = $sync.configs.appxHashtable
    } -ScriptBlock {
        param($Selected, $Apps)

        $total = @($Selected).Count
        $packageList = [System.Collections.Generic.List[string]]::new()
        Write-WinUtilLog -Component "AppX" -Message "Starting AppX removal for $total selected package(s)."

        for ($index = 0; $index -lt $total; $index++) {
            $key = $Selected[$index]
            $app = $Apps[$key]
            $position = $index + 1
            Step-WinUtilJob -Status "正在移除 $($app.Content)（$position/$total）" -Percent ([int](($index / $total) * 90))

            if ($key -eq "WPFAppxMicrosoft_XboxGamingOverlay") {
                # Making sure Game Bar isn't running
                Write-WinUtilLog -Component "AppX" -Message "Stopping GameBarFTServer before removing Xbox Gaming Overlay."
                Stop-Process -Name GameBarFTServer -Force -Confirm:$false -ErrorAction SilentlyContinue

                # This stops annoying ms-gamebar popup when launching games.
                Write-WinUtilLog -Component "AppX" -Message "Disabling Game DVR capture before removing Xbox Gaming Overlay."
                Set-ItemProperty -Path HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR -Name AppCaptureEnabled -Value 0
            }

            if ($key -eq "WPFAppxMicrosoft_WindowsNotepad") {
                Write-WinUtilLog -Component "AppX" -Message "Stopping dllhost before removing Notepad."
                Stop-Process -Name dllhost -Force -Confirm:$false -ErrorAction SilentlyContinue
            }

            Write-Host "Removing $($app.Content)"
            Write-WinUtilLog -Component "AppX" -Message "Removing $($app.Content) ($($app.PackageId))."
            Remove-WinUtilAPPX -Name $app.PackageId
            $packageList.Add($app.PackageId)

            if ($key -eq "WPFAppxMSTeams") {
                # Uninstalls Microsoft Teams Meeting Add-in for Microsoft Office
                Write-WinUtilLog -Component "AppX" -Message "Uninstalling Microsoft Teams meeting add-in package."
                Get-Package -Name "Microsoft Teams*" -ErrorAction SilentlyContinue | Uninstall-Package -Force
            }

            Step-WinUtilJob -Status "已移除 $($app.Content)（$position/$total）" -Percent ([int](($position / $total) * 90))
        }

        if ($packageList.Count -gt 0) {
            Step-WinUtilJob -Status "正在移除预配的 AppX 包" -Percent 90
            Remove-WinUtilProvisionedAPPX -PackageList $packageList.ToArray()
        }
    }
}
