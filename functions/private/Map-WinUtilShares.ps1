function Invoke-WinUtilEntCmd {

    <#

    .SYNOPSIS
        Runs a cmd.exe command, captures its output and never hangs

    .DESCRIPTION
        Ported from the C# tool's RunCmd. net use waits forever for a console password prompt,
        so stdin is closed immediately (an empty redirect file), stdout/stderr are read in
        parallel and the whole process tree is killed on timeout.

    .PARAMETER Command
        Command line passed to cmd.exe /c

    .PARAMETER TimeoutMs
        Overall timeout, default 15 seconds

    #>
    param(
        [Parameter(Mandatory)]
        [string]$Command,

        [int]$TimeoutMs = 15000
    )

    $outFile = Join-Path ([System.IO.Path]::GetTempPath()) ("ent_out_{0}.txt" -f [Guid]::NewGuid())
    $errFile = Join-Path ([System.IO.Path]::GetTempPath()) ("ent_err_{0}.txt" -f [Guid]::NewGuid())
    $inFile  = Join-Path ([System.IO.Path]::GetTempPath()) ("ent_in_{0}.txt" -f [Guid]::NewGuid())
    New-Item -ItemType File -Path $inFile -Force | Out-Null

    try {
        $p = Start-Process -FilePath "cmd.exe" -ArgumentList "/c $Command" -WindowStyle Hidden -PassThru `
            -RedirectStandardInput $inFile -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        if (-not $p.WaitForExit($TimeoutMs)) {
            try {
                & taskkill.exe /pid $p.Id /T /F 2>$null | Out-Null
                Start-Sleep -Milliseconds 200
            } catch { }
            Write-WinUtilLog -Level "WARN" -Component "Printers" -Message "命令执行超时(${TimeoutMs}ms)，已强制终止: $Command"
            return "[超时] 命令超过 $([Math]::Round($TimeoutMs/1000)) 秒未完成，已强制终止。"
        }
        Start-Sleep -Milliseconds 100 # flush grace for the redirect handles
        $so = if (Test-Path -LiteralPath $outFile) { Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue } else { "" }
        $se = if (Test-Path -LiteralPath $errFile) { Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue } else { "" }
        return [string]$so + [string]$se
    } catch {
        return "执行失败：$($_.Exception.Message)"
    } finally {
        foreach ($f in @($outFile, $errFile, $inFile)) {
            Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
        }
    }
}

function Map-WinUtilShares {

    <#

    .SYNOPSIS
        Maps the selected enterprise SMB shares to drive letters (net use + cmdkey)

    .DESCRIPTION
        Port of the C# MapSharedFolders: skips a drive already mapped to one of the candidate
        paths, deletes a conflicting mapping, tries every candidate path in order, stores the
        credential in the Windows Credential Manager for reconnect at logon, then broadcasts
        WM_SETTINGCHANGE so Explorer shows the new drive.

    .PARAMETER Indices
        Zero-based indexes into configs.entprinters.shares to map

    #>
    param([Parameter(Mandatory)][int[]]$Indices)

    $cfg = $sync.configs.entprinters
    foreach ($i in $Indices) {
        $folder = $cfg.shares[$i]
        if (-not $folder) { continue }

        Write-Host "  正在映射：$($folder.Name)"
        try {
            $checkResult = Invoke-WinUtilEntCmd "net use $($folder.Drive)"
            $alreadyMapped = $false
            foreach ($path in $folder.Paths) {
                if ($checkResult -like "*$path*") { $alreadyMapped = $true }
            }
            if ($alreadyMapped) {
                Write-Host "  $($folder.Name) 已映射，跳过。"
                continue
            }

            # 盘符被其他路径占用则先断开
            if ($checkResult -notmatch "找不到|未找到|尚未连接|网络找不到|Local and Remote|--------") {
                $null = Invoke-WinUtilEntCmd "net use $($folder.Drive) /delete /y"
            }

            for ($pi = 0; $pi -lt $folder.Paths.Count; $pi++) {
                $path = $folder.Paths[$pi]
                # 无密码也必须显式传 ""，否则 net use 会交互式等待输入密码导致挂起
                $passArg = if ([string]::IsNullOrEmpty($folder.Pass)) { '""' } else { $folder.Pass }
                $result = Invoke-WinUtilEntCmd "net use $($folder.Drive) `"$path`" /user:$($folder.User) $passArg /persistent:yes"
                if ($result -match "成功|successfully") {
                    Write-Host "  $($folder.Name) 映射成功 → $($folder.Drive)（$path）"
                    break
                }
                $more = if ($pi + 1 -lt $folder.Paths.Count) { "（尝试备用路径）" } else { "" }
                Write-Host "  [警告] $($folder.Name) 映射失败：$($result.Trim())$more"
            }

            if (-not [string]::IsNullOrEmpty($folder.Pass)) {
                $server = ($folder.Paths[0] -replace '^\\\\', '') -replace '\\.*', ''
                $null = Invoke-WinUtilEntCmd "cmdkey /add:$server /user:$($folder.User) /pass:$($folder.Pass)"
            }
        } catch {
            Write-Host "  [警告] 映射 $($folder.Name) 异常：$($_.Exception.Message)"
        }
    }

    Write-Host "  共享文件夹映射完成。"
    [EntSpool]::BroadcastEnvironmentChange()
    Write-WinUtilEntNativeLog
}

