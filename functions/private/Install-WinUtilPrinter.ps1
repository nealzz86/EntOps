function Install-WinUtilPrinter {

    <#

    .SYNOPSIS
        The seven-step enterprise printer install, ported from the C# PrinterInstaller tool

    .DESCRIPTION
        1 create TCP/IP port (WMI) · 2 release & expand driver zip · 3 install driver
        (AddPrinterDriverEx -> WMI -> printui) · 4 AddPrinter (+ force mono for BW-only units)
        5 register the custom paper form and write Default DevMode · 6 legacy print dialog,
        then optionally the default printer and a test page.
        Mapping shared folders is its own job (Invoke-WPFShareMapOnly): a spooler that hangs must
        not take the drive mappings down with it.
        Runs inside a WinUtil job, so it must not touch WPF controls directly.

    .PARAMETER Printer
        Printer config object from configs.entprinters.printers

    .PARAMETER Mode
        COLOR or BLACK

    .PARAMETER UserCode
        Ricoh user code for the color branch (reminder only, never written to the driver)

    .PARAMETER SetDefault
        Set the printer as default when done

    .PARAMETER TestPage
        Print a test page when done

    #>
    param(
        [Parameter(Mandatory)]$Printer,
        [ValidateSet("COLOR", "BLACK")][string]$Mode = "BLACK",
        [string]$UserCode = "",
        [bool]$SetDefault = $false,
        [bool]$TestPage = $false
    )

    $cfg = $sync.configs.entprinters
    Add-WinUtilEntNatives

    $modeText = if ($Mode -eq "COLOR") { "彩色打印机" } else { "黑白打印机" }
    Write-Host "========== 打印机自动配置与安装（纯 API 实现）=========="
    Write-Host "打印机名称：$($Printer.Name)"
    Write-Host "打印机IP  ：$($Printer.Ip)"
    Write-Host "端口名称  ：$($Printer.PortName)"
    Write-Host "驱动名称  ：$($Printer.DriverName)"
    Write-Host "模式      ：$(if ($Mode -eq 'COLOR') { "彩色 (用户代码 $UserCode)" } else { "黑白 (无用户代码)" })"
    if ($Mode -eq "COLOR") {
        Write-Host "提示：RICOH 用户代码 $UserCode 需在安装完成后于「打印机首选项 → 用户代码（部门管理）」中确认/设置；本工具不写入驱动私有配置。"
    }
    Write-Host "======================================================"

    # ---------- [1/6] TCP/IP 端口 ----------
    Step-WinUtilJob -Status "1/6 · 创建打印端口中…" -Percent 0
    $portOk = $false
    for ($attempt = 1; $attempt -le 3 -and -not $portOk; $attempt++) {
        try {
            $existing = Get-CimInstance -ClassName Win32_TCPIPPrinterPort -Filter "Name='$($Printer.PortName)'" -ErrorAction Stop
            if ($existing) {
                Write-Host "  端口 $($Printer.PortName) 已存在，跳过创建。"
            } else {
                $null = New-CimInstance -ClassName Win32_TCPIPPrinterPort -Property @{
                    Name        = $Printer.PortName
                    Protocol    = 1          # 1 = RAW, 2 = LPR
                    HostAddress = $Printer.Ip
                    PortNumber  = 9100
                    SNMPEnabled = $false
                }
                Write-Host "  端口创建成功。"
            }
            $portOk = $true
        } catch {
            Write-Host "  [尝试 $attempt] 创建端口失败：$($_.Exception.Message)"
            Start-Sleep -Seconds 1
        }
    }
    if (-not $portOk) { Stop-WinUtilPrinterInstall -Printer $Printer; return }
    Step-WinUtilJob -Status "1/6 · 端口就绪" -Percent 16

    # ---------- [2/6] 释放并展开驱动 ----------
    Step-WinUtilJob -Status "2/6 · 释放驱动文件中…" -Percent 16
    $driverRoot = Get-WinUtilEntDriverRoot
    if (-not $driverRoot) {
        Write-Host "  [错误] 未找到驱动目录（drivers\driver.zip / driver2.zip）。"
        Write-Host "  请将 drivers 文件夹与本脚本放在同一目录，或设置环境变量 WINUTIL_ENT_DRIVERS。"
        Stop-WinUtilPrinterInstall -Printer $Printer; return
    }
    $zipPath = Join-Path $driverRoot $Printer.DriverZip
    if (-not (Test-Path -LiteralPath $zipPath)) {
        Write-Host "  [错误] 未找到驱动包：$zipPath"
        Stop-WinUtilPrinterInstall -Printer $Printer; return
    }

    $destDir = Join-Path ([System.IO.Path]::GetTempPath()) "WinUtilEnt_driver"
    if (Test-Path -LiteralPath $destDir) {
        try { Remove-Item -LiteralPath $destDir -Recurse -Force } catch { Write-Host "  [提示] 清理旧驱动目录失败，将覆盖：$($_.Exception.Message)" }
    }
    New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    Write-Host "  正在解压 $($Printer.DriverZip)..."
    try {
        Expand-Archive -LiteralPath $zipPath -DestinationPath $destDir -Force
    } catch {
        Write-Host "  [错误] 释放驱动失败：$($_.Exception.Message)"
        Stop-WinUtilPrinterInstall -Printer $Printer; return
    }

    # 展开 .dl_ → .dll, .ex_ → .exe（kernel32 LZ API）
    Write-Host "  正在用 LZ API 展开压缩文件..."
    $expanded = 0
    foreach ($f in (Get-ChildItem -LiteralPath $destDir -File)) {
        $ext = $f.Extension.ToLowerInvariant()
        if ($ext -notin @(".dl_", ".ex_")) { continue }
        $targetExt = if ($ext -eq ".dl_") { ".dll" } else { ".exe" }
        $target = [System.IO.Path]::ChangeExtension($f.FullName, $targetExt)
        try {
            [EntLz]::Decompress($f.FullName, $target)
            $expanded++
        } catch {
            Write-Host "  [错误] 展开失败：$($f.Name) - $($_.Exception.Message)"
            Stop-WinUtilPrinterInstall -Printer $Printer; return
        }
    }
    Write-Host "  展开完成，共 $expanded 个压缩文件。"
    $infPath = Join-Path $destDir "oemsetup.inf"
    if (-not (Test-Path -LiteralPath $infPath)) {
        Write-Host "  [错误] 释放后未找到 oemsetup.inf"
        Stop-WinUtilPrinterInstall -Printer $Printer; return
    }
    Write-Host "  驱动文件就绪：$destDir"
    Step-WinUtilJob -Status "2/6 · 驱动文件就绪" -Percent 33

    # ---------- [3/6] 安装驱动 ----------
    Step-WinUtilJob -Status "3/6 · 安装打印机驱动中…" -Percent 33
    $blocker = Get-WinUtilEntSpoolerBlocker
    if ($blocker) { Stop-WinUtilPrinterInstall -Printer $Printer -Reason $blocker; return }
    $depFiles = @($Printer.DependentFiles | ForEach-Object { Join-Path $destDir $_ })
    $driverOk = $false
    for ($attempt = 1; $attempt -le 3 -and -not $driverOk; $attempt++) {
        if (Test-WinUtilEntDriverInstalled -DriverName $Printer.DriverName) {
            Write-Host "  驱动已安装，视为成功。"
            $driverOk = $true
            break
        }
        $driverOk = [EntSpool]::InstallDriver(
            $Printer.DriverName,
            (Join-Path $destDir $Printer.DriverFile),
            (Join-Path $destDir $Printer.DataFile),
            (Join-Path $destDir $Printer.ConfigFile),
            (Join-Path $destDir $Printer.HelpFile),
            [string[]]$depFiles)
        Write-WinUtilEntNativeLog
        if (-not $driverOk) {
            Write-Host "  [尝试 $attempt] AddPrinterDriverEx 失败"
            Start-Sleep -Seconds 1
        }
    }
    if (-not $driverOk) {
        Write-Host "  AddPrinterDriverEx 失败，尝试后备方案..."
        $driverOk = Install-WinUtilEntDriverWmi -Printer $Printer -Dir $destDir
    }
    if (-not $driverOk) {
        $driverOk = Install-WinUtilEntDriverPrintui -Printer $Printer -InfPath $infPath
    }
    if (-not $driverOk) {
        Write-Host "  [错误] 驱动安装最终失败"
        Stop-WinUtilPrinterInstall -Printer $Printer; return
    }
    Write-Host "  驱动安装成功。"
    Step-WinUtilJob -Status "3/6 · 驱动安装完成" -Percent 50

    # ---------- [4/6] 添加打印机 ----------
    Step-WinUtilJob -Status "4/6 · 添加打印机中…" -Percent 50
    $blocker = Get-WinUtilEntSpoolerBlocker -Printer $Printer -CheckDriver
    if ($blocker) { Stop-WinUtilPrinterInstall -Printer $Printer -Reason $blocker; return }

    $added = $false
    $timedOut = $false
    for ($attempt = 1; $attempt -le 3 -and -not $added; $attempt++) {
        $added = [EntSpool]::AddPrinter($Printer.Name, $Printer.PortName, $Printer.DriverName, 60)
        Write-WinUtilEntNativeLog
        if ($added) { break }
        if ([EntSpool]::AddPrinterTimedOut) {
            # The call is still parked inside the spooler; issuing another only queues a second one
            $timedOut = $true
            break
        }
        if ([EntSpool]::PrinterExists($Printer.Name)) {
            Write-Host "  打印机已存在，视为成功。"
            $added = $true
            break
        }
        Write-Host "  [尝试 $attempt] AddPrinter 失败"
        Start-Sleep -Seconds 1
    }
    if ($timedOut) {
        Stop-WinUtilPrinterInstall -Printer $Printer -Reason "添加打印机等待 60 秒没有返回，Print Spooler 已被挡住（不是网络问题）"
        return
    }
    if (-not $added) {
        Write-Host "  [错误] AddPrinter 最终失败"
        Stop-WinUtilPrinterInstall -Printer $Printer; return
    }
    Write-Host "  打印机添加成功。"

    # 黑白机强制 dmColor=MONOCHROME
    if (-not $Printer.SupportColor) {
        [EntSpool]::SetColorMode($Printer.Name, $false)
        Write-WinUtilEntNativeLog
    }
    Step-WinUtilJob -Status "4/6 · 打印机已添加" -Percent 66

    # ---------- [5/6] 易快报打印模式（自定义纸张） ----------
    Step-WinUtilJob -Status "5/6 · 配置易快报打印模式中…" -Percent 66
    $formOk = [EntSpool]::RegisterPaperForm($Printer.Name, $cfg.formName, [int]$cfg.formWidthTenthMm, [int]$cfg.formHeightTenthMm)
    Write-WinUtilEntNativeLog
    if (-not $formOk) {
        Write-Host "  [警告] 易快报纸张配置失败，但打印机已安装成功。"
    } else {
        Write-Host "  正在重启 Print Spooler 服务以刷新缓存（会中断本机进行中的打印任务）..."
        try {
            Restart-Service -Name Spooler -Force -ErrorAction Stop
            Write-Host "  Print Spooler 服务已重启，缓存已刷新。"
        } catch {
            Write-Host "  [警告] 重启 Spooler 失败：$($_.Exception.Message)"
        }
        Write-Host "  [5/6] 易快报打印模式配置完成。"
        Write-Host "  提示：如打印首选项下拉框未显示该纸张，请在应用中选择「自定义纸张尺寸」手动输入 140×240mm。"
    }
    Step-WinUtilJob -Status "5/6 · 纸张配置完成" -Percent 83

    # ---------- [6/6] 传统打印对话框 ----------
    Step-WinUtilJob -Status "6/6 · 启用传统打印对话框…" -Percent 83
    try {
        $printKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Print"
        if (-not (Test-Path -LiteralPath $printKey)) { New-Item -Path $printKey -Force | Out-Null }
        Set-ItemProperty -LiteralPath $printKey -Name "UseLegacyPrintDialog" -Value 1 -Type DWord
        Write-Host "  已启用传统打印对话框（UseLegacyPrintDialog=1），纸张下拉框应能看到「$($cfg.formName)」。"
    } catch {
        Write-Host "  [警告] 启用传统打印对话框失败：$($_.Exception.Message)"
    }
    Step-WinUtilJob -Status "6/6 · 完成" -Percent 100

    if ($SetDefault) {
        Write-Host "  正在将其设为默认打印机…"
        [EntSpool]::SetDefault($Printer.Name) | Out-Null
        Write-WinUtilEntNativeLog
    }
    if ($TestPage) {
        Write-Host "  正在打印测试页…"
        Print-WinUtilTestPage -PrinterName $Printer.Name -Printer $Printer | Out-Null
    }

    Step-WinUtilJob -Status "安装完成" -Percent 100
    Write-Host ""
    Write-Host "======================================================"
    Write-Host "              ✅ 打印机安装完成！"
    Write-Host "======================================================"
    Write-Host "打印机名称：$($Printer.Name)"
    Write-Host "模式      ：$(if ($Mode -eq 'COLOR') { '彩色' } else { '黑白' })"
    Write-Host "位置      ：$($Printer.Location)"
    Write-Host "用户代码  ：$(if ($UserCode) { $UserCode } else { '（无）' })"
    Write-Host ""
    Write-Host "【使用提示】"
    Write-Host "1. 已启用传统打印对话框，打印时纸张下拉框应显示「$($cfg.formName)」"
    Write-Host "2. 如仍看不到，请在打印对话框选择「自定义纸张尺寸」→ 输入 140×240mm"
    Write-Host "3. 黑白打印机已强制设置为黑白模式"
    Write-Host "4. 本次只装打印机，共享文件夹请用「映射共享文件夹」单独执行"
    Write-Host "如有问题，请联系信息部，谢谢！"
    Write-Host "======================================================"
    Write-WinUtilLog -Level "INFO" -Component "Printers" -Message "Printer install finished: $($Printer.Name) ($Mode)"
}

