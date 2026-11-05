#===========================================================================
# Tests - 易快报纸张与颜色的独立入口
#===========================================================================

<#
    The paper form and the mono lock used to exist only inside the full install, so a machine that
    already had the printer could not be re-set without re-running the driver work. There are now
    two entry points, which means one rule to keep: the actual spooler calls live in
    Set-WinUtilPrinterPaperAndColor, and each caller only says what success or failure means for
    itself. The first Describe holds that line; the second exercises the helper against a fake
    winspool so the argument plumbing is checked without a printer or a real service restart.
#>

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
    $script:helperPath = Join-Path $repoRoot "functions\private\Set-WinUtilPrinterPaperAndColor.ps1"
    $script:installPath = Join-Path $repoRoot "functions\private\Install-WinUtilPrinter.ps1"
    $script:handlerPath = Join-Path $repoRoot "functions\public\Invoke-WPFPrinterInstall.ps1"

    $script:helperSource = Get-Content -LiteralPath $script:helperPath -Raw -Encoding UTF8
    $script:installSource = Get-Content -LiteralPath $script:installPath -Raw -Encoding UTF8
    $script:handlerSource = Get-Content -LiteralPath $script:handlerPath -Raw -Encoding UTF8
}

Describe "One implementation behind both entry points" {
    It "keeps the spooler work inside the shared helper" {
        # Duplicated here is not merely untidy: the two paths would start writing different paper
        # names or sizes, and the operator would see the dropdown differ after an install versus
        # after a re-set, with nothing in the log to explain it.
        foreach ($source in @($script:installSource, $script:handlerSource)) {
            $source | Should -Not -Match 'Restart-Service\s+-Name\s+Spooler'
            $source | Should -Not -Match 'UseLegacyPrintDialog'
            $source | Should -Not -Match '\[EntSpool\]::RegisterPaperForm'
        }

        $script:helperSource | Should -Match 'Restart-Service\s+-Name\s+Spooler'
        $script:helperSource | Should -Match 'UseLegacyPrintDialog'
        $script:helperSource | Should -Match '\[EntSpool\]::RegisterPaperForm'
    }

    It "routes the standalone button to a handler that opens its own job" {
        $routes = Get-Content -LiteralPath (Join-Path $script:repoRoot "config\routes.json") -Raw -Encoding UTF8 | ConvertFrom-Json
        $route = $routes.PSObject.Properties["WPFPrinterFormColorOnly"].Value
        $route | Should -Not -BeNullOrEmpty
        $route.function | Should -Be "Invoke-WPFPrinterFormColorOnly"

        # A route with "work" gets wrapped in a job by the dispatcher, and the job layer keeps one
        # slot: a handler that also starts a job would have its own work refused, silently.
        $route.work | Should -BeNullOrEmpty
        $script:handlerSource | Should -Match 'function Invoke-WPFPrinterFormColorOnly'
        $script:handlerSource | Should -Match 'Start-WinUtilJob'
    }

    It "asks before interrupting whatever else is printing" {
        # Restarting the spooler is the whole cost of this button, so it has to be said out loud
        # before the job starts rather than discovered in the progress log afterwards.
        $script:handlerSource | Should -Match 'Show-WinUtilMessage'
        $script:handlerSource | Should -Match 'Spooler'
    }

    It "reuses the helper from both the install and the standalone job" {
        $script:installSource | Should -Match 'Set-WinUtilPrinterPaperAndColor\s+-Printer\s+\$Printer'
        $script:handlerSource | Should -Match 'Set-WinUtilPrinterPaperAndColor\s+-Printer\s+\$Printer'
        $script:installSource | Should -Match 'Enable-WinUtilLegacyPrintDialog'
        $script:handlerSource | Should -Match 'Enable-WinUtilLegacyPrintDialog'
    }

    It "keeps the helpers' return values out of the log pane" {
        # The operator reads Write-Host output as the whole story of the run; a bare boolean
        # landing in it looks like an error code and gets reported as one.
        foreach ($source in @($script:installSource, $script:handlerSource)) {
            foreach ($line in ($source -split "`n")) {
                if ($line -notmatch '(Set-WinUtilPrinterPaperAndColor|Enable-WinUtilLegacyPrintDialog)') { continue }
                ($line -match 'if \(-not \(') -or ($line -match '\|\s*Out-Null') |
                    Should -BeTrue -Because "call site should consume the result: $($line.Trim())"
            }
        }
    }
}