function Print-WinUtilTestPage {

    <#

    .SYNOPSIS
        Sends a one-page test page verifying driver and port, like the C# tool

    .PARAMETER PrinterName
        Name of the printer to print on

    .PARAMETER Printer
        Printer config object from configs.entprinters

    #>
    param(
        [Parameter(Mandatory)][string]$PrinterName,
        [Parameter(Mandatory)]$Printer
    )

    try {
        # System.Drawing.Printing is a namespace inside System.Drawing.dll on .NET Framework but an
        # assembly of its own on Core, so asking for the name there is a hard error, not a no-op
        $null = Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
        if (-not ('System.Drawing.Printing.PrintDocument' -as [type])) {
            $null = Add-Type -AssemblyName System.Drawing.Printing -ErrorAction SilentlyContinue
        }
        $doc = New-Object System.Drawing.Printing.PrintDocument
        $doc.PrinterSettings.PrinterName = $PrinterName
        if (-not $doc.PrinterSettings.IsValid) {
            Write-Host "  [警告] 打印测试页失败：系统未识别打印机 $PrinterName"
            return $false
        }
        $doc.DocumentName = "信息部 - 打印机安装测试页"
        $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $doc.Add_PrintPage({
            param($sender, $ev)
            $g = $ev.Graphics
            $ft = New-Object System.Drawing.Font("Microsoft YaHei", 20, [System.Drawing.FontStyle]::Bold)
            $fb = New-Object System.Drawing.Font("Microsoft YaHei", 11)
            $br = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::Black)
            $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::Black, 2)
            $x = 80; $y = 90
            $g.DrawString("打印机安装测试页", $ft, $br, $x, $y); $y += 46
            $g.DrawLine($pen, $x, $y, $x + 420, $y); $y += 24
            $g.DrawString("打印机名称：$($Printer.Name)", $fb, $br, $x, $y); $y += 26
            $g.DrawString("IP 地址　　：$($Printer.Ip)", $fb, $br, $x, $y); $y += 26
            $g.DrawString("端口名称　：$($Printer.PortName)", $fb, $br, $x, $y); $y += 26
            $g.DrawString("驱动名称　：$($Printer.DriverName)", $fb, $br, $x, $y); $y += 26
            $g.DrawString("安放位置　：$($Printer.Location)", $fb, $br, $x, $y); $y += 26
            $g.DrawString("打印时间　：$stamp", $fb, $br, $x, $y); $y += 40
            $g.DrawString("若能看到本页，说明驱动与端口配置成功。", $fb, $br, $x, $y); $y += 24
            $g.DrawString("如有问题请联系信息部。", $fb, $br, $x, $y)
            $ft.Dispose(); $fb.Dispose(); $br.Dispose(); $pen.Dispose()
            $ev.HasMorePages = $false
        })
        $doc.Print()
        Write-Host "  测试页已发送到打印队列。"
        return $true
    } catch {
        Write-Host "  [警告] 打印测试页失败：$($_.Exception.Message)"
        return $false
    }
}
