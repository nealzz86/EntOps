function Write-WinUtilEntCleanLog {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    Write-WinUtilLog -Level $Level -Component "Security" -Message $Message
    Write-Host "  [$Level] $Message"
}

function Stop-WinUtilEntCleanProcesses {
    <#
        .SYNOPSIS
            Kills the product's processes by configured name or image path
    #>
    param($Product)

    $dirs = @($Product.installDirs | ForEach-Object { Resolve-WinUtilEntCleanPath $_ })
    $victims = @()
    try {
        $victims = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
            $byName = $Product.processNames -contains ($_.ProcessName + ".exe")
            $byPath = $false
            try {
                if ($_.Path) {
                    foreach ($d in $dirs) {
                        if ($d.Length -gt 3 -and $_.Path.StartsWith($d, [StringComparison]::OrdinalIgnoreCase)) { $byPath = $true; break }
                    }
                }
            } catch { }
            $byName -or $byPath
        })
    } catch { }

    foreach ($proc in $victims) {
        [void](Invoke-WinUtilEntCmd "taskkill /F /T /PID $($proc.Id)" 8000)
        Write-WinUtilEntCleanLog "已结束进程 $($proc.ProcessName) (PID $($proc.Id))"
    }
    if ($victims.Count -gt 0) { Start-Sleep -Milliseconds 500 }
}

function Remove-WinUtilEntCleanServices {
    <#
        .SYNOPSIS
            Disables, stops and deletes services/drivers whose binary lives under the product dirs
    #>
    param([string[]]$Dirs)

    $items = @()
    try { $items += @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Select-Object Name, State, PathName, @{n='Kind';e={'Service'}}) } catch { }
    try { $items += @(Get-CimInstance Win32_SystemDriver -ErrorAction SilentlyContinue | Select-Object Name, State, PathName, @{n='Kind';e={'Driver'}}) } catch { }

    foreach ($item in $items) {
        if (-not $item.PathName) { continue }
        $img = $item.PathName -replace '^\\\?\?\\', ''
        $img = [System.Environment]::ExpandEnvironmentVariables($img.Trim('"'))
        $hit = $false
        foreach ($d in $Dirs) {
            if ($d.Length -gt 3 -and $img.StartsWith($d, [StringComparison]::OrdinalIgnoreCase)) { $hit = $true; break }
        }
        if (-not $hit) { continue }

        Write-WinUtilEntCleanLog "移除$($item.Kind)：$($item.Name)（$img）"
        try { Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$($item.Name)" -Name Start -Value 4 -Force -ErrorAction Stop } catch { }
        if ($item.State -eq "Running") {
            [void](Invoke-WinUtilEntCmd "sc stop $($item.Name)" 10000)
        }
        [void](Invoke-WinUtilEntCmd "sc delete $($item.Name)" 10000)
    }
}

function Invoke-WinUtilEntCleanVendorUninstall {
    <#
        .SYNOPSIS
            Runs the vendor's own uninstaller with a timeout, best effort
    #>
    param($Product, $Entry)

    $cmd = if ($Entry.QuietUninstallString) { $Entry.QuietUninstallString } else { $Entry.UninstallString }
    if ([string]::IsNullOrWhiteSpace($cmd)) { return }
    $exe = $cmd.Trim()
    if ($exe -imatch '\.exe"?\s*$') {
        # Bare (or quoted) executable without arguments: add the vendor's silent switch
        $exe = $exe + " " + @($Product.silentUninstallArgs)[0]
    }
    Write-WinUtilEntCleanLog "尝试官方卸载程序：$exe"
    $out = Invoke-WinUtilEntCmd $exe 180000
    if ($out) { Write-WinUtilEntCleanLog "卸载程序输出：$($out.Trim())" }
}