Describe "Set-WinUtilPrinterPaperAndColor" {
    BeforeAll {
        if (-not ("EntSpool" -as [type])) {
            Add-Type @"
using System.Collections.Generic;

public static class EntSpool
{
    public static List<string> Calls = new List<string>();
    public static bool FormResult = true;
    public static string Effective = "1|256|1400|2400|测试小票纸";

    public static void SetColorMode(string printerName, bool color)
    {
        Calls.Add("SetColorMode|" + printerName + "|" + color);
    }

    public static bool RegisterPaperForm(string printerName, string formName, int widthTenthMm, int heightTenthMm, int colorMode)
    {
        Calls.Add("RegisterPaperForm|" + printerName + "|" + formName + "|" + widthTenthMm + "|" + heightTenthMm + "|" + colorMode);
        return FormResult;
    }

    public static string ReadEffectiveDefaults(string printerName)
    {
        Calls.Add("ReadEffectiveDefaults|" + printerName);
        return Effective;
    }
}
"@
        }

        . $script:helperPath

        # The helper's own noise filters: the natives are already faked by EntSpool above, and its
        # log drain would reach for the real EntNative type.
        function script:Add-WinUtilEntNatives { }
        function script:Write-WinUtilEntNativeLog { }

        # The helper's whole job now is to tell the operator what the driver accepted, so the tests
        # have to read its lines back. A function shadow wins over the cmdlet for calls made from
        # this file's scope, which keeps the pane out of the test run.
        $script:HostLines = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
        function script:Write-Host {
            $null = $script:HostLines.Add(($args -join ' '))
        }
    }

    BeforeEach {
        [EntSpool]::Calls.Clear()
        [EntSpool]::FormResult = $true
        [EntSpool]::Effective = "1|256|1400|2400|测试小票纸"
        $null = $script:HostLines.Clear()
        $script:sync = [Hashtable]::Synchronized(@{
            configs = @{
                entprinters = [pscustomobject]@{
                    formName            = "测试小票纸"
                    formWidthTenthMm    = 1400
                    formHeightTenthMm   = 2400
                }
            }
        })
        # The real thing would take the developer's own print jobs down mid-test
        Mock Restart-Service { }
    }

    AfterEach {
        Remove-Variable -Name sync -Scope Script -ErrorAction SilentlyContinue
    }

    It "registers the form with the sizes from the config" {
        $printer = [pscustomobject]@{ Name = "前台打印机"; SupportColor = $true }

        Set-WinUtilPrinterPaperAndColor -Printer $printer | Should -BeTrue

        [EntSpool]::Calls | Should -Contain "RegisterPaperForm|前台打印机|测试小票纸|1400|2400|0"
    }

    It "locks a black and white unit to monochrome" {
        $printer = [pscustomobject]@{ Name = "财务打印机"; SupportColor = $false }

        Set-WinUtilPrinterPaperAndColor -Printer $printer | Should -BeTrue

        [EntSpool]::Calls | Should -Contain "SetColorMode|财务打印机|False"
    }

    It "leaves a colour-capable printer in colour" {
        # Forcing mono here would silently cost the front desk its colour printing
        $printer = [pscustomobject]@{ Name = "前台打印机"; SupportColor = $true }

        $null = Set-WinUtilPrinterPaperAndColor -Printer $printer

        @([EntSpool]::Calls | Where-Object { $_ -like "SetColorMode*" }) | Should -BeNullOrEmpty
    }

    It "restarts the spooler only after the driver accepted the form" {
        [EntSpool]::FormResult = $false
        $printer = [pscustomobject]@{ Name = "前台打印机"; SupportColor = $true }

        Set-WinUtilPrinterPaperAndColor -Printer $printer | Should -BeFalse

        Should -Invoke Restart-Service -Times 0 -Exactly
    }

    It "carries on when the spooler refuses to restart" {
        # Without elevation, or with a job holding the service, the form is still registered: the
        # size shows up once something else restarts the service, so the work is not lost.
        Mock Restart-Service { throw "拒绝访问。" }
        $printer = [pscustomobject]@{ Name = "前台打印机"; SupportColor = $true }

        Set-WinUtilPrinterPaperAndColor -Printer $printer | Should -BeTrue
    }

    It "carries the mono intent into the registry DEVMODE, not only the queue call" {
        # SetPrinter alone does not stick on this class of driver; the blob the spooler reloads at
        # startup is the one that decides, so it has to carry dmColor too.
        $printer = [pscustomobject]@{ Name = "财务打印机"; SupportColor = $false }

        Set-WinUtilPrinterPaperAndColor -Printer $printer | Should -BeTrue

        [EntSpool]::Calls | Should -Contain "RegisterPaperForm|财务打印机|测试小票纸|1400|2400|1"
    }

    It "reads the defaults back from the driver after the restart" {
        $printer = [pscustomobject]@{ Name = "前台打印机"; SupportColor = $true }

        Set-WinUtilPrinterPaperAndColor -Printer $printer | Should -BeTrue

        $read = @([EntSpool]::Calls | Where-Object { $_ -like "ReadEffectiveDefaults*" })
        $read.Count | Should -BeGreaterThan 0 -Because "a write the driver never acknowledged is not a finished job"
    }

    It "confirms the paper size only when the read-back matches" {
        $printer = [pscustomobject]@{ Name = "前台打印机"; SupportColor = $true }

        Set-WinUtilPrinterPaperAndColor -Printer $printer | Should -BeTrue

        ($script:HostLines -join "`n") | Should -Match '默认纸张已生效'
    }

    It "says out loud when the driver clamps the custom size back" {
        # 现场就是这样：通用 V4 驱动只认自己清单里的纸，把 140×240 退回 A4。工具如果照旧报
        # 「配置完成」，运维到门店对着下拉框才发现选不到，白跑一趟。
        [EntSpool]::Effective = "2|9|2100|2970|"
        $printer = [pscustomobject]@{ Name = "前台打印机"; SupportColor = $true }

        Set-WinUtilPrinterPaperAndColor -Printer $printer | Should -BeTrue

        $text = $script:HostLines -join "`n"
        $text | Should -Match '没有采纳 140×240mm'
        $text | Should -Match '自定义纸张尺寸'
        $text | Should -Not -Match '默认纸张已生效'
    }

    It "reports a mono lock that the driver ignored" {
        [EntSpool]::Effective = "2|256|1400|2400|测试小票纸"
        $printer = [pscustomobject]@{ Name = "财务打印机"; SupportColor = $false }

        Set-WinUtilPrinterPaperAndColor -Printer $printer | Should -BeTrue

        $text = $script:HostLines -join "`n"
        $text | Should -Match '黑白未生效'
        $text | Should -Match '默认纸张已生效'
    }
}
