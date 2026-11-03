#===========================================================================
# Tests - Baseline compliance checklist (装机体检清单)
#===========================================================================
# Everything here runs on fake fact hashtables: no admin rights, no network, no read of the
# machine under test. The scanning half of the feature lives in Get-WinUtilBaselineFacts and is
# deliberately not loaded, so the calculation stays pure.

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
    . (Join-Path $script:repoRoot "functions\private\Get-WinUtilBaselineResult.ps1")

    $script:baselinePath = Join-Path $script:repoRoot "config\baseline.json"
    $script:baselineConfig = Get-Content -LiteralPath $script:baselinePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $script:routeNames = @((Get-Content -LiteralPath (Join-Path $script:repoRoot "config\routes.json") -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties.Name)

    $script:allowedSeverities = @("fail", "warn", "info")
    $script:allowedTypes = @(
        "computerNamePattern",
        "domain",
        "timeZone",
        "powerScheme",
        "updatePolicy",
        "defender",
        "avClean",
        "service",
        "softwareInstalled",
        "shareReachable",
        "freeSpace",
        "adminRequired"
    )
    $script:rowProperties = @("Id", "State", "Name", "Detail", "FixButton", "FixText")

    $script:compliantFacts = @{
        ComputerName       = "PC-00123"
        JoinedDomain       = "WORKGROUP"
        IsDomainJoined     = $false
        TimeZoneId         = "China Standard Time"
        PowerScheme        = "a184165d-7495-4f8a-8cca-41e58eda836a"
        PowerSchemeName    = "平衡"
        UpdatesManaged     = $true
        UpdatesDisabled    = $false
        DefenderEnabled    = $true
        EntAVRemaining     = @()
        WinRMStatus        = "Running"
        InstalledAppNames  = @("WPS Office 12.1.0.14320", "微信 3.9.11", "向日葵企业版（SOS）")
        SharePath          = "打印机共享、资料共享"
        ShareReachable     = $true
        ShareError         = ""
        SystemDriveFreeGB  = 88.4
        SystemDriveTotalGB = 237
        IsAdmin            = $true
    }

    # A check written in code instead of JSON, so the checker can be exercised without the shipped
    # config deciding what a test proves.
    function script:New-WinUtilBaselineCheck {
        param(
            [string]$Type,
            $Expect = "",
            [string]$Severity = "warn",
            [string]$Button = "",
            [string]$Text = "",
            [string]$Id = ""
        )

        if ([string]::IsNullOrWhiteSpace($Id)) { $Id = "check$Type" }

        return [pscustomobject]@{
            id       = $Id
            type     = $Type
            label    = "体检项"
            group    = "基础信息"
            severity = $Severity
            expect   = $Expect
            hint     = "说明"
            fix      = [pscustomobject]@{ button = $Button; text = $Text }
        }
    }

    function script:Test-WinUtilHasCJK {
        param([string]$Text)

        if ([string]::IsNullOrEmpty($Text)) { return $false }
        # the block name, not a literal range, so the assertion does not depend on how this file is decoded
        return [regex]::IsMatch($Text, "\p{IsCJKUnifiedIdeographs}")
    }
}

Describe "Get-WinUtilBaselineFactKeys" {
    It "documents the fact contract as unique ASCII keys" {
        $keys = @(Get-WinUtilBaselineFactKeys)

        $keys.Count | Should -BeGreaterThan 0
        @($keys | Select-Object -Unique).Count | Should -Be $keys.Count
        foreach ($key in $keys) {
            $key | Should -Match '^[a-z][A-Za-z0-9]*$' -Because "the glue builds facts with these exact names, got $key"
        }
        $keys | Should -Contain "ComputerName"
        $keys | Should -Contain "IsAdmin"
    }

    It "lists every key the fake compliant run feeds" {
        $keys = @(Get-WinUtilBaselineFactKeys)
        $undeclared = @($script:compliantFacts.Keys | Where-Object { $keys -notcontains $_ })

        $undeclared.Count | Should -Be 0 -Because "facts must stay inside the documented contract, got: $($undeclared -join ', ')"
    }
}