function Stop-WinUtilPrinterInstall {
    param($Printer, [string]$Reason = "")

    if ($Reason) {
        Write-WinUtilLog -Level "ERROR" -Component "Printers" -Message "$Reason（$($Printer.Name)）"
        Write-Host "  [错误] $Reason"
    }

    Step-WinUtilJob -Status "安装失败" -Percent 100 -State Error -Overlay Warning
    Write-Host ""
    Write-Host "======================================================"
    Write-Host "              ❌ 安装失败，请检查："
    Write-Host "======================================================"
    Write-Host "1. 电脑已连接内网"
    Write-Host "2. 已以【管理员身份】运行 WinUtil"
    Write-Host "3. 打印机 IP $($Printer.Ip) 可达"
    Write-Host "4. 卡住不动的通常是 Print Spooler：在那台电脑上执行"
    Write-Host "   Restart-Service Spooler -Force 后重新安装（会中断该机正在进行的打印）"
    Write-Host "5. 反复卡在「添加打印机」多为该驱动未签名或被 Point and Print 策略拦截，"
    Write-Host "   确认框弹在服务会话里、远程桌面上看不见；需放行策略或改用带签名的驱动"
    Write-Host "======================================================"
    Write-WinUtilLog -Level "ERROR" -Component "Printers" -Message "Printer install failed: $($Printer.Name)"
}

