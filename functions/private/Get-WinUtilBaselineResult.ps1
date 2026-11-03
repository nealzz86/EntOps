#===========================================================================
# 装机体检清单 - 结果计算
#
# 事实键契约（Get-WinUtilBaselineFacts 采集，全部可选；缺失即视为探针不可用）：
#   ComputerName        [string]   本机计算机名
#   JoinedDomain        [string]   Win32_ComputerSystem.Domain，域名为空时为工作组名
#   IsDomainJoined      [bool]     是否已加入域
#   TimeZoneId          [string]   [TimeZoneInfo]::Local.Id
#   PowerScheme         [string]   当前电源计划 GUID（小写）
#   PowerSchemeName     [string]   powercfg 打印的本地化计划名
#   UpdatesManaged      [bool]     更新是否由策略管控
#   UpdatesDisabled     [bool]     自动更新是否被关闭
#   DefenderEnabled     [bool]     Defender 实时防护是否开启
#   EntAVRemaining      [string[]] 检测到的第三方杀软产品名，空数组表示干净
#   WinRMStatus         [string]   Running / Stopped / Disabled / Manual，空表示未读取
#   InstalledAppNames   [string[]] 卸载注册表里的显示名
#   RequiredApps        [string[]] 必装软件清单，检查项 expect 为空时的替补
#   SharePath           [string]   配置里的共享目录名（不含凭据）
#   ShareReachable      [bool]     共享是否可达，$null 表示未配置或未探测
#   ShareError          [string]   不可达时的中文原因
#   SystemDriveFreeGB   [double]   系统盘剩余容量
#   SystemDriveTotalGB  [double]   系统盘总容量
#   IsAdmin             [bool]     当前是否以管理员身份运行
#   OSArch              [string]   系统架构
#   OSVersion           [string]   系统版本名
#
# FixButton / FixText 只在需要动手的行上给出（State 不是 pass），通过的行留空，
# 免得界面在一堆绿色行后面挂上一排无用的修复按钮。
#===========================================================================

function Get-WinUtilBaselineFactKeys {

    <#

    .SYNOPSIS
        体检扫描器读取的事实键清单

    .DESCRIPTION
        这段清单是采集端与计算端唯一的接口文档：调用方按这些名字组装 hashtable，
        Test-WinUtilBaseline 只认这些名字。任何一项都可以缺失，缺失的行降级为 info。

    #>

    return [string[]]@(
        "ComputerName",
        "JoinedDomain",
        "IsDomainJoined",
        "TimeZoneId",
        "PowerScheme",
        "PowerSchemeName",
        "UpdatesManaged",
        "UpdatesDisabled",
        "DefenderEnabled",
        "EntAVRemaining",
        "WinRMStatus",
        "InstalledAppNames",
        "RequiredApps",
        "SharePath",
        "ShareReachable",
        "ShareError",
        "SystemDriveFreeGB",
        "SystemDriveTotalGB",
        "IsAdmin",
        "OSArch",
        "OSVersion"
    )
}

