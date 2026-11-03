#===========================================================================
# Tests - 打印共享的本机配置层（编辑器写进去的那份文件）
#===========================================================================

<#
    Printers and shares used to be fixed at two and three slots, edited by hand in the JSON, and
    baked into the build. The editor keeps its result in the operator's own profile instead, which
    makes three things worth holding down: the validation rules have to reject what would fail at
    install time, the save must be all-or-nothing, and startup must never let a broken file take
    printing down with it. Nothing here touches the real %LOCALAPPDATA%\winutil.
#>

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
    . (Join-Path $script:repoRoot "functions\private\EntPrinterConfig.ps1")

    function Write-WinUtilLog {
        param($Message, $Level, $Component)
        $script:LogEntries.Add("$Level|$Message")
    }
    $script:LogEntries = [System.Collections.Generic.List[string]]::new()
}

Describe "本机打印共享配置（编辑器写到哪、启动时怎么读）" {

    BeforeEach {
        $script:LogEntries = [System.Collections.Generic.List[string]]::new()
        $script:sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("entops-cfg-" + [Guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $sandbox -Force | Out-Null

        $script:embedded = [pscustomobject]@{
            formName          = "内置纸名"
            formWidthTenthMm  = 1400
            formHeightTenthMm = 2400
            colorUserCode     = "8888"
            driverDirNames    = @("drivers", "driver")
            printers          = @([pscustomobject]@{
                Name = "内置打印机"; Ip = "10.0.0.1"; PortName = "IP_10.0.0.1"
                DriverName = "RICOH PCL6"; DriverZip = "driver.zip"
                DriverFile = "ricoh.dll"; DataFile = "ricoh.GPD"; ConfigFile = "ricohConfig.dll"; HelpFile = "ricoh.hlp"
                DependentFiles = @("ricohUI.dll"); Location = "内置位置"; SupportColor = $true
            })
            shares = @([pscustomobject]@{
                Name = "内置共享"; Paths = @("\\fileserver\public"); User = "ops"; Pass = "secret"; Drive = "Z:"
            })
        }

        $script:sync = [Hashtable]::Synchronized(@{
            winutildir = $sandbox
            configs    = @{ entprinters = $embedded }
        })
    }

    AfterEach {
        Remove-Item -LiteralPath $script:sandbox -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Variable -Name sync -Scope Script -ErrorAction SilentlyContinue
    }

    function script:New-ValidPrinter {
        param([string]$Name = "前台打印机", [string]$Ip = "192.168.10.20")

        return [ordered]@{
            Name = $Name; Ip = $Ip; PortName = ""
            DriverName = "RICOH PCL6"; DriverZip = "driver.zip"
            DriverFile = "ricoh.dll"; DataFile = "ricoh.GPD"; ConfigFile = "ricohConfig.dll"; HelpFile = "ricoh.hlp"
            DependentFiles = @()
            Location = "前台"; SupportColor = $true
        }
    }

    function script:New-ValidShare {
        param([string]$Name = "公共盘", [string]$Drive = "S:")

        return [ordered]@{ Name = $Name; Paths = @("\\server\public"); User = "shareuser"; Pass = ""; Drive = $Drive }
    }

    function script:New-ValidConfig {
        return [ordered]@{
            formName = "易快报打印模式"; formWidthTenthMm = 1400; formHeightTenthMm = 2400
            colorUserCode = ""; driverDirNames = @("drivers")
            printers = @(New-ValidPrinter)
            shares   = @(New-ValidShare)
        }
    }

    Describe "Test-WinUtilEntPrinterConfig" {
        It "accepts what the install flow can actually use" {
            @(Test-WinUtilEntPrinterConfig -Config (ConvertTo-WinUtilEntPrinterConfig -Config (New-ValidConfig))) |
                Should -BeNullOrEmpty
        }

        It "requires at least one printer" {
            $config = New-ValidConfig
            $config.printers = @()
            $problems = @(Test-WinUtilEntPrinterConfig -Config (ConvertTo-WinUtilEntPrinterConfig -Config $config))

            ($problems -join "`n") | Should -Match "至少"
        }

        It "names the entry every problem belongs to" {
            # An operator fixing this at night should not have to count array indexes to find the row
            $config = New-ValidConfig
            $config.printers = @((New-ValidPrinter -Name "前台打印机" -Ip "192.168.10.20"), (New-ValidPrinter -Name "仓库打印机" -Ip "not-an-ip"))
            $problems = @(Test-WinUtilEntPrinterConfig -Config (ConvertTo-WinUtilEntPrinterConfig -Config $config))

            ($problems -join "`n") | Should -Match "仓库打印机"
            ($problems -join "`n") | Should -Not -Match "前台打印机 ："
        }

        It "rejects duplicate printer names and a blank one" {
            $config = New-ValidConfig
            $config.printers = @((New-ValidPrinter -Name "同一台" -Ip "10.1.1.1"), (New-ValidPrinter -Name "同一台" -Ip "10.1.1.2"))
            @(Test-WinUtilEntPrinterConfig -Config (ConvertTo-WinUtilEntPrinterConfig -Config $config) | Where-Object { $_ -match "重复" }).Count |
                Should -Be 1

            $blank = New-ValidConfig
            $blank.printers = @(New-ValidPrinter -Name "")
            (@(Test-WinUtilEntPrinterConfig -Config (ConvertTo-WinUtilEntPrinterConfig -Config $blank)) -join "`n") | Should -Match "名称不能为空"
        }

        It "rejects a driver entry that is missing a file name" {
            # Every one of these is passed straight to AddPrinterDriverEx; an empty one fails the install
            $config = New-ValidConfig
            $printer = New-ValidPrinter
            $printer.DataFile = " "
            $config.printers = @($printer)

            (@(Test-WinUtilEntPrinterConfig -Config (ConvertTo-WinUtilEntPrinterConfig -Config $config)) -join "`n") | Should -Match "DataFile"
        }

        It "rejects paper sizes DEVMODE cannot carry" {
            $config = New-ValidConfig
            $config.formWidthTenthMm = "10"          # under a millimetre
            $config.formHeightTenthMm = "40000"      # past the 16-bit field
            $config.formName = ""
            $problems = @(Test-WinUtilEntPrinterConfig -Config (ConvertTo-WinUtilEntPrinterConfig -Config $config))

            ($problems -join "`n") | Should -Match "纸张宽度"
            ($problems -join "`n") | Should -Match "纸张高度"
            ($problems -join "`n") | Should -Match "纸张名称"
        }

        It "rejects a share without a UNC path or with a malformed drive letter" {
            $config = New-ValidConfig
            $share = New-ValidShare
            $share.Paths = @("server:public")
            $share.Drive = "SS"
            $config.shares = @($share)
            $problems = @(Test-WinUtilEntPrinterConfig -Config (ConvertTo-WinUtilEntPrinterConfig -Config $config))

            ($problems -join "`n") | Should -Match "UNC"
            ($problems -join "`n") | Should -Match "盘符"
        }

        It "rejects two shares fighting for one drive letter" {
            $config = New-ValidConfig
            $config.shares = @((New-ValidShare -Name "甲" -Drive "S:"), (New-ValidShare -Name "乙" -Drive "S:"))

            (@(Test-WinUtilEntPrinterConfig -Config (ConvertTo-WinUtilEntPrinterConfig -Config $config)) -join "`n") | Should -Match "已被"
        }
    }

    Describe "ConvertTo-WinUtilEntPrinterConfig" {
        It "derives the port name from the address when the row leaves it blank" {
            # The install step looks the port up by name, so a blank one is a bug waiting to happen
            $normalized = ConvertTo-WinUtilEntPrinterConfig -Config (New-ValidConfig)

            $normalized.printers[0].PortName | Should -Be "IP_192.168.10.20"
        }

        It "trims typed whitespace and uppercases the drive letter" {
            $config = New-ValidConfig
            $config.printers = @(New-ValidPrinter -Name "  前台打印机  " -Ip " 192.168.10.20 ")
            $config.shares = @(New-ValidShare -Drive "s:")

            $normalized = ConvertTo-WinUtilEntPrinterConfig -Config $config

            $normalized.printers[0].Name | Should -Be "前台打印机"
            $normalized.printers[0].Ip | Should -Be "192.168.10.20"
            $normalized.shares[0].Drive | Should -Be "S:"
        }

        It "keeps the password out of the trim so a leading space survives" {
            $config = New-ValidConfig
            $config.shares = @(New-ValidShare)
            $config.shares[0].Pass = " secret "

            (ConvertTo-WinUtilEntPrinterConfig -Config $config).shares[0].Pass | Should -Be " secret "
        }

        It "turns a fractional millimetre size into whole tenths" {
            $config = New-ValidConfig
            $config.formWidthTenthMm = "1400.6"

            (ConvertTo-WinUtilEntPrinterConfig -Config $config).formWidthTenthMm | Should -Be 1401
        }
    }

    Describe "Write-WinUtilEntPrinterConfig" {
        It "saves and reads back the same number of entries" {
            $config = New-ValidConfig
            $config.printers = @((New-ValidPrinter -Name "甲"), (New-ValidPrinter -Name "乙" -Ip "10.2.2.2"), (New-ValidPrinter -Name "丙" -Ip "10.3.3.3"))
            $config.shares = @()

            @(Write-WinUtilEntPrinterConfig -Config $config) | Should -BeNullOrEmpty

            $path = Get-WinUtilEntPrinterConfigPath
            Test-Path -LiteralPath $path | Should -BeTrue
            $loaded = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
            @($loaded.printers).Count | Should -Be 3
            @($loaded.shares).Count | Should -Be 0
            $loaded.printers[2].Name | Should -Be "丙"
            $loaded.printers[2].PortName | Should -Be "IP_10.3.3.3"
        }

        It "refuses an invalid config and leaves the previous file untouched" {
            $null = Write-WinUtilEntPrinterConfig -Config (New-ValidConfig)
            $path = Get-WinUtilEntPrinterConfigPath
            $before = Get-Content -LiteralPath $path -Raw -Encoding UTF8

            $broken = New-ValidConfig
            $broken.shares[0].Drive = "NOPE"
            $problems = @(Write-WinUtilEntPrinterConfig -Config $broken)

            $problems.Count | Should -BeGreaterThan 0
            (Get-Content -LiteralPath $path -Raw -Encoding UTF8) | Should -Be $before
            -not (Test-Path -LiteralPath "$path.tmp") | Should -BeTrue
        }

        It "leaves no temporary file behind and never writes a half file" {
            $null = Write-WinUtilEntPrinterConfig -Config (New-ValidConfig)

            Test-Path -LiteralPath "$(Get-WinUtilEntPrinterConfigPath).tmp" | Should -BeFalse
        }
    }

    Describe "Update-WinUtilEntPrinterConfig" {
        It "keeps the built-in config when the machine has never been configured" {
            Update-WinUtilEntPrinterConfig | Out-Null

            $sync.configs.entprinters.Name | Should -BeNullOrEmpty
            @($sync.configs.entprinters.printers)[0].Name | Should -Be "内置打印机"
            $sync.configs.entprintersDefault | Should -Not -BeNullOrEmpty
        }

        It "swaps in the per-machine file once it exists" {
            $null = Write-WinUtilEntPrinterConfig -Config (New-ValidConfig)
            $sync.configs.entprinters = $embedded

            $loaded = Update-WinUtilEntPrinterConfig

            @($loaded.printers)[0].Name | Should -Be "前台打印机"
            @($sync.configs.entprinters.printers)[0].Name | Should -Be "前台打印机"
            @($sync.configs.entprintersDefault.printers)[0].Name | Should -Be "内置打印机"
        }

        It "falls back to the built-in config when the file cannot be parsed" {
            Set-Content -LiteralPath (Get-WinUtilEntPrinterConfigPath) -Value "{ this is not json" -Encoding UTF8

            Update-WinUtilEntPrinterConfig | Out-Null

            @($sync.configs.entprinters.printers)[0].Name | Should -Be "内置打印机"
        }

        It "falls back when the file has no printers at all" {
            Set-Content -LiteralPath (Get-WinUtilEntPrinterConfigPath) -Value '{"formName":"纸","printers":[],"shares":[]}' -Encoding UTF8

            Update-WinUtilEntPrinterConfig | Out-Null

            @($sync.configs.entprinters.printers)[0].Name | Should -Be "内置打印机"
        }

        It "loads anyway and reports the problems when a hand-edited file is only partly wrong" {
            # The editor is the way to fix it, so the file still has to load and say what is off
            $json = '{"formName":"易快报打印模式","formWidthTenthMm":1400,"formHeightTenthMm":2400,' +
                    '"colorUserCode":"","driverDirNames":["drivers"],' +
                    '"printers":[{"Name":"甲机","Ip":"10.1.1.1","PortName":"IP_10.1.1.1","DriverName":"RICOH","DriverZip":"driver.zip","DriverFile":"a.dll","DataFile":"a.GPD","ConfigFile":"c.dll","HelpFile":"a.hlp","DependentFiles":[],"Location":"前台","SupportColor":true}],' +
                    '"shares":[{"Name":"公共盘","Paths":["\\\\server\\public"],"User":"shareuser","Pass":"","Drive":"BAD"}]}'
            [System.IO.File]::WriteAllText((Get-WinUtilEntPrinterConfigPath), $json, [System.Text.UTF8Encoding]::new($false))

            $sync.configs.entprinters = $embedded
            Update-WinUtilEntPrinterConfig | Out-Null

            @($sync.configs.entprinters.shares)[0].Drive | Should -Be "BAD"
        }
    }

    Describe "Remove-WinUtilEntPrinterConfig" {
        It "goes back to the built-in config and drops the file" {
            # The sequence the operator actually causes: the app starts and caches the built-in
            # copy, the editor saves an override, 「恢复内置配置」 removes it again.
            Update-WinUtilEntPrinterConfig | Out-Null
            $null = Write-WinUtilEntPrinterConfig -Config (New-ValidConfig)
            @($sync.configs.entprinters.printers)[0].Name | Should -Be "前台打印机"

            Remove-WinUtilEntPrinterConfig

            Test-Path -LiteralPath (Get-WinUtilEntPrinterConfigPath) | Should -BeFalse
            @($sync.configs.entprinters.printers)[0].Name | Should -Be "内置打印机"
        }

        It "says so instead of quietly keeping the edited config when there is no built-in copy" {
            Remove-WinUtilEntPrinterConfig

            $LogEntries | Should -Be "WARN|没有内置配置可回退，界面仍显示刚才保存的配置"
            @($sync.configs.entprinters.printers)[0].Name | Should -Be "内置打印机"
        }
    }

}