#===========================================================================
# Tests - Command palette catalog and search (interface search / Ctrl+K)
#===========================================================================

<#
    The palette searches a static catalog rather than the control tree, because most pages are
    built lazily and do not exist yet when the box opens. Two halves therefore have to hold
    together: the ranking, tested against an invented catalog, and config\commands.json, tested
    against the files that give its buttons and tabs meaning.

    This file is deliberately ASCII-only. Every Chinese string is built from code points, so the
    assertions do not depend on how the host decodes this file's bytes: the queries and the
    expected row text stay exactly the characters the operator would type and read.
#>

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
    $script:commandsPath = Join-Path $script:repoRoot "config\commands.json"
    $script:routesPath = Join-Path $script:repoRoot "config\routes.json"
    $script:xamlPath = Join-Path $script:repoRoot "xaml\inputXML.xaml"

    . (Join-Path $script:repoRoot "functions\private\Search-WinUtilCommand.ps1")

    # A Chinese string from its code points, so nothing here depends on host decoding.
    function script:Join-WinUtilGlyph {
        param([int[]]$Codes)

        $text = [System.Text.StringBuilder]::new()
        foreach ($code in $Codes) { $null = $text.Append([char]$code) }
        return $text.ToString()
    }

    function script:New-WinUtilPaletteCommand {
        param(
            [string]$Button,
            [string]$Label,
            [string]$Group,
            [string]$Tab = "WPFTab1BT",
            [string]$Keywords = "",
            [string]$Action = "run"
        )

        # Shaped like ConvertFrom-Json's output: the lower-case field names the config uses
        return [pscustomobject]@{
            button   = $Button
            label    = $Label
            group    = $Group
            tab      = $Tab
            keywords = $Keywords
            action   = $Action
        }
    }

    # Words the fixture and the expectations are built from
    $script:wordPrint = Join-WinUtilGlyph @(0x6253, 0x5370)                                     # printing
    $script:wordPrintShare = Join-WinUtilGlyph @(0x6253, 0x5370, 0x5171, 0x4EAB)               # print sharing
    $script:wordPrintShareSetup = Join-WinUtilGlyph @(0x6253, 0x5370, 0x5171, 0x4EAB, 0x8BBE, 0x7F6E)
    $script:wordPrintList = Join-WinUtilGlyph @(0x6253, 0x5370, 0x6E05, 0x5355)
    $script:wordNetPrint = Join-WinUtilGlyph @(0x7F51, 0x7EDC, 0x6253, 0x5370)
    $script:wordWirelessPrint = Join-WinUtilGlyph @(0x65E0, 0x7EBF, 0x6253, 0x5370)
    $script:wordPortsUsed = Join-WinUtilGlyph @(0x7AEF, 0x53E3, 0x5360, 0x7528)
    $script:wordNetDiag = Join-WinUtilGlyph @(0x7F51, 0x7EDC, 0x8BCA, 0x65AD)
    $script:wordScan = Join-WinUtilGlyph @(0x626B, 0x63CF)
    $script:wordPort = Join-WinUtilGlyph @(0x7AEF, 0x53E3)
    $script:wordPaperBox = Join-WinUtilGlyph @(0x7EB8, 0x76D2)
    $script:wordImageBuild = Join-WinUtilGlyph @(0x955C, 0x50CF, 0x5236, 0x4F5C)
    $script:wordBootDisk = Join-WinUtilGlyph @(0x542F, 0x52A8, 0x76D8)
    $script:wordRefreshHealth = Join-WinUtilGlyph @(0x5237, 0x65B0, 0x603B, 0x89C8)
    $script:wordPingTest = "Ping " + (Join-WinUtilGlyph @(0x6D4B, 0x8BD5))
    $script:wordBaselineCheck = Join-WinUtilGlyph @(0x57FA, 0x7EBF, 0x4F53, 0x68C0)
    $script:wordUpdate = Join-WinUtilGlyph @(0x66F4, 0x65B0)
    $script:wordVerbRun = Join-WinUtilGlyph @(0x6267, 0x884C)
    $script:wordVerbGoto = Join-WinUtilGlyph @(0x6253, 0x5F00, 0x9875, 0x9762)
    $script:separator = " " + [char]0x00B7 + " "

    $script:catalog = @(
        (New-WinUtilPaletteCommand -Button "WPFFakePrinterShare" -Label $wordPrintShareSetup -Group $wordPrintShare -Tab "WPFTab7BT" -Keywords "$wordScan $wordPort")
        (New-WinUtilPaletteCommand -Button "WPFFakeNetPorts" -Label $wordPortsUsed -Group $wordNetDiag -Tab "WPFTab11BT" -Keywords "$wordPrint $wordPaperBox")
        (New-WinUtilPaletteCommand -Button "WPFFakePrintPage" -Label $wordPrint -Group $wordPrintShare -Tab "WPFTab7BT" -Action "goto")
        (New-WinUtilPaletteCommand -Button "WPFFakeNetRefresh" -Label $wordRefreshHealth -Group $wordNetDiag -Tab "WPFTab11BT" -Keywords $wordScan)
        (New-WinUtilPaletteCommand -Button "WPFFakePingTool" -Label $wordPingTest -Group $wordNetDiag -Tab "WPFTab11BT")
        (New-WinUtilPaletteCommand -Button "WPFFakeIsoWriter" -Label $wordImageBuild -Group $wordImageBuild -Tab "WPFTab5BT" -Keywords ("iso " + $wordBootDisk))
        (New-WinUtilPaletteCommand -Button "WPFFakeNoGroup" -Label $wordBaselineCheck -Group "")
    )

    # Two rows that score alike: the config order has to be what separates them
    $script:tieCatalog = @(
        (New-WinUtilPaletteCommand -Button "WPFFakeWirelessPrint" -Label $wordWirelessPrint -Group $wordPrintShare)
        (New-WinUtilPaletteCommand -Button "WPFFakeNetPrint" -Label $wordNetPrint -Group $wordPrintShare)
        (New-WinUtilPaletteCommand -Button "WPFFakePrintTop" -Label $wordPrintList -Group $wordPrintShare)
    )

    $script:realConfig = Get-Content -LiteralPath $script:commandsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $script:realCatalog = @($script:realConfig.commands)
    $script:routeNames = @((Get-Content -LiteralPath $script:routesPath -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties.Name)
    $script:xamlText = Get-Content -LiteralPath $script:xamlPath -Raw -Encoding UTF8
    $script:navTabs = @([regex]::Matches($script:xamlText, 'Name="(WPFTab\d+BT)"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    # The AppX page has no sidebar toggle but is a real page: the palette navigates by index, so
    # every TabItem counts as a page a command may point at.
    $script:pageTabs = @([regex]::Matches($script:xamlText, 'Name="(WPFTab\d+)"') | ForEach-Object { "$($_.Groups[1].Value)BT" } | Sort-Object -Unique)
}

Describe "Search-WinUtilCommand" {
    It "ranks a label prefix above another entry's keyword match" {
        $found = @(Search-WinUtilCommand -Query $script:wordPrint -Commands $script:catalog)

        $found[0].Button | Should -Be "WPFFakePrintPage" -Because "an exact label match is the best match there is"
        $found[1].Button | Should -Be "WPFFakePrinterShare"
        $found[1].Match | Should -Be "label"
        $found[1].Score | Should -Be 80
        $found[2].Button | Should -Be "WPFFakeNetPorts"
        $found[2].Match | Should -Be "keyword"
        $found[2].Score | Should -Be 40
    }

    It "sorts an exact label ahead of a label that only starts the same way" {
        $found = @(Search-WinUtilCommand -Query $script:wordPrint -Commands $script:catalog)

        $found[0].Score | Should -Be 100
        $found[0].Match | Should -Be "label"
        $found[1].Score | Should -BeLessThan 100
    }

    It "keeps the config order for entries that score alike" {
        $found = @(Search-WinUtilCommand -Query $script:wordPrint -Commands $script:tieCatalog)

        $found.Count | Should -Be 3
        (($found | ForEach-Object { $_.Button }) -join ",") | Should -Be "WPFFakePrintTop,WPFFakeWirelessPrint,WPFFakeNetPrint"
        $found[0].Score | Should -Be 80 -Because "its label is the only one that starts with the query"
        $found[1].Score | Should -Be 60
        $found[2].Score | Should -Be 60
        $found[2].Button | Should -Be "WPFFakeNetPrint" -Because "two equal scores are the config's own order, not a reshuffle"
    }

    It "returns nothing for blank or whitespace-only text" {
        # The palette paints a hint instead of the whole catalog, which is only cheap if this
        # answers with an empty list rather than every command it has.
        @(Search-WinUtilCommand -Query "" -Commands $script:catalog).Count | Should -Be 0
        @(Search-WinUtilCommand -Query "   " -Commands $script:catalog).Count | Should -Be 0
        @(Search-WinUtilCommand -Query "`t  `r`n " -Commands $script:catalog).Count | Should -Be 0
        @(Search-WinUtilCommand -Commands $script:catalog).Count | Should -Be 0
    }

    It "matches labels without regard to case" {
        $lower = @(Search-WinUtilCommand -Query "ping" -Commands $script:catalog)
        $upper = @(Search-WinUtilCommand -Query "PING" -Commands $script:catalog)

        $lower.Count | Should -Be 1
        $lower[0].Button | Should -Be "WPFFakePingTool"
        $lower[0].Match | Should -Be "label"
        $upper.Count | Should -Be 1
        $upper[0].Button | Should -Be $lower[0].Button
        $upper[0].Score | Should -Be $lower[0].Score
    }

    It "still finds a command whose only match is its button name" {
        $found = @(Search-WinUtilCommand -Query "writer" -Commands $script:catalog)

        $found.Count | Should -Be 1
        $found[0].Button | Should -Be "WPFFakeIsoWriter"
        $found[0].Match | Should -Be "button"
        $found[0].Score | Should -Be 10
        $found[0].Label | Should -Be $script:wordImageBuild
    }

    It "carries the fields the row and the click handler need" {
        $found = @(Search-WinUtilCommand -Query $script:wordPrint -Commands $script:catalog)

        foreach ($field in @("Button", "Label", "Group", "Tab", "Action", "Keywords", "Match", "Score")) {
            $found[0].PSObject.Properties.Name | Should -Contain $field
        }
        $found[0].Action | Should -Be "goto"
        $found[1].Label | Should -Be $script:wordPrintShareSetup
        $found[1].Group | Should -Be $script:wordPrintShare
        $found[1].Tab | Should -Be "WPFTab7BT"
        $found[1].Action | Should -Be "run"
        $found[1].Keywords | Should -Be "$($script:wordScan) $($script:wordPort)"
    }

    It "trims the query before matching" {
        $padded = @(Search-WinUtilCommand -Query ("  " + $script:wordPrint + "  ") -Commands $script:catalog)
        $plain = @(Search-WinUtilCommand -Query $script:wordPrint -Commands $script:catalog)

        (($padded | ForEach-Object { $_.Button }) -join ",") | Should -Be (($plain | ForEach-Object { $_.Button }) -join ",")
    }

    It "respects the limit and keeps the best rows" {
        $found = @(Search-WinUtilCommand -Query $script:wordPrint -Commands $script:catalog -Limit 2)

        $found.Count | Should -Be 2
        $found[0].Button | Should -Be "WPFFakePrintPage"
        $found[1].Button | Should -Be "WPFFakePrinterShare"
        @(Search-WinUtilCommand -Query $script:wordPrint -Commands $script:catalog -Limit 0).Count | Should -Be 0
    }

    It "holds its ground on a catalog that is missing, blank or half built" {
        $broken = @(
            $null,
            "not an entry",
            @{button = "WPFFakeHash"; label = "whatever" },
            [pscustomobject]@{button = "WPFFakeNoLabel"; group = $script:wordPrintShare; keywords = $script:wordPrint },
            [pscustomobject]@{label = $script:wordPrint; group = $script:wordPrintShare },
            [pscustomobject]@{button = "WPFFakeNoFields" },
            [pscustomobject]@{button = "WPFFakeStillHere"; label = $script:wordPrint; group = $script:wordPrintShare }
        )

        { Search-WinUtilCommand -Query $script:wordPrint -Commands $null } | Should -Not -Throw
        { Search-WinUtilCommand -Query $script:wordPrint -Commands @() } | Should -Not -Throw
        { Search-WinUtilCommand -Query $script:wordPrint -Commands $broken } | Should -Not -Throw
        { Search-WinUtilCommand -Query $script:wordScan -Commands ([pscustomobject]@{oops = 1 }) } | Should -Not -Throw
        @(Search-WinUtilCommand -Query $script:wordPrint -Commands $null).Count | Should -Be 0

        # The entries with no label, or no button, are skipped even when their keywords match: a
        # row that cannot be named cannot be read, and a row that cannot be pressed cannot run
        $found = @(Search-WinUtilCommand -Query $script:wordPrint -Commands $broken)
        $found.Count | Should -Be 1
        $found[0].Button | Should -Be "WPFFakeStillHere"
    }

    It "takes the whole config node as well as its commands list" {
        $node = [pscustomobject]@{meta = [pscustomobject]@{version = "1" }; commands = $script:catalog }

        @(Search-WinUtilCommand -Query $script:wordPrint -Commands $node).Count | Should -Be 3
        @(Get-WinUtilCommandGroup -Commands $node).Count | Should -Be 3
    }
}

Describe "Get-WinUtilCommandGroup" {
    It "lists each group once, in the order the catalog uses them" {
        $groups = @(Get-WinUtilCommandGroup -Commands $script:catalog)

        $groups.Count | Should -Be 3
        $groups[0] | Should -Be $script:wordPrintShare
        $groups[1] | Should -Be $script:wordNetDiag
        $groups[2] | Should -Be $script:wordImageBuild
    }

    It "ignores blank and missing groups and survives having no catalog at all" {
        @(Get-WinUtilCommandGroup -Commands $null).Count | Should -Be 0
        @(Get-WinUtilCommandGroup -Commands @()).Count | Should -Be 0
        @(Get-WinUtilCommandGroup -Commands "not an entry").Count | Should -Be 0
        @(Get-WinUtilCommandGroup -Commands @([pscustomobject]@{button = "WPFX"; label = "x" })).Count | Should -Be 0
        @(Get-WinUtilCommandGroup -Commands @($null, [pscustomobject]@{button = "WPFY"; label = "y" })).Count | Should -Be 0
    }
}

Describe "Format-WinUtilCommandResult" {
    It "says what pressing a run row does" {
        $row = [pscustomobject]@{Group = $script:wordPrintShare; Label = $script:wordPrintShareSetup; Action = "run" }

        Format-WinUtilCommandResult -Command $row | Should -Be ("[{0}] {1}{2}{3}" -f $script:wordPrintShare, $script:wordPrintShareSetup, $script:separator, $script:wordVerbRun)
    }

    It "says that pressing a goto row only opens its page" {
        $row = [pscustomobject]@{Group = $script:wordPrintShare; Label = $script:wordPrint; Action = "goto" }

        Format-WinUtilCommandResult -Command $row | Should -Be ("[{0}] {1}{2}{3}" -f $script:wordPrintShare, $script:wordPrint, $script:separator, $script:wordVerbGoto)
    }

    It "paints the same row the same way every time and never fails on an empty one" {
        $row = [pscustomobject]@{Group = $script:wordNetDiag; Label = $script:wordPortsUsed; Action = "run" }

        Format-WinUtilCommandResult -Command $row | Should -Be (Format-WinUtilCommandResult -Command $row)
        Format-WinUtilCommandResult -Command ([pscustomobject]@{Label = $script:wordPrint }) | Should -Be ("{0}{1}{2}" -f $script:wordPrint, $script:separator, $script:wordVerbRun)
        Format-WinUtilCommandResult -Command ([pscustomobject]@{Group = $script:wordPrintShare; Label = ""; Action = "run" }) | Should -Be ""
        { Format-WinUtilCommandResult -Command $null } | Should -Not -Throw
    }

    It "formats what the search actually returned" {
        $found = @(Search-WinUtilCommand -Query $script:wordPrint -Commands $script:catalog -Limit 1)

        Format-WinUtilCommandResult -Command $found[0] | Should -Be ("[{0}] {1}{2}{3}" -f $script:wordPrintShare, $script:wordPrint, $script:separator, $script:wordVerbGoto)
    }
}

Describe "Command catalog config" {
    It "parses as JSON behind a versioned wrapper" {
        $script:realConfig.meta.version | Should -Be "1"
        @($script:realConfig.commands).Count | Should -BeGreaterOrEqual 45
    }

    It "names a button the router knows, or a sidebar entry when it only opens a page" {
        $invalid = [System.Collections.Generic.List[string]]::new()
        foreach ($entry in $script:realCatalog) {
            if ($script:routeNames -contains $entry.button) { continue }
            if ($entry.action -eq "goto" -and $script:navTabs -contains $entry.button) { continue }
            $invalid.Add("$($entry.button) is neither a routes.json key nor a nav ToggleButton")
        }

        $invalid.Count | Should -Be 0 -Because ($invalid | Out-String)
    }

    It "shows the sidebar entry every command navigates through" {
        $invalid = [System.Collections.Generic.List[string]]::new()
        foreach ($entry in $script:realCatalog) {
            if ($script:pageTabs -notcontains $entry.tab) {
                $invalid.Add("$($entry.button) wants tab $($entry.tab), which is not a page in the XAML")
            }
        }

        $invalid.Count | Should -Be 0 -Because ($invalid | Out-String)
    }

    It "only offers the two actions the palette can act on" {
        $invalid = @($script:realCatalog | Where-Object { "run", "goto" -notcontains [string]$_.action } | ForEach-Object { $_.button })

        $invalid | Should -BeNullOrEmpty -Because "run presses the button and goto only opens its page"
    }

    It "labels every command in Chinese and files it under a Chinese group" {
        $invalid = [System.Collections.Generic.List[string]]::new()
        foreach ($entry in $script:realCatalog) {
            if ([string]$entry.label -notmatch '[\u4e00-\u9fff]') { $invalid.Add("$($entry.button) has a label with no Chinese in it") }
            if ([string]$entry.group -notmatch '[\u4e00-\u9fff]') { $invalid.Add("$($entry.button) has a group with no Chinese in it") }
        }

        $invalid.Count | Should -Be 0 -Because ($invalid | Out-String)
    }

    It "keeps the groups to the handful the sidebar is made of" {
        $groups = @(Get-WinUtilCommandGroup -Commands $script:realCatalog)

        $groups.Count | Should -BeGreaterOrEqual 10
        $groups.Count | Should -BeLessOrEqual 12
        $groups | Should -Contain $script:wordPrintShare
        @($groups | Where-Object { [string]$_ -notmatch '[\u4e00-\u9fff]' }).Count | Should -Be 0
    }

    It "presses each button once, not twice under two names" {
        $duplicates = @($script:realCatalog | Group-Object { [string]$_.button } | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })

        $duplicates | Should -BeNullOrEmpty
    }

    It "carries the fields a row is built from" {
        $invalid = [System.Collections.Generic.List[string]]::new()
        foreach ($entry in $script:realCatalog) {
            foreach ($field in @("button", "label", "group", "tab", "keywords", "action")) {
                if (@($entry.PSObject.Properties.Name) -notcontains $field -or
                    [string]::IsNullOrWhiteSpace([string]$entry.$field)) {
                    $invalid.Add("$($entry.button) is missing $field")
                }
            }
        }

        $invalid.Count | Should -Be 0 -Because ($invalid | Out-String)
    }

    It "brings the print page back when an operator types the word for printer" {
        $found = @(Search-WinUtilCommand -Query $script:wordPrint -Commands $script:realCatalog -Limit 40)

        $found.Count | Should -BeGreaterThan 0
        $found[0].Button | Should -Be "WPFOverviewGoPrinter" -Because "the page named for printing is the exact best answer"
        $found[0].Tab | Should -Be "WPFTab7BT"
        $found.Button | Should -Contain "WPFPrinterInstall"
        $found.Button | Should -Contain "WPFReceiptScan"
    }

    It "brings the update policies back when an operator types the word for update" {
        $found = @(Search-WinUtilCommand -Query $script:wordUpdate -Commands $script:realCatalog -Limit 40)

        $found.Count | Should -BeGreaterThan 0
        $found[0].Button | Should -Be "WPFOverviewGoUpdates"
        ($found | Where-Object { $_.Tab -eq "WPFTab4BT" }).Count | Should -BeGreaterThan 0
        $found.Button | Should -Contain "WPFUpdatessecurity"
        $found.Button | Should -Contain "WPFUpdatesdisable"
    }

    It "reaches every page from the catalog, so no feature is only findable by clicking" {
        $reachable = @($script:realCatalog | ForEach-Object { [string]$_.tab } | Sort-Object -Unique)

        $missing = @($script:navTabs | Where-Object { $reachable -notcontains $_ })
        $missing | Should -BeNullOrEmpty -Because "a page the palette cannot open is a page it cannot search"
    }
}
