function Set-WinUtilRegistryComboState {
    <#
    .SYNOPSIS
        Applies and verifies a config-defined registry combo-box state.

    .PARAMETER Registry
        Registry settings containing a value mapping for each supported state.

    .PARAMETER State
        The state name to apply.
    #>
    param(
        [Parameter(Mandatory)]
        $Registry,

        [Parameter(Mandatory)]
        [string]$State
    )

    if ($Registry[0].Values.PSObject.Properties.Name -notcontains $State) {
        throw "未知的注册表状态「$State」。"
    }

    # Preserve exact prior values so a partial update can be rolled back.
    $previousValues = foreach ($setting in @($Registry)) {
        $currentValue = Get-WinUtilRegistryComboValue -Setting $setting
        [pscustomobject]@{ Setting = $setting; Exists = $currentValue.Exists; Value = $currentValue.Value }
    }

    try {
        foreach ($setting in @($Registry)) {
            $configuredValue = $setting.Values.PSObject.Properties[$State].Value
            $previousValue = $previousValues | Where-Object Setting -EQ $setting
            if ($configuredValue -ne "<RemoveEntry>" -or $previousValue.Exists) {
                Set-WinUtilRegistry -Name $setting.Name -Path $setting.Path -Type $setting.Type -Value $configuredValue
            }
        }

        # Set-WinUtilRegistry reports write errors without throwing, so verify each result explicitly.
        foreach ($setting in @($Registry)) {
            $configuredValue = $setting.Values.PSObject.Properties[$State].Value
            $currentValue = Get-WinUtilRegistryComboValue -Setting $setting
            $writeMatches = if ($configuredValue -eq "<RemoveEntry>") {
                -not $currentValue.Exists
            } else {
                $currentValue.Exists -and [string]$currentValue.Value -eq [string]$configuredValue
            }
            if (-not $writeMatches) {
                throw "写入后的注册表值与所选状态不一致。"
            }
        }
    } catch {
        $applyError = $_.Exception.Message
        if ([string]::IsNullOrWhiteSpace($applyError)) {
            $applyError = "写入后的注册表值与所选状态不一致。"
        }
        $rollbackFailed = $false
        foreach ($previousValue in $previousValues) {
            try {
                $currentValue = Get-WinUtilRegistryComboValue -Setting $previousValue.Setting
                if ($previousValue.Exists -or $currentValue.Exists) {
                    $rollbackValue = if ($previousValue.Exists) { $previousValue.Value } else { "<RemoveEntry>" }
                    Set-WinUtilRegistry -Name $previousValue.Setting.Name -Path $previousValue.Setting.Path -Type $previousValue.Setting.Type -Value $rollbackValue
                }
                $restoredValue = Get-WinUtilRegistryComboValue -Setting $previousValue.Setting
                if ($restoredValue.Exists -ne $previousValue.Exists -or ($restoredValue.Exists -and [string]$restoredValue.Value -ne [string]$previousValue.Value)) {
                    $rollbackFailed = $true
                }
            } catch {
                $rollbackFailed = $true
            }
        }
        if ($rollbackFailed) {
            throw "无法应用注册表状态「$State」，原有注册表状态也未能恢复：$applyError"
        }
        throw "无法应用注册表状态「$State」：$applyError"
    }
}