Describe "Test-WinUtilBaseline" {
    Context "Row contract" {
        It "emits exactly the properties the renderer binds to" {
            $rows = @(Test-WinUtilBaseline -Checks @(New-WinUtilBaselineCheck -Type "adminRequired" -Expect "true" -Severity "fail") -Facts @{ IsAdmin = $true })

            $rows.Count | Should -Be 1
            @($rows[0].PSObject.Properties.Name) | Should -Be $script:rowProperties
            $rows[0].Id | Should -Be "checkadminRequired"
            $rows[0].Name | Should -Be "体检项"
            $rows[0].State | Should -Be "pass"
            $rows[0].FixButton | Should -Be "" -Because "a passing row has nothing to fix"
        }

        It "keeps the configured fix on a row that still needs work" {
            $check = New-WinUtilBaselineCheck -Type "avClean" -Expect "clean" -Severity "fail" -Button "WPFEntCleanDetect" -Text "检测残留杀软"
            $failed = @(Test-WinUtilBaseline -Checks @($check) -Facts @{ EntAVRemaining = @("360 安全卫士") })
            $passed = @(Test-WinUtilBaseline -Checks @($check) -Facts @{ EntAVRemaining = @() })

            $failed[0].State | Should -Be "fail"
            $failed[0].FixButton | Should -Be "WPFEntCleanDetect"
            $failed[0].FixText | Should -Be "检测残留杀软"
            $passed[0].State | Should -Be "pass"
            $passed[0].FixText | Should -Be ""
        }

        It "writes every detail line in Chinese" {
            $checks = @($script:allowedTypes | ForEach-Object { New-WinUtilBaselineCheck -Type $_ })
            $rows = @(Test-WinUtilBaseline -Checks $checks -Facts $script:compliantFacts)

            $rows.Count | Should -Be $script:allowedTypes.Count
            foreach ($row in $rows) {
                (Test-WinUtilHasCJK -Text $row.Detail) | Should -BeTrue -Because "the window only ever shows Chinese, got: $($row.Detail)"
            }
        }
    }

    Context "Degradation" {
        It "reports info instead of throwing when a fact is missing" {
            $rows = @(Test-WinUtilBaseline -Checks @(New-WinUtilBaselineCheck -Type "timeZone" -Expect "China Standard Time" -Severity "fail") -Facts @{})

            $rows[0].State | Should -Be "info"
            (Test-WinUtilHasCJK -Text $rows[0].Detail) | Should -BeTrue
        }

        It "reports info instead of throwing when a fact is null" {
            $check = New-WinUtilBaselineCheck -Type "defender" -Expect "enabled" -Severity "fail"

            { Test-WinUtilBaseline -Checks @($check) -Facts @{ DefenderEnabled = $null } } | Should -Not -Throw

            $rows = @(Test-WinUtilBaseline -Checks @($check) -Facts @{ DefenderEnabled = $null })
            $rows[0].State | Should -Be "info"
        }

        It "survives a null fact hashtable" {
            { Test-WinUtilBaseline -Checks @(New-WinUtilBaselineCheck -Type "computerNamePattern" -Expect "PC-") -Facts $null } | Should -Not -Throw
        }

        It "downgrades an unknown check type to an explanatory info row" {
            $rows = @(Test-WinUtilBaseline -Checks @(New-WinUtilBaselineCheck -Type "bitlocker" -Severity "fail") -Facts @{ ComputerName = "PC-00123" })

            $rows.Count | Should -Be 1
            $rows[0].State | Should -Be "info"
            $rows[0].Detail | Should -BeLike "*bitlocker*"
            (Test-WinUtilHasCJK -Text $rows[0].Detail) | Should -BeTrue
        }

        It "handles an empty check collection" {
            @(Test-WinUtilBaseline -Checks @() -Facts @{}).Count | Should -Be 0
        }
    }

    Context "computerNamePattern" {
        It "fails with the configured severity and names the observed computer name" {
            $check = New-WinUtilBaselineCheck -Type "computerNamePattern" -Expect "PC-" -Severity "fail"
            $rows = @(Test-WinUtilBaseline -Checks @($check) -Facts @{ ComputerName = "shiji-01" })

            $rows[0].State | Should -Be "fail"
            $rows[0].Detail | Should -BeLike "*shiji-01*"
            (Test-WinUtilHasCJK -Text $rows[0].Detail) | Should -BeTrue
        }

        It "treats an anchored expect as a regular expression" {
            $check = New-WinUtilBaselineCheck -Type "computerNamePattern" -Expect "^PC-\d{4}$" -Severity "warn"
            $passing = @(Test-WinUtilBaseline -Checks @($check) -Facts @{ ComputerName = "PC-0421" })
            $failing = @(Test-WinUtilBaseline -Checks @($check) -Facts @{ ComputerName = "PC-0421A" })

            $passing[0].State | Should -Be "pass"
            $failing[0].State | Should -Be "warn"
        }

        It "refuses to read an empty rule as a prefix that always matches" {
            $blank = New-WinUtilBaselineCheck -Type "computerNamePattern" -Expect "" -Severity "fail"
            $rows = @(Test-WinUtilBaseline -Checks @($blank) -Facts @{ ComputerName = "anything" })

            $rows[0].State | Should -Be "info"
            $rows[0].Detail | Should -BeLike "*未配置命名规则*"
        }

        It "degrades to info when an anchored rule cannot be parsed" {
            $broken = New-WinUtilBaselineCheck -Type "computerNamePattern" -Expect "^PC-([" -Severity "fail"
            $rows = @(Test-WinUtilBaseline -Checks @($broken) -Facts @{ ComputerName = "PC-00123" })

            $rows[0].State | Should -Be "info"
        }

        It "reads an unanchored rule literally instead of as a regular expression" {
            $prefix = New-WinUtilBaselineCheck -Type "computerNamePattern" -Expect "PC-([" -Severity "fail"
            $rows = @(Test-WinUtilBaseline -Checks @($prefix) -Facts @{ ComputerName = "PC-([01" })

            $rows[0].State | Should -Be "pass"
        }
    }

    Context "domain" {
        It "reads a workgroup machine as compliant with the workgroup baseline" {
            $check = New-WinUtilBaselineCheck -Type "domain" -Expect "workgroup" -Severity "fail"
            $rows = @(Test-WinUtilBaseline -Checks @($check) -Facts @{ IsDomainJoined = $false; JoinedDomain = "WORKGROUP" })

            $rows[0].State | Should -Be "pass"
            $rows[0].Detail | Should -BeLike "*WORKGROUP*"
        }

        It "reports a domain joined machine with its own severity" {
            $check = New-WinUtilBaselineCheck -Type "domain" -Expect "workgroup" -Severity "info"
            $rows = @(Test-WinUtilBaseline -Checks @($check) -Facts @{ IsDomainJoined = $true; JoinedDomain = "contoso.local" })

            $rows[0].State | Should -Be "info"
            $rows[0].Detail | Should -BeLike "*contoso.local*"
        }

        It "accepts an expected domain name only for a joined machine" {
            $check = New-WinUtilBaselineCheck -Type "domain" -Expect "contoso.local" -Severity "warn"
            $joined = @(Test-WinUtilBaseline -Checks @($check) -Facts @{ IsDomainJoined = $true; JoinedDomain = "contoso.local" })
            $workgroup = @(Test-WinUtilBaseline -Checks @($check) -Facts @{ IsDomainJoined = $false; JoinedDomain = "contoso.local" })

            $joined[0].State | Should -Be "pass"
            $workgroup[0].State | Should -Be "warn"
        }
    }

    Context "timeZone" {
        It "shows the observed zone id even when it is compliant" {
            $check = New-WinUtilBaselineCheck -Type "timeZone" -Expect "China Standard Time" -Severity "warn"
            $rows = @(Test-WinUtilBaseline -Checks @($check) -Facts @{ TimeZoneId = "China Standard Time" })

            $rows[0].State | Should -Be "pass"
            $rows[0].Detail | Should -BeLike "*当前时区：China Standard Time*"
        }
    }

    Context "powerScheme" {
        It "matches the localized plan name and still shows the guid" {
            $check = New-WinUtilBaselineCheck -Type "powerScheme" -Expect "平衡" -Severity "fail"
            $rows = @(Test-WinUtilBaseline -Checks @($check) -Facts @{ PowerScheme = "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c"; PowerSchemeName = "平衡" })

            $rows[0].State | Should -Be "pass"
            $rows[0].Detail | Should -BeLike "*8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c*"
        }

        It "matches a plan by its guid prefix" {
            $check = New-WinUtilBaselineCheck -Type "powerScheme" -Expect "e9a42b02" -Severity "warn"
            $rows = @(Test-WinUtilBaseline -Checks @($check) -Facts @{ PowerScheme = "e9a42b02-d5df-448d-aa00-03f14749eb61"; PowerSchemeName = "Ultimate Performance" })

            $rows[0].State | Should -Be "pass"
        }

        It "fails an off baseline plan on the name alone" {
            $check = New-WinUtilBaselineCheck -Type "powerScheme" -Expect "平衡" -Severity "warn"
            $rows = @(Test-WinUtilBaseline -Checks @($check) -Facts @{ PowerScheme = "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c"; PowerSchemeName = "高性能" })

            $rows[0].State | Should -Be "warn"
            $rows[0].Detail | Should -BeLike "*高性能*"
        }

        It "refuses to pass an unconfigured plan expectation" {
            $check = New-WinUtilBaselineCheck -Type "powerScheme" -Expect "" -Severity "fail"
            $rows = @(Test-WinUtilBaseline -Checks @($check) -Facts @{ PowerSchemeName = "高性能" })

            $rows[0].State | Should -Be "info"
        }
    }

    Context "updatePolicy" {
        It "passes the security baseline only when policy manages update and keeps it switched on" {
            $check = New-WinUtilBaselineCheck -Type "updatePolicy" -Expect "security" -Severity "warn"
            $managed = @(Test-WinUtilBaseline -Checks @($check) -Facts @{ UpdatesManaged = $true; UpdatesDisabled = $false })
            $switchedOff = @(Test-WinUtilBaseline -Checks @($check) -Facts @{ UpdatesManaged = $true; UpdatesDisabled = $true })
            $homeUser = @(Test-WinUtilBaseline -Checks @($check) -Facts @{ UpdatesManaged = $false; UpdatesDisabled = $false })

            $managed[0].State | Should -Be "pass"
            $switchedOff[0].State | Should -Be "warn"
            $homeUser[0].State | Should -Be "warn"
        }

        It "passes a managed-only baseline without caring about the switch" {
            $check = New-WinUtilBaselineCheck -Type "updatePolicy" -Expect "managed" -Severity "warn"
            $rows = @(Test-WinUtilBaseline -Checks @($check) -Facts @{ UpdatesManaged = $true; UpdatesDisabled = $true })

            $rows[0].State | Should -Be "pass"
        }
    }

    Context "defender" {
        It "honours an expectation to keep it switched off" {
            $check = New-WinUtilBaselineCheck -Type "defender" -Expect "disabled" -Severity "warn"
            $rows = @(Test-WinUtilBaseline -Checks @($check) -Facts @{ DefenderEnabled = $false })

            $rows[0].State | Should -Be "pass"
        }
    }

    Context "avClean" {
        It "lists every leftover security suite by name" {
            $check = New-WinUtilBaselineCheck -Type "avClean" -Expect "clean" -Severity "fail"
            $rows = @(Test-WinUtilBaseline -Checks @($check) -Facts @{ EntAVRemaining = @("360 安全卫士 / 360 杀毒", "腾讯电脑管家") })

            $rows[0].State | Should -Be "fail"
            $rows[0].Detail | Should -BeLike "*360*"
            $rows[0].Detail | Should -BeLike "*腾讯电脑管家*"
        }

        It "passes an empty result and stays info when the probe never ran" {
            $check = New-WinUtilBaselineCheck -Type "avClean" -Expect "clean" -Severity "fail"
            $clean = @(Test-WinUtilBaseline -Checks @($check) -Facts @{ EntAVRemaining = @() })
            $unread = @(Test-WinUtilBaseline -Checks @($check) -Facts @{})

            $clean[0].State | Should -Be "pass"
            $unread[0].State | Should -Be "info"
        }
    }

    Context "service" {
        It "compares the WinRM status against the expected state" {
            $check = New-WinUtilBaselineCheck -Type "service" -Expect "Running" -Severity "fail" -Button "WPFInstallSunlogin" -Text "安装向日葵企业版"
            $running = @(Test-WinUtilBaseline -Checks @($check) -Facts @{ WinRMStatus = "Running" })
            $stopped = @(Test-WinUtilBaseline -Checks @($check) -Facts @{ WinRMStatus = "Stopped" })

            $running[0].State | Should -Be "pass"
            $stopped[0].State | Should -Be "fail"
            $stopped[0].Detail | Should -BeLike "*Stopped*"
            $stopped[0].FixButton | Should -Be "WPFInstallSunlogin"
        }

        It "reports info for a blank status instead of a failure" {
            $check = New-WinUtilBaselineCheck -Type "service" -Expect "Running" -Severity "fail"
            $rows = @(Test-WinUtilBaseline -Checks @($check) -Facts @{ WinRMStatus = "" })

            $rows[0].State | Should -Be "info"
        }
    }

    Context "softwareInstalled" {
        It "names the app that is missing out of two" {
            $check = New-WinUtilBaselineCheck -Type "softwareInstalled" -Expect "WPS Office,微信" -Severity "warn"
            $rows = @(Test-WinUtilBaseline -Checks @($check) -Facts @{ InstalledAppNames = @("WPS Office 12.1.0.14320") })

            $rows[0].State | Should -Be "warn"
            $rows[0].Detail | Should -BeLike "*缺少必装软件：微信*"
        }

        It "matches a versioned display name against the bare product name" {
            $check = New-WinUtilBaselineCheck -Type "softwareInstalled" -Expect "WPS Office,微信" -Severity "warn"
            $rows = @(Test-WinUtilBaseline -Checks @($check) -Facts @{ InstalledAppNames = @("WPS Office 12.1.0", "微信 3.9.11") })

            $rows[0].State | Should -Be "pass"
        }

        It "falls back to the RequiredApps fact when the check carries no expect" {
            $check = New-WinUtilBaselineCheck -Type "softwareInstalled" -Expect "" -Severity "warn"
            $rows = @(Test-WinUtilBaseline -Checks @($check) -Facts @{ InstalledAppNames = @("Everything 1.5"); RequiredApps = @("Everything") })

            $rows[0].State | Should -Be "pass"
        }

        It "reports info when the install list could not be read" {
            $check = New-WinUtilBaselineCheck -Type "softwareInstalled" -Expect "WPS Office" -Severity "warn"
            $rows = @(Test-WinUtilBaseline -Checks @($check) -Facts @{})

            $rows[0].State | Should -Be "info"
        }
    }

    Context "shareReachable" {
        It "carries the probe error into the failing row" {
            $check = New-WinUtilBaselineCheck -Type "shareReachable" -Expect "true" -Severity "fail" -Button "WPFShareMapOnly" -Text "映射共享目录"
            $rows = @(Test-WinUtilBaseline -Checks @($check) -Facts @{ ShareReachable = $false; SharePath = "打印机共享"; ShareError = "路径不可访问：\\fileserver\share" })

            $rows[0].State | Should -Be "fail"
            $rows[0].Detail | Should -BeLike "*fileserver*"
            $rows[0].FixButton | Should -Be "WPFShareMapOnly"
        }

        It "stays info when the share was never probed" {
            $check = New-WinUtilBaselineCheck -Type "shareReachable" -Expect "true" -Severity "fail"
            $rows = @(Test-WinUtilBaseline -Checks @($check) -Facts @{ ShareReachable = $null; ShareError = "未配置共享文件夹。" })

            $rows[0].State | Should -Be "info"
            $rows[0].Detail | Should -BeLike "*未配置共享文件夹*"
        }
    }

    Context "freeSpace" {
        It "passes exactly on the configured minimum" {
            $check = New-WinUtilBaselineCheck -Type "freeSpace" -Expect 20 -Severity "warn"
            $rows = @(Test-WinUtilBaseline -Checks @($check) -Facts @{ SystemDriveFreeGB = 20; SystemDriveTotalGB = 118 })

            $rows[0].State | Should -Be "pass"
            $rows[0].Detail | Should -BeLike "*20 GB*"
        }

        It "fails one tenth below the minimum" {
            $check = New-WinUtilBaselineCheck -Type "freeSpace" -Expect 20 -Severity "warn"
            $rows = @(Test-WinUtilBaseline -Checks @($check) -Facts @{ SystemDriveFreeGB = 19.9; SystemDriveTotalGB = 118 })

            $rows[0].State | Should -Be "warn"
        }

        It "reports info for an unreadable volume or a non numeric minimum" {
            $unread = @(Test-WinUtilBaseline -Checks @(New-WinUtilBaselineCheck -Type "freeSpace" -Expect 20 -Severity "warn") -Facts @{ SystemDriveFreeGB = $null })
            $broken = @(Test-WinUtilBaseline -Checks @(New-WinUtilBaselineCheck -Type "freeSpace" -Expect "lots" -Severity "warn") -Facts @{ SystemDriveFreeGB = 40 })

            $unread[0].State | Should -Be "info"
            $broken[0].State | Should -Be "info"
        }
    }

    Context "adminRequired" {
        It "fails a non elevated run with its own severity" {
            $check = New-WinUtilBaselineCheck -Type "adminRequired" -Expect "true" -Severity "fail"
            $rows = @(Test-WinUtilBaseline -Checks @($check) -Facts @{ IsAdmin = $false })

            $rows[0].State | Should -Be "fail"
            $rows[0].Detail | Should -BeLike "*普通用户权限*"
        }
    }
}