function Remove-WinUtilEntCleanDirTree {
    <#
        .SYNOPSIS
            takeown + icacls + rd a directory; returns $true when it is gone
    #>
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $true }
    [void](Invoke-WinUtilEntCmd "takeown /f `"$Path`" /r /d y" 180000)
    [void](Invoke-WinUtilEntCmd "icacls `"$Path`" /grant *S-1-5-32-544:F /T /C /Q" 180000)
    [void](Invoke-WinUtilEntCmd "rd /s /q `"$Path`"" 180000)
    return -not (Test-Path -LiteralPath $Path)
}

function Remove-WinUtilEntCleanAllUserData {
    <#
        .SYNOPSIS
            Deletes the product's per-user data folders under every user profile
    #>
    param($Product)

    if (-not $Product.userDataDirs -or @($Product.userDataDirs).Count -eq 0) { return }
    $profilesRoot = Split-Path ([Environment]::GetFolderPath('UserProfile')) -Parent
    $skip = @("Public", "Default", "Default User", "All Users", "defaultuser0", "WDAGUtilityAccount")
    foreach ($profile in (Get-ChildItem $profilesRoot -Directory -Force -ErrorAction SilentlyContinue)) {
        if ($profile.Name -in $skip -or $profile.Name.StartsWith("Default.")) { continue }
        foreach ($rel in $Product.userDataDirs) {
            $p = Join-Path $profile.FullName $rel
            if (Test-Path -LiteralPath $p) {
                if (Remove-WinUtilEntCleanDirTree $p) {
                    Write-WinUtilEntCleanLog "已删除用户数据目录 $p"
                } else {
                    Write-WinUtilEntCleanLog "未能删除 $p" "WARN"
                    $script:EntCleanPending += $p
                }
            }
        }
    }
}

function Remove-WinUtilEntCleanRegistry {
    <#
        .SYNOPSIS
            Deletes product registry keys, uninstall table entries and autostart values
    #>
    param($Product, [string[]]$Dirs)

    foreach ($key in $Product.registryKeys) {
        if (Test-Path $key) {
            Remove-Item -Path $key -Recurse -Force -ErrorAction SilentlyContinue
            Write-WinUtilEntCleanLog "已删除注册表键 $key"
        }
    }

    $runRoots = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\RunOnce",
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run",
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce"
    )
    foreach ($root in $runRoots) {
        if (-not (Test-Path $root)) { continue }
        $props = (Get-Item $root).GetValueNames()
        foreach ($name in $props) {
            $data = [string](Get-ItemProperty -Path $root -Name $name).$name
            foreach ($d in $Dirs) {
                if ($d.Length -gt 3 -and $data -imatch [regex]::Escape($d)) {
                    Remove-ItemProperty -Path $root -Name $name -Force -ErrorAction SilentlyContinue
                    Write-WinUtilEntCleanLog "已删除自启动项 $root\$name"
                    break
                }
            }
        }
    }

    foreach ($root in @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall"
    )) {
        if (-not (Test-Path $root)) { continue }
        Get-ChildItem $root -ErrorAction SilentlyContinue | ForEach-Object {
            $p = Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue
            if (-not $p) { return }
            $byName = ([string]$p.DisplayName) -imatch $Product.displayNameRegex
            $byPath = $false
            foreach ($u in @([string]$p.UninstallString, [string]$p.InstallLocation, [string]$p.QuietUninstallString)) {
                foreach ($d in $Dirs) {
                    if ($d.Length -gt 3 -and $u -imatch [regex]::Escape($d)) { $byPath = $true; break }
                }
                if ($byPath) { break }
            }
            if ($byName -or $byPath) {
                Remove-Item -Path $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue
                Write-WinUtilEntCleanLog "已删除卸载表项 $($_.PSChildName)"
            }
        }
    }
}

function Remove-WinUtilEntCleanTasks {
    <#
        .SYNOPSIS
            Unregisters scheduled tasks whose action points into a product directory
    #>
    param([string[]]$Dirs)

    try {
        Get-ScheduledTask -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.TaskPath -like "\Microsoft\*") { return }
            $bad = @($_.Actions | Where-Object {
                $exe = [string]$_.Execute
                foreach ($d in $Dirs) {
                    if ($d.Length -gt 3 -and $exe.StartsWith($d, [StringComparison]::OrdinalIgnoreCase)) { return $true }
                }
                return $false
            })
            if ($bad.Count -gt 0) {
                Unregister-ScheduledTask -TaskName $_.TaskName -TaskPath $_.TaskPath -Confirm:$false -ErrorAction SilentlyContinue
                Write-WinUtilEntCleanLog "已删除计划任务 $($_.TaskPath)$($_.TaskName)"
            }
        }
    } catch { }
}

function Set-WinUtilEntCleanRunOnce {
    <#
        .SYNOPSIS
            Writes a boot-time cleanup batch for still-locked paths and registers RunOnce
    #>
    param([string[]]$Paths)

    if (-not $Paths -or @($Paths).Count -eq 0) { return $false }
    $bat = Join-Path (Join-Path $env:SystemRoot "Temp") ("EntOpsAVClean_{0}.cmd" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
    $lines = @()
    $lines += "@echo off"
    $lines += "@chcp 65001 >nul"
    $lines += "@echo cleanup started %date% %time% > `"$env:SystemRoot\Temp\EntOpsAVClean.log`""
    foreach ($p in (@($Paths) | Select-Object -Unique)) {
        $lines += "@takeown /f `"$p`" /r /d y >> `"$env:SystemRoot\Temp\EntOpsAVClean.log`" 2>&1"
        $lines += "@icacls `"$p`" /grant *S-1-5-32-544:F /T /C /Q >> `"$env:SystemRoot\Temp\EntOpsAVClean.log`" 2>&1"
        $lines += "@rd /s /q `"$p`""
        $lines += "@echo removed: $p %errorlevel% >> `"$env:SystemRoot\Temp\EntOpsAVClean.log`""
    }
    $lines += "@del /q `"$bat`""
    try { $enc = [System.Text.Encoding]::GetEncoding(936) } catch { $enc = New-Object System.Text.UTF8Encoding($false) }
    [System.IO.File]::WriteAllLines($bat, $lines, $enc)
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" -Name "EntOpsAVClean" -Value "cmd.exe /c `"$bat`"" -Force
    Write-WinUtilEntCleanLog "已登记重启清理脚本：$bat"
    return $true
}

function Remove-WinUtilEntAVProducts {

    <#

    .SYNOPSIS
        Detects, uninstalls and force-cleans the selected consumer security suites

    .PARAMETER Keys
        Product keys from entclean.json (360, kingsoft, tencent)

    .PARAMETER ForceMode
        Skip the vendor uninstallers and go straight to the force pass

    #>
    param(
        [Parameter(Mandatory)]
        [string[]]$Keys,

        [bool]$ForceMode = $false
    )

    $script:EntCleanPending = @()
    $products = @($sync.configs.entclean.products | Where-Object { $Keys -contains $_.key })

    Step-WinUtilJob -Status "正在检测已安装的安全软件" -Percent 5
    Write-WinUtilEntCleanLog "========== 安全软件彻底清理 =========="
    Write-WinUtilEntCleanLog ("模式：" + $(if ($ForceMode) { "强制清理（不运行官方卸载程序）" } else { "先官方卸载，再清理残留" }))

    $targets = @()
    foreach ($product in $products) {
        $dirs = @($product.installDirs | ForEach-Object { Resolve-WinUtilEntCleanPath $_ })
        $foundDirs = @($dirs | Where-Object { Test-Path -LiteralPath $_ })
        $entry = $null
        $inst = @(Get-WinUtilEntAVInstall | Where-Object { $_.Key -eq $product.key -and $_.Found })
        if ($inst.Count -gt 0) { $entry = $inst[0].UninstallEntry }

        if ($inst.Count -eq 0) {
            Write-WinUtilEntCleanLog "未检测到 $($product.name)，跳过。"
            continue
        }
        $targets += [pscustomobject]@{ Product = $product; Dirs = $dirs; FoundDirs = $foundDirs; Entry = $entry }
    }

    if ($targets.Count -eq 0) {
        Step-WinUtilJob -Status "未发现勾选的产品" -Percent 100
        Write-WinUtilEntCleanLog "勾选的产品均未安装，无需清理。"
        return
    }

    $index = 0
    foreach ($target in $targets) {
        $index++
        $product = $target.Product
        $percent = 10 + [int](60 * ($index - 1) / $targets.Count)
        Step-WinUtilJob -Status "正在清理 $($product.name)" -Percent $percent
        Write-WinUtilEntCleanLog "---------- $($product.name) ----------"

        Stop-WinUtilEntCleanProcesses -Product $product

        if (-not $ForceMode -and $target.Entry -and ($target.Entry.UninstallString -or $target.Entry.QuietUninstallString)) {
            Invoke-WinUtilEntCleanVendorUninstall -Product $product -Entry $target.Entry
            Stop-WinUtilEntCleanProcesses -Product $product
        }

        Remove-WinUtilEntCleanServices -Dirs $target.Dirs
        Stop-WinUtilEntCleanProcesses -Product $product

        foreach ($d in ($target.FoundDirs + @($product.programDataDirs | ForEach-Object { Resolve-WinUtilEntCleanPath $_ }))) {
            if (-not (Test-Path -LiteralPath $d)) { continue }
            if (Remove-WinUtilEntCleanDirTree $d) {
                Write-WinUtilEntCleanLog "已删除目录 $d"
            } else {
                Write-WinUtilEntCleanLog "目录仍被占用，留待重启后删除：$d" "WARN"
                $script:EntCleanPending += $d
            }
        }

        Remove-WinUtilEntCleanAllUserData -Product $product
        Remove-WinUtilEntCleanRegistry -Product $product -Dirs $target.Dirs
        Remove-WinUtilEntCleanTasks -Dirs $target.Dirs
    }

    Step-WinUtilJob -Status "正在清理安全中心注册" -Percent 80
    try {
        $regex = ($targets | ForEach-Object { $_.Product.displayNameRegex }) -join "|"
        Get-CimInstance -Namespace "root\SecurityCenter2" -ClassName AntiVirusProduct -ErrorAction Stop |
            Where-Object { $_.displayName -imatch $regex } |
            ForEach-Object {
                Write-WinUtilEntCleanLog "移除安全中心注册：$($_.displayName)"
                Remove-CimInstance -InputObject $_ -ErrorAction SilentlyContinue
            }
    } catch {
        Write-WinUtilEntCleanLog "安全中心注册清理未完成：$($_.Exception.Message)" "WARN"
    }

    Step-WinUtilJob -Status "收尾" -Percent 90
    $pending = @($script:EntCleanPending | Select-Object -Unique)
    $needReboot = $false
    if ($pending.Count -gt 0) {
        if (Set-WinUtilEntCleanRunOnce -Paths $pending) { $needReboot = $true }
    }

    # Re-detect for the closing report: only hard evidence (dirs/processes) counts as remaining
    $remaining = @(Get-WinUtilEntAVInstall | Where-Object { $Keys -contains $_.Key -and $_.Found } | ForEach-Object {
        $hard = @($_.Evidence | Where-Object { $_ -notlike "卸载注册表*" })
        if ($hard.Count -gt 0) { [pscustomobject]@{ Name = $_.Name; Evidence = $hard } }
    })
    Write-WinUtilEntCleanLog "========== 清理完成 =========="
    if ($remaining.Count -gt 0) {
        foreach ($r in $remaining) { Write-WinUtilEntCleanLog "仍存在痕迹：$($r.Name)（$($r.Evidence -join '；')）" "WARN" }
    }
    if ($needReboot) {
        Write-WinUtilEntCleanLog "部分文件正被占用，已安排在下次开机时自动删除，请尽快重启计算机。" "WARN"
    } else {
        Write-WinUtilEntCleanLog "清理完成。若刚卸载了第三方杀软，Windows 安全中心会自动恢复 Microsoft Defender 防护。"
    }
}
