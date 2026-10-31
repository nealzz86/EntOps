#===========================================================================
# Tests - Interface text is Chinese

<#
    The product requirement is an all-Chinese interface, so the strings that reach the window
    (progress label, dialogs, job labels) are guarded the same way the routing config is: a rule,
    not a review habit.

    Only string literals are inspected. A call that interpolates a variable is checked where that
    variable is assigned, because there the value is known. Comment blocks are not part of the
    AST, so a .EXAMPLE that still shows English text cannot fail the build.

    This file is deliberately ASCII-only: the CJK range is written as an escape, so the test does
    not depend on how the host decodes it.
#>

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

    # Argument names whose value is painted into the window. -Overlay is deliberately absent: it
    # names a taskbar icon (logo/checkmark/warning), not text.
    $script:textArguments = @("Status", "Description", "Message", "Title")
    $script:textCommands = @{
        "Step-WinUtilJob"     = $script:textArguments
        "Start-WinUtilJob"    = $script:textArguments
        "Show-WinUtilMessage" = $script:textArguments
        "Write-WinUtilISOLog" = @("Message")
    }

    # Names that stay as they are: the brand in a dialog title bar.
    $script:allowedText = @("WinUtil")

    # Matched by type name: not every AST type name resolves in every host, and these two are the
    # only ones the rule needs.
    $script:stringTypes = @("StringConstantExpressionAst", "ExpandableStringExpressionAst")

    function Test-WinUtilTopLevelText {
        param($Node)

        # FindAll also returns the literals nested inside an interpolation, and those belong to the
        # expression they sit in, not to the interface text being checked.
        $ancestor = $Node.Parent
        while ($ancestor) {
            if ($ancestor.GetType().Name -in $script:stringTypes) { return $false }
            $ancestor = $ancestor.Parent
        }
        return $true
    }

    function Get-WinUtilEnglishOnlyText {
        param($Expression)

        if ($null -eq $Expression) { return @() }

        $literals = @($Expression.FindAll({
            param($node)
            $node.GetType().Name -in $script:stringTypes
        }, $true) | Where-Object { Test-WinUtilTopLevelText -Node $_ })
        if ($literals.Count -eq 0) { return @() }
        if ($literals.Value -match "[\u4e00-\u9fff]") { return @() }
        # Interpolated text is its variable's problem: "...$label..." reads as English here only
        # because the label was set in English, and that assignment is where the fix belongs.
        $variableTokens = '\$\{[^}]*\}|\$\([^)]*\)|\$[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*'
        return @($literals | Where-Object {
            $bare = [regex]::Replace($_.Value, $variableTokens, "")
            $bare -match "[A-Za-z]{3,}" -and $script:allowedText -notcontains $_.Value.Trim()
        })
    }

    function Find-WinUtilEnglishText {
        param([string]$Path)

        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)
        $violations = [System.Collections.Generic.List[object]]::new()

        $commands = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst]
        }, $true))

        foreach ($command in $commands) {
            $name = $command.GetCommandName()
            $wanted = $null
            if ($name -and $script:textCommands.ContainsKey($name)) {
                $wanted = $script:textCommands[$name]
            }

            $candidates = [System.Collections.Generic.List[object]]::new()
            if ($wanted) {
                for ($i = 1; $i -lt $command.CommandElements.Count; $i++) {
                    $element = $command.CommandElements[$i]
                    # Pairwise rather than NamedArgumentAst: PowerShell 5.1 leaves the parameter
                    # and its value as two elements, PowerShell 7 merges them.
                    if ($element -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }
                    if ($wanted -notcontains $element.ParameterName) { continue }
                    if ($i + 1 -ge $command.CommandElements.Count) { continue }
                    $candidates.Add([pscustomobject]@{
                        Argument = $element.ParameterName
                        Value    = $command.CommandElements[$i + 1]
                    })
                    $i++
                }
            }

            # The ISO status log is a window control, so its lines are interface text even though
            # they are written through a helper instead of the progress bar. It takes its message
            # positionally, which is why the check below is not part of the named-argument loop.
            $isLoggerLine = $name -eq "Write-WinUtilISOLog" -or
                $command.CommandElements[0].Extent.Text -match '\$Logger$'
            if ($isLoggerLine) {
                if ($command.CommandElements.Count -lt 2) { continue }
                $first = $command.CommandElements[1]
                if ($first -is [System.Management.Automation.Language.CommandParameterAst]) { continue }
                $candidates.Add([pscustomobject]@{ Argument = "Line"; Value = $first })
            } elseif ($name -like "*MessageBox*::Show*") {
                # Show(text, caption, ...) is always called positionally
                for ($i = 1; $i -le 2 -and $i -lt $command.CommandElements.Count; $i++) {
                    $candidates.Add([pscustomobject]@{ Argument = "Show"; Value = $command.CommandElements[$i] })
                }
            }

            foreach ($candidate in $candidates) {
                foreach ($text in (Get-WinUtilEnglishOnlyText -Expression $candidate.Value)) {
                    $violations.Add([pscustomobject]@{
                        File     = $Path
                        Line     = $text.Extent.StartLineNumber
                        Command  = $name
                        Argument = $candidate.Argument
                        Text     = $text.Value
                    })
                }
            }
        }

        return $violations
    }

    $collected = [System.Collections.Generic.List[object]]::new()
    foreach ($root in @((Join-Path $script:repoRoot "functions"), (Join-Path $script:repoRoot "scripts"))) {
        foreach ($file in Get-ChildItem -Path $root -Recurse -File -Filter *.ps1) {
            foreach ($violation in (Find-WinUtilEnglishText -Path $file.FullName)) {
                $collected.Add($violation)
            }
        }
    }
    $script:found = @($collected)
}

Describe "Interface text" {
    It "leaves no English-only text in the window's progress labels and dialogs" {
        $report = ($script:found | ForEach-Object {
            "  {0}:{1} {2} -{3}: {4}" -f (Split-Path $_.File -Leaf), $_.Line, $_.Command, $_.Argument, $_.Text
        }) -join "`n"

        $script:found.Count | Should -Be 0 -Because ("every string the window paints must be Chinese.{0}{1}" -f "`n", $report)
    }

    It "keeps the job identifiers the log greps for out of the translation" {
        # The guard above proves the window is Chinese. This proves it did not get there by
        # translating the log component and job name, which the log reading rules match on.
        $jobSource = Get-Content -LiteralPath (Join-Path $script:repoRoot "functions\private\Start-WinUtilJob.ps1") -Raw
        $jobSource | Should -Match 'Write-WinUtilLog -Component \$Name'
        $jobSource | Should -Match '\$sync\.ActiveJob = \$Name'
    }
}