function Test-WinUtilBaseline {

    <#

    .SYNOPSIS
        把检查项与已采集的事实算成一行行体检结果，不碰注册表、WMI 与磁盘

    .DESCRIPTION
        纯函数：所有输入都在 $Facts 里，所以整张表可以用假数据测试，也能在无界面
        的环境复用。事实缺失、为 $null 或为空串时该行降级为 info，绝不抛异常；
        未知的 type 同样输出 info 并说明本版本不支持该检查。

    .PARAMETER Checks
        config\baseline.json 里的 checks 数组

    .PARAMETER Facts
        以 Get-WinUtilBaselineFactKeys 为键的 hashtable

    #>

    param(
        $Checks,
        [hashtable]$Facts
    )

    if ($null -eq $Facts) { $Facts = @{} }

    $rows = [System.Collections.Generic.List[psobject]]::new()

    foreach ($check in @($Checks)) {
        if ($null -eq $check) { continue }

        $type = [string]$check.type
        $expect = [string]$check.expect
        $severity = ([string]$check.severity).ToLowerInvariant()
        if (@("fail", "warn", "info") -notcontains $severity) { $severity = "info" }

        $ok = $false
        $unknown = $false
        $detail = ""

        switch ($type) {

            "computerNamePattern" {
                $name = [string]$Facts['ComputerName']
                $rule = $expect.Trim()

                # 空前缀会让 StartsWith 永远为真，基线工具最坏的错就是假通过，所以宁可报未配置
                if ([string]::IsNullOrWhiteSpace($rule)) {
                    $unknown = $true
                    $detail = "本项未配置命名规则，无法比对。"
                } elseif ([string]::IsNullOrWhiteSpace($name)) {
                    $unknown = $true
                    $detail = "未读取到计算机名，无法比对命名规则。"
                } else {
                    $isRegex = $rule.StartsWith("^") -or $rule.EndsWith("$")
                    if ($isRegex) {
                        # -imatch swallows an invalid pattern as a false match, which would read as
                        # "不符合命名规则" instead of telling the operator the rule is broken
                        try {
                            $probe = New-Object System.Text.RegularExpressions.Regex($rule, "IgnoreCase")
                            $ok = $probe.IsMatch($name)
                            $ruleText = "规则 $rule"
                        } catch {
                            $unknown = $true
                            $detail = "命名规则 $rule 无法解析，已跳过该项。"
                        }
                    } else {
                        $ok = $name.StartsWith($rule, [StringComparison]::OrdinalIgnoreCase)
                        $ruleText = "前缀 $rule"
                    }

                    if (-not $unknown) {
                        if ($ok) {
                            $detail = "计算机名：$name，符合$ruleText。"
                        } else {
                            $detail = "计算机名：$name，不符合$ruleText。"
                        }
                    }
                }
            }

            "domain" {
                $joined = $Facts['IsDomainJoined']
                if ($null -eq $joined) {
                    $unknown = $true
                    $detail = "未读取到加域状态，无法判定入网方式。"
                } else {
                    $isDomain = [bool]$joined
                    $domainName = [string]$Facts['JoinedDomain']
                    $wanted = $expect.Trim().ToLowerInvariant()

                    if ($wanted -eq "domain") { $ok = $isDomain }
                    elseif ($wanted -eq "workgroup") { $ok = (-not $isDomain) }
                    else { $ok = ($isDomain -and $domainName.IndexOf($wanted, [StringComparison]::OrdinalIgnoreCase) -ge 0) }

                    $modeText = "工作组"
                    if ($isDomain) { $modeText = "域" }
                    $detail = "入网方式：$modeText（$domainName），基线要求：$expect。"
                }
            }

            "timeZone" {
                $zone = [string]$Facts['TimeZoneId']
                if ([string]::IsNullOrWhiteSpace($zone)) {
                    $unknown = $true
                    $detail = "未读取到系统时区。"
                } else {
                    $wanted = $expect.Trim()
                    $ok = ($zone -ieq $wanted)
                    if ($ok) {
                        $detail = "当前时区：$zone，符合基线。"
                    } else {
                        $detail = "当前时区：$zone，基线要求 $wanted。"
                    }
                }
            }

            "powerScheme" {
                $guid = [string]$Facts['PowerScheme']
                $schemeName = [string]$Facts['PowerSchemeName']
                $wanted = $expect.Trim()

                if ([string]::IsNullOrWhiteSpace($wanted)) {
                    $unknown = $true
                    $detail = "本项未配置基线电源计划，无法比对。"
                } elseif ([string]::IsNullOrWhiteSpace($guid) -and [string]::IsNullOrWhiteSpace($schemeName)) {
                    $unknown = $true
                    $detail = "未读取到当前电源计划。"
                } else {
                    $seenParts = [System.Collections.Generic.List[string]]::new()
                    if (-not [string]::IsNullOrWhiteSpace($schemeName)) { [void]$seenParts.Add($schemeName.Trim()) }
                    if (-not [string]::IsNullOrWhiteSpace($guid)) { [void]$seenParts.Add("($guid)") }
                    $seenText = ($seenParts -join " ")

                    # 计划名由 powercfg 按显示语言输出，GUID 才是稳定的那一半，所以两个都试，
                    # 并允许 expect 只写 GUID 的前缀（复制出来的计划后缀每次都不同）
                    foreach ($candidate in @($guid, $schemeName)) {
                        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
                        $trimmed = $candidate.Trim()
                        if ($trimmed -ieq $wanted -or $trimmed.StartsWith($wanted, [StringComparison]::OrdinalIgnoreCase)) {
                            $ok = $true
                            break
                        }
                    }

                    if ($ok) {
                        $detail = "当前电源计划：$seenText，符合基线。"
                    } else {
                        $detail = "当前电源计划：$seenText，基线要求：$wanted。"
                    }
                }
            }

            "updatePolicy" {
                $managed = $Facts['UpdatesManaged']
                $disabled = $Facts['UpdatesDisabled']
                if ($null -eq $managed -and $null -eq $disabled) {
                    $unknown = $true
                    $detail = "未读取到 Windows 更新策略。"
                } else {
                    $isManaged = [bool]$managed
                    $isDisabled = [bool]$disabled
                    $wanted = $expect.Trim().ToLowerInvariant()

                    # security 是本单位的标准：既要有策略管控，也不能把更新整个关掉
                    if ($wanted -eq "managed") { $ok = $isManaged }
                    else { $ok = ($isManaged -and (-not $isDisabled)) }

                    $managedText = "未受控"
                    if ($isManaged) { $managedText = "受策略管控" }
                    $disabledText = "自动更新未关闭"
                    if ($isDisabled) { $disabledText = "自动更新已关闭" }
                    $detail = "更新策略：$managedText，$disabledText；基线要求：$expect。"
                }
            }

            "defender" {
                $enabled = $Facts['DefenderEnabled']
                if ($null -eq $enabled) {
                    $unknown = $true
                    $detail = "未读取到 Defender 实时防护状态（第三方杀软接管时该项不可用）。"
                } else {
                    $actual = [bool]$enabled
                    $wantedEnabled = ($expect.Trim().ToLowerInvariant() -ne "disabled")
                    $ok = ($actual -eq $wantedEnabled)

                    $actualText = "已关闭"
                    if ($actual) { $actualText = "已开启" }
                    $wantedText = "开启"
                    if (-not $wantedEnabled) { $wantedText = "关闭" }
                    $detail = "Defender 实时防护：$actualText，基线要求：$wantedText。"
                }
            }

            "avClean" {
                $leftover = @($Facts['EntAVRemaining'] |
                    Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
                    ForEach-Object { [string]$_ })

                if ($null -eq $Facts['EntAVRemaining']) {
                    $unknown = $true
                    $detail = "未执行第三方杀软探测，无法确认是否有残留。"
                } elseif ($leftover.Count -eq 0) {
                    $ok = $true
                    $detail = "未发现本单位要清理的第三方杀软残留。"
                } else {
                    $detail = "发现待清理的杀软残留：$($leftover -join '、')。"
                }
            }

            "service" {
                $status = [string]$Facts['WinRMStatus']
                if ([string]::IsNullOrWhiteSpace($status)) {
                    $unknown = $true
                    $detail = "未读取到 WinRM 服务状态。"
                } else {
                    $wanted = $expect.Trim()
                    $ok = ($status -ieq $wanted)
                    if ($ok) {
                        $detail = "WinRM 服务状态：$status，符合基线。"
                    } else {
                        $detail = "WinRM 服务状态：$status，基线要求：$wanted。"
                    }
                }
            }

            "softwareInstalled" {
                $installed = @($Facts['InstalledAppNames'] |
                    Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
                    ForEach-Object { [string]$_ })

                if ($null -eq $Facts['InstalledAppNames']) {
                    $unknown = $true
                    $detail = "未读取到已安装软件清单。"
                } else {
                    $wantedText = $expect
                    if ([string]::IsNullOrWhiteSpace($wantedText) -and $Facts.ContainsKey('RequiredApps')) {
                        $wantedText = (@($Facts['RequiredApps'] | ForEach-Object { [string]$_ }) -join ",")
                    }
                    $wantedApps = @($wantedText -split '[,，、]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })

                    if ($wantedApps.Count -eq 0) {
                        $unknown = $true
                        $detail = "本项未配置必装软件清单，无法比对。"
                    } else {
                        $found = [System.Collections.Generic.List[string]]::new()
                        $missing = [System.Collections.Generic.List[string]]::new()
                        foreach ($app in $wantedApps) {
                            # 卸载项显示名带版本号，先按原名，再按前缀，最后才按包含，逐级放宽
                            $hit = @($installed | Where-Object { $_ -ieq $app })
                            if ($hit.Count -eq 0) {
                                $hit = @($installed | Where-Object { $_.StartsWith($app, [StringComparison]::OrdinalIgnoreCase) })
                            }
                            if ($hit.Count -eq 0) {
                                $hit = @($installed | Where-Object { $_.IndexOf($app, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
                            }

                            if ($hit.Count -gt 0) { [void]$found.Add($hit[0]) } else { [void]$missing.Add($app) }
                        }

                        $ok = ($missing.Count -eq 0)
                        if ($ok) {
                            $detail = "必装软件已就位：$($found -join '、')。"
                        } else {
                            $detail = "缺少必装软件：$($missing -join '、')。"
                            if ($found.Count -gt 0) { $detail += "已装：$($found -join '、')。" }
                        }
                    }
                }
            }

            "shareReachable" {
                $reachable = $Facts['ShareReachable']
                $sharePath = [string]$Facts['SharePath']
                $shareError = [string]$Facts['ShareError']

                if ($null -eq $reachable) {
                    $unknown = $true
                    if ([string]::IsNullOrWhiteSpace($shareError)) {
                        $detail = "未配置共享目录或未执行可达性探测。"
                    } else {
                        $detail = "共享目录未探测：$shareError"
                    }
                } elseif ([bool]$reachable) {
                    $ok = $true
                    $detail = "共享目录可访问：$sharePath。"
                    if ([string]::IsNullOrWhiteSpace($sharePath)) { $detail = "共享目录可访问。" }
                } else {
                    $detail = "共享目录不可访问：$sharePath。"
                    if ([string]::IsNullOrWhiteSpace($sharePath)) { $detail = "共享目录不可访问。" }
                    if (-not [string]::IsNullOrWhiteSpace($shareError)) { $detail += "原因：$shareError" }
                }
            }

            "freeSpace" {
                $free = $Facts['SystemDriveFreeGB']
                $total = $Facts['SystemDriveTotalGB']
                $wantedGB = [double]0
                $parsable = [double]::TryParse($expect, [ref]$wantedGB)

                if ($null -eq $free -or -not $parsable) {
                    $unknown = $true
                    $detail = "未读取到系统盘剩余空间。"
                } else {
                    $freeGB = [math]::Round([double]$free, 1)
                    $ok = ($freeGB -ge $wantedGB)

                    $seenText = "系统盘剩余 $freeGB GB"
                    if ($null -ne $total) { $seenText += "（共 $([math]::Round([double]$total, 0)) GB）" }
                    if ($ok) {
                        $detail = "$seenText，满足最低 $wantedGB GB。"
                    } else {
                        $detail = "$seenText，低于最低 $wantedGB GB。"
                    }
                }
            }

            "adminRequired" {
                $isAdmin = $Facts['IsAdmin']
                if ($null -eq $isAdmin) {
                    $unknown = $true
                    $detail = "未能确认当前运行身份。"
                } else {
                    $actual = [bool]$isAdmin
                    $wanted = ($expect.Trim().ToLowerInvariant() -ne "false")
                    $ok = ($actual -eq $wanted)

                    $actualText = "普通用户权限"
                    if ($actual) { $actualText = "管理员权限" }
                    $detail = "当前运行身份：$actualText，基线要求：$expect。"
                }
            }

            default {
                $unknown = $true
                $detail = "检查类型 $type 暂不支持，本项未参与判定。"
            }
        }

        $state = "pass"
        if ($unknown) {
            $state = "info"
        } elseif (-not $ok) {
            $state = $severity
        }

        $fixButton = ""
        $fixText = ""
        if ($state -ne "pass" -and $null -ne $check.fix) {
            $fixButton = [string]$check.fix.button
            $fixText = [string]$check.fix.text
        }

        $rows.Add([pscustomobject]@{
            Id        = [string]$check.id
            State     = $state
            Name      = [string]$check.label
            Detail    = $detail
            FixButton = $fixButton
            FixText   = $fixText
        })
    }

    return @($rows)
}

function Get-WinUtilBaselineResult {

    <#

    .SYNOPSIS
        装机体检的最终结果：结果表、计数、一句话中文结论

    .DESCRIPTION
        包住 Test-WinUtilBaseline，只多做两件事：确认配置可用（不可用时给出 Problem，
        由界面决定怎么提示），以及把计数汇成一句结论。本函数不采集事实，也不写日志。

    .PARAMETER Config
        $sync.configs.baseline（config\baseline.json 编译期内嵌）

    .PARAMETER Facts
        以 Get-WinUtilBaselineFactKeys 为键的 hashtable

    #>

    param(
        $Config,
        [hashtable]$Facts
    )

    $problem = ""
    $checks = @()

    if ($null -eq $Config) {
        $problem = "未找到装机体检配置，无法开始体检。"
    } else {
        $checks = @($Config.checks)
        if ($checks.Count -eq 0) {
            $problem = "装机体检配置里没有检查项，无法开始体检。"
        } elseif (@($checks | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.type) }).Count -gt 0) {
            $problem = "装机体检配置格式不正确：检查项缺少 type 字段。"
        }
    }

    $rows = @()
    if ([string]::IsNullOrWhiteSpace($problem)) {
        try {
            $rows = @(Test-WinUtilBaseline -Checks $checks -Facts $Facts)
        } catch {
            # 结论只给运维看，异常细节留在日志里，不让英文堆栈爬到界面上
            $rows = @()
            $problem = "体检计算失败，未得到结论。请重新运行一键体检。"
        }
    }

    $passCount = @($rows | Where-Object { $_.State -eq "pass" }).Count
    $warnCount = @($rows | Where-Object { $_.State -eq "warn" }).Count
    $failCount = @($rows | Where-Object { $_.State -eq "fail" }).Count

    $verdict = ""
    if (-not [string]::IsNullOrWhiteSpace($problem)) {
        $verdict = "体检配置不可用，未得出结论。"
    } elseif ($failCount -gt 0) {
        $verdict = "体检未通过：$failCount 项严重问题、$warnCount 项提醒。"
    } elseif ($warnCount -gt 0) {
        $verdict = "体检通过，未发现严重问题，另有 $warnCount 项提醒。"
    } elseif ($passCount -eq 0 -and @($rows).Count -gt 0) {
        # 一项都没取到结果时报“通过”会把采集端的故障说成机器没问题，必须分开
        $verdict = "体检未完成：$(@($rows).Count) 项检查均未取到结果，无法判断本机是否合规。"
    } else {
        $verdict = "体检通过，未发现严重问题。"
    }

    return @{
        Rows    = @($rows)
        Summary = @{
            Pass  = $passCount
            Warn  = $warnCount
            Fail  = $failCount
            Total = @($rows).Count
        }
        Verdict = $verdict
        Problem = $problem
    }
}