Describe "Get-WinUtilBaselineResult" {
    Context "A compliant machine" {
        BeforeAll {
            $script:compliantResult = Get-WinUtilBaselineResult -Config $script:baselineConfig -Facts $script:compliantFacts
        }

        It "concludes 通过 with nothing failed" {
            $script:compliantResult.Problem | Should -Be ""
            $script:compliantResult.Verdict | Should -BeLike "*通过*"
            $script:compliantResult.Summary.Fail | Should -Be 0
            $script:compliantResult.Summary.Warn | Should -Be 0
            $script:compliantResult.Summary.Pass | Should -Be $script:compliantResult.Summary.Total
        }

        It "keeps every shipped check in the table" {
            $script:compliantResult.Rows.Count | Should -Be @($script:baselineConfig.checks).Count

            foreach ($row in $script:compliantResult.Rows) {
                $row.State | Should -Be "pass"
                $row.Detail | Should -Not -BeNullOrEmpty
                (Test-WinUtilHasCJK -Text $row.Detail) | Should -BeTrue -Because "the window only ever shows Chinese, got: $($row.Detail)"
            }
        }
    }

    Context "Verdict wording" {
        It "counts severe problems and reminders separately" {
            $checks = @(
                (New-WinUtilBaselineCheck -Id "a" -Type "adminRequired" -Expect "true" -Severity "fail")
                (New-WinUtilBaselineCheck -Id "b" -Type "timeZone" -Expect "China Standard Time" -Severity "warn")
            )
            $result = Get-WinUtilBaselineResult -Config ([pscustomobject]@{ checks = $checks }) -Facts @{ IsAdmin = $false; TimeZoneId = "Pacific Standard Time" }

            $result.Summary.Fail | Should -Be 1
            $result.Summary.Warn | Should -Be 1
            $result.Summary.Total | Should -Be 2
            $result.Verdict | Should -BeLike "*体检未通过：1 项严重问题、1 项提醒*"
        }

        It "concludes 通过 but keeps the reminders visible" {
            $checks = @(
                (New-WinUtilBaselineCheck -Id "a" -Type "adminRequired" -Expect "true" -Severity "fail")
                (New-WinUtilBaselineCheck -Id "b" -Type "powerScheme" -Expect "平衡" -Severity "warn")
            )
            $result = Get-WinUtilBaselineResult -Config ([pscustomobject]@{ checks = $checks }) -Facts @{ IsAdmin = $true; PowerSchemeName = "高性能" }

            $result.Summary.Fail | Should -Be 0
            $result.Summary.Warn | Should -Be 1
            $result.Verdict | Should -BeLike "*通过*"
            $result.Verdict | Should -BeLike "*提醒*"
        }

        It "refuses to claim 通过 when no check produced a result" {
            $result = Get-WinUtilBaselineResult -Config $script:baselineConfig -Facts @{}

            $result.Summary.Pass | Should -Be 0
            $result.Verdict | Should -Not -BeLike "*通过*"
            $result.Verdict | Should -BeLike "*未完成*"
        }
    }

    Context "Unusable config" {
        It "explains a missing config instead of throwing" {
            $result = Get-WinUtilBaselineResult -Config $null -Facts $script:compliantFacts

            $result.Problem | Should -Not -BeNullOrEmpty
            (Test-WinUtilHasCJK -Text $result.Problem) | Should -BeTrue
            @($result.Rows).Count | Should -Be 0
            $result.Summary.Total | Should -Be 0
            $result.Verdict | Should -Not -BeNullOrEmpty
        }

        It "explains a check list with no checks" {
            $result = Get-WinUtilBaselineResult -Config ([pscustomobject]@{ checks = @() }) -Facts $script:compliantFacts

            $result.Problem | Should -Not -BeNullOrEmpty
        }

        It "explains checks that lost their type" {
            $broken = [pscustomobject]@{ checks = @([pscustomobject]@{ id = "oops"; label = "体检项"; severity = "warn" }) }
            $result = Get-WinUtilBaselineResult -Config $broken -Facts $script:compliantFacts

            $result.Problem | Should -Not -BeNullOrEmpty
        }

        It "accepts a single check that was not wrapped in an array" {
            $single = [pscustomobject]@{ checks = (New-WinUtilBaselineCheck -Type "adminRequired" -Expect "true" -Severity "fail") }
            $result = Get-WinUtilBaselineResult -Config $single -Facts @{ IsAdmin = $true }

            $result.Problem | Should -Be ""
            $result.Summary.Total | Should -Be 1
        }
    }
}