function Get-WinUtilEntSpoolerBlocker {

    <#

    .SYNOPSIS
        Why the next winspool call would hang, asked before making it

    .DESCRIPTION
        Every winspool entry point used here is a synchronous RPC with no timeout of its own, so
        a spooler that has stopped answering turns the install into a progress bar that never
        moves. These checks go by CIM and the service control manager instead, which is a separate
        path and still replies while the spooler is parked. Returns a Chinese sentence, or $null
        when nothing is obviously wrong.

    #>
    param($Printer, [switch]$CheckDriver)

    $service = Get-Service -Name "Spooler" -ErrorAction SilentlyContinue
    if (-not $service) {
        return "本机没有 Print Spooler 服务（打印功能可能被精简或被策略禁用），无法添加打印机。"
    }
    if ($service.Status -ne "Running") {
        return "Print Spooler 服务当前为 $($service.Status)，请先运行 net start Spooler 启动它再重试。"
    }

    if ($Printer -and $Printer.PortName) {
        $escaped = $Printer.PortName.Replace("'", "''")
        $port = Get-CimInstance -ClassName Win32_TCPIPPrinterPort -Filter "Name='$escaped'" -ErrorAction SilentlyContinue
        if (-not $port) {
            return "打印端口 $($Printer.PortName) 不存在，说明第 1 步创建的端口没留住（可能被安全软件删除），请检查后重试。"
        }
    }

    if ($CheckDriver -and $Printer -and $Printer.DriverName) {
        if (-not (Test-WinUtilEntDriverInstalled -DriverName $Printer.DriverName)) {
            return "驱动「$($Printer.DriverName)」没有在打印服务器上登记成功，此时添加打印机必定失败；请确认驱动包完整、且有管理员权限。"
        }
    }

    # The one check that cannot be done through CIM: whether spoolsv will answer at all
    if (-not [EntSpool]::SpoolerResponsive(5)) {
        return "Print Spooler 对探测调用没有回应（5 秒超时），它已经卡住了。请在该电脑执行 Restart-Service Spooler -Force 后重试；反复出现通常是驱动未签名或被 Point and Print 策略拦截，确认框弹在远程桌面看不见的会话里。"
    }

    return $null
}

