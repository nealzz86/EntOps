function Get-WinUtilBaselineInstalledAppNames {

    <#

    .SYNOPSIS
        The display names of everything this machine has an uninstall record for

    .DESCRIPTION
        The three uninstall hives cover machine-wide, 32-bit and per-user installs, which is what
        a "必装软件有没有装上" check needs. Deliberately cheap: one registry read, no package
        manager call, so the checklist stays usable on a machine where winget is broken.

    #>

    $roots = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall"
    )

    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($root in $roots) {
        $entries = Get-ItemProperty -Path (Join-Path $root "*") -ErrorAction SilentlyContinue
        foreach ($entry in @($entries)) {
            if ($null -eq $entry) { continue }
            $display = [string]$entry.DisplayName
            if ([string]::IsNullOrWhiteSpace($display)) { continue }
            if ($display -match "^(更新|Update for|Security Update)") { continue }
            [void]$names.Add($display)
        }
    }

    return @($names | Sort-Object -Unique)
}

function Get-WinUtilBaselinePowerScheme {

    <#

    .SYNOPSIS
        The active power plan as a GUID plus the friendly name powercfg printed

    .DESCRIPTION
        powercfg writes its labels in the Windows display language, so the name is whatever the
        machine says and the GUID is the part a check can rely on.

    #>

    $text = ""
    try {
        $global:LASTEXITCODE = 0
        $text = @(powercfg /getactivescheme 2>&1 | Out-String)
    } catch {
        return @{ Guid = ""; Name = "" }
    }

    $text = [string]$text
    $guid = ""
    $name = ""
    if ($text -match "([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})") {
        $guid = $Matches[1].ToLower()
    }
    if ($text -match "\((.+?)\)\s*$") { $name = $Matches[1].Trim() }

    return @{ Guid = $guid; Name = $name }
}

function Get-WinUtilBaselineUpdatePolicy {

    <#

    .SYNOPSIS
        Whether Windows Update is managed by policy, and whether automatic updates are switched off

    #>

    $managed = $false
    $disabled = $false
    $auPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"

    try {
        $au = Get-ItemProperty -Path $auPath -ErrorAction SilentlyContinue
        if ($au) {
            $managed = ($null -ne $au.WUServer) -or ($au.PSObject.Properties.Name -contains "UseWUServer")
            if ([int]$au.NoAutoUpdate -eq 1) { $disabled = $true }
        }
    } catch { }

    if (-not $managed) {
        try {
            if (Test-Path -LiteralPath "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Update") { $managed = $true }
        } catch { }
    }

    return @{ Managed = $managed; Disabled = $disabled }
}

function Get-WinUtilBaselineShareFacts {

    <#

    .SYNOPSIS
        Reachability of every SMB share the print-and-share config declares, aggregated into one verdict

    .DESCRIPTION
        Only the configured paths are probed, never a scan of the network. The result carries names
        and errors, not credentials, so a failed check can explain itself in the UI.

    #>

    $shares = @($sync.configs.entprinters.shares)
    if ($shares.Count -eq 0) {
        return @{ SharePath = ""; ShareReachable = $null; ShareError = "未配置共享文件夹。" }
    }

    $unreachable = [System.Collections.Generic.List[string]]::new()
    $lastError = ""
    foreach ($share in $shares) {
        if ($null -eq $share) { continue }
        $path = [string]$share.Paths[0]
        $label = if ([string]::IsNullOrWhiteSpace([string]$share.Name)) { $path } else { [string]$share.Name }
        try {
            if (Test-Path -LiteralPath $path -ErrorAction Stop) { continue }
            [void]$unreachable.Add($label)
            $lastError = "路径不可访问：$path"
        } catch {
            [void]$unreachable.Add($label)
            $lastError = [string]$_.Exception.Message
        }
    }

    return @{
        SharePath      = (@($shares | ForEach-Object { [string]$_.Name } | Where-Object { $_ }) -join "、")
        ShareReachable = ($unreachable.Count -eq 0)
        ShareError     = if ($unreachable.Count -eq 0) { "" } else { "$($unreachable -join '、') 不可访问（$lastError）" }
    }
}

function Get-WinUtilBaselineFacts {

    <#

    .SYNOPSIS
        Reads everything the baseline checklist needs from this machine, once

    .DESCRIPTION
        Every probe is independent: whatever cannot be read is simply left out of the hashtable, so
        Test-WinUtilBaseline reports that item as 未知 instead of failing the whole check-up. Runs
        in the job thread, so nothing here may touch WPF controls.

    #>

    $facts = @{}

    try { $facts.ComputerName = [string]$Env:COMPUTERNAME } catch { }

    try {
        $system = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $facts.JoinedDomain = [string]$system.Domain
        $facts.IsDomainJoined = [bool]$system.PartOfDomain
    } catch { }

    try { $facts.TimeZoneId = [string][TimeZoneInfo]::Local.Id } catch { }

    $scheme = Get-WinUtilBaselinePowerScheme
    if ($scheme.Guid) { $facts.PowerScheme = $scheme.Guid }
    if ($scheme.Name) { $facts.PowerSchemeName = $scheme.Name }

    $update = Get-WinUtilBaselineUpdatePolicy
    $facts.UpdatesManaged = $update.Managed
    $facts.UpdatesDisabled = $update.Disabled

    try {
        $defender = Get-MpComputerStatus -ErrorAction Stop
        $facts.DefenderEnabled = [bool]$defender.RealTimeProtectionEnabled
    } catch {
        Write-WinUtilLog -Component "Baseline" -Level "WARN" -Message "Defender status unavailable: $($_.Exception.Message)"
    }

    try {
        $leftover = @(Get-WinUtilEntAVInstall | Where-Object { $_.Found } | ForEach-Object { [string]$_.Name })
        $facts.EntAVRemaining = $leftover
    } catch {
        Write-WinUtilLog -Component "Baseline" -Level "WARN" -Message "Enterprise AV probe failed: $($_.Exception.Message)"
    }

    try {
        $winrm = Get-Service -Name WinRM -ErrorAction Stop
        $facts.WinRMStatus = [string]$winrm.Status
    } catch {
        Write-WinUtilLog -Component "Baseline" -Level "WARN" -Message "WinRM service not readable: $($_.Exception.Message)"
    }

    try { $facts.InstalledAppNames = Get-WinUtilBaselineInstalledAppNames } catch {
        Write-WinUtilLog -Component "Baseline" -Level "WARN" -Message "Installed program list unreadable: $($_.Exception.Message)"
    }

    foreach ($entry in (Get-WinUtilBaselineShareFacts).GetEnumerator()) {
        $facts[$entry.Key] = $entry.Value
    }

    try {
        $systemDrive = (Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction Stop)
        if ($null -ne $systemDrive) {
            $facts.SystemDriveFreeGB = [math]::Round([double]$systemDrive.FreeSpace / 1GB, 1)
            $facts.SystemDriveTotalGB = [math]::Round([double]$systemDrive.Size / 1GB, 1)
        }
    } catch {
        Write-WinUtilLog -Component "Baseline" -Level "WARN" -Message "System drive size unreadable: $($_.Exception.Message)"
    }

    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $facts.IsAdmin = (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator
        )
    } catch { }

    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $facts.OSVersion = [string]$os.Caption
        $facts.OSArch = [string]$os.OSArchitecture
    } catch { }

    return $facts
}