Describe "Baseline config" {
    BeforeAll {
        $script:checks = @($script:baselineConfig.checks)
    }

    It "carries meta information" {
        $script:baselineConfig.meta.version | Should -Not -BeNullOrEmpty
        (Test-WinUtilHasCJK -Text ([string]$script:baselineConfig.meta.site)) | Should -BeTrue
    }

    It "declares around twelve checks" {
        $script:checks.Count | Should -BeGreaterOrEqual 10
        $script:checks.Count | Should -BeLessOrEqual 16
    }

    It "keeps every check id unique and ASCII" {
        $ids = @($script:checks | ForEach-Object { [string]$_.id })

        @($ids | Select-Object -Unique).Count | Should -Be $ids.Count
        foreach ($id in $ids) {
            $id | Should -Match '^[a-z][A-Za-z0-9]*$' -Because "check ids are machine identifiers handed to the renderer, got $id"
        }
    }

    It "uses only the severities the checker understands" {
        foreach ($check in $script:checks) {
            $severity = [string]$check.severity

            # IndexOf, not -contains: the severity becomes the row state the renderer switches on
            $known = ([System.Array]::IndexOf($script:allowedSeverities, $severity) -ge 0)
            $known | Should -BeTrue -Because "severity is a machine enum, got $severity"
        }
    }

    It "uses only the types the checker implements" {
        foreach ($check in $script:checks) {
            $script:allowedTypes | Should -Contain ([string]$check.type)
        }
    }

    It "declares every field the checker reads" {
        foreach ($check in $script:checks) {
            $checkNames = @($check.PSObject.Properties.Name)

            $checkNames | Should -Contain "id"
            $checkNames | Should -Contain "type"
            $checkNames | Should -Contain "label"
            $checkNames | Should -Contain "group"
            $checkNames | Should -Contain "severity"
            $checkNames | Should -Contain "expect"
            $checkNames | Should -Contain "hint"
            $checkNames | Should -Contain "fix"
            @($check.fix.PSObject.Properties.Name) | Should -Contain "button"
            @($check.fix.PSObject.Properties.Name) | Should -Contain "text"
            $check.group | Should -Not -BeNullOrEmpty
        }
    }

    It "points only at buttons that are already routed" {
        foreach ($check in $script:checks) {
            $button = [string]$check.fix.button
            if ([string]::IsNullOrWhiteSpace($button)) { continue }

            # IndexOf, not -contains: the dispatcher matches the route key exactly, so a fix that
            # differs only in case would look valid here and dead-click in the window
            $routed = ([System.Array]::IndexOf([array]$script:routeNames, $button) -ge 0)
            $routed | Should -BeTrue -Because "$($check.id) points at an unrouted button $button"
            (Test-WinUtilHasCJK -Text ([string]$check.fix.text)) | Should -BeTrue -Because "$($check.id) names a button, so it needs a Chinese caption"
        }
    }

    It "leaves a caption empty exactly when there is nothing to click" {
        foreach ($check in $script:checks) {
            $hasButton = -not [string]::IsNullOrWhiteSpace([string]$check.fix.button)
            $hasCaption = -not [string]::IsNullOrWhiteSpace([string]$check.fix.text)

            $hasButton | Should -Be $hasCaption -Because "$($check.id) either names a fix or names none"
        }
    }

    It "writes label and hint in Chinese" {
        foreach ($check in $script:checks) {
            (Test-WinUtilHasCJK -Text ([string]$check.label)) | Should -BeTrue -Because "$($check.id) is painted as the row title"
            (Test-WinUtilHasCJK -Text ([string]$check.hint)) | Should -BeTrue -Because "$($check.id) is painted as the row tooltip"
        }
    }

    It "avoids credential shaped fields" {
        $raw = Get-Content -LiteralPath $script:baselinePath -Raw -Encoding UTF8

        $raw | Should -Not -Match '(?i)"(pass|password|passwd|secret|token|user|username|account)"\s*:\s*"[^"]'
    }
}