function Test-WinUtilEntDriverInstalled {
    param([string]$DriverName)
    try {
        $escaped = $DriverName.Replace("'", "''")
        $found = Get-CimInstance -ClassName Win32_PrinterDriver -Filter "Name LIKE '$escaped%'" -ErrorAction Stop
        return [bool]$found
    } catch {
        Write-Host "  [提示] 查询驱动是否已安装异常：$($_.Exception.Message)"
        return $false
    }
}

function Install-WinUtilEntDriverWmi {
    param($Printer, [string]$Dir)
    try {
        Write-Host "  尝试 WMI 方式安装驱动..."
        $cls = [WmiClass]"Win32_PrinterDriver"
        $obj = $cls.CreateInstance()
        $obj["Name"] = $Printer.DriverName
        $obj["SupportedPlatform"] = if ([IntPtr]::Size -eq 8) { "Windows x64" } else { "Windows NT x86" }
        $obj["Version"] = 3
        $obj["DriverPath"] = Join-Path $Dir $Printer.DriverFile
        $obj["DataFile"] = Join-Path $Dir $Printer.DataFile
        $obj["ConfigFile"] = Join-Path $Dir $Printer.ConfigFile
        $obj["HelpFile"] = Join-Path $Dir $Printer.HelpFile
        $inParams = $cls.GetMethodParameters("AddPrinterDriver")
        $inParams["Driver"] = $obj
        $null = $cls.InvokeMethod("AddPrinterDriver", $inParams, $null)
        if (Test-WinUtilEntDriverInstalled -DriverName $Printer.DriverName) {
            Write-Host "  WMI 方式安装驱动成功。"
            return $true
        }
        Write-Host "  WMI 方式未生效。"
        return $false
    } catch {
        Write-Host "  WMI 方式失败：$($_.Exception.Message)"
        return $false
    }
}

function Install-WinUtilEntDriverPrintui {
    param($Printer, [string]$InfPath)
    try {
        Write-Host "  尝试 printui 方式安装驱动..."
        if (-not (Test-Path -LiteralPath $InfPath)) {
            Write-Host "  printui 方式失败：找不到 oemsetup.inf"
            return $false
        }
        $result = Invoke-WinUtilEntCmd "rundll32.exe printui.dll,PrintUIEntry /ia /m `"$($Printer.DriverName)`" /f `"$InfPath`"" 60000
        Write-Host "  printui 输出：$($result.Trim())"
        if (Test-WinUtilEntDriverInstalled -DriverName $Printer.DriverName) {
            Write-Host "  printui 方式安装驱动成功。"
            return $true
        }
        Write-Host "  printui 方式未生效。"
        return $false
    } catch {
        Write-Host "  printui 方式失败：$($_.Exception.Message)"
        return $false
    }
}
