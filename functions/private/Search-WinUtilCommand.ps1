function Search-WinUtilCommand {

    <#

    .SYNOPSIS
        Ranks the palette's command catalog against what the operator typed

    .DESCRIPTION
        The pages are built lazily, so when the palette opens there is no control tree to walk:
        config\commands.json is the catalog instead, and this is the ranking done against it. No
        window, no file, no route - the palette can call it on every keystroke.

        Weight falls away from the label: an exact label, then a label that starts with the query,
        then a label that contains it, then the entry's keywords, then its group, then its button
        name. Entries that score alike keep the order the config has them in, so the list never
        reshuffles under someone still typing. Pinyin is deliberately not attempted: there is no
        table to do it with, and a guess would be worse than the keywords field, which spells the
        synonyms out.

        Nothing here throws. A catalog that is missing, empty or half filled simply yields fewer
        results, and an entry with no label or button is skipped because the palette could not
        render or run it.

    .PARAMETER Query
        The text typed so far, trimmed of surrounding whitespace. Blank text matches nothing, which
        is how the palette is told to show its hint instead of the whole catalog.

    .PARAMETER Commands
        The command entries to search, normally $sync.configs.commands.commands. The enclosing
        config node is accepted too.

    .PARAMETER Limit
        How many results come back, best first.

    #>

    param(
        [string]$Query,
        $Commands,
        [int]$Limit = 12
    )

    $text = if ($null -eq $Query) { "" } else { $Query.Trim() }
    if ($text.Length -eq 0 -or $null -eq $Commands -or $Limit -lt 1) { return @() }

    $entries = Get-WinUtilCommandEntry -Commands $Commands

    $found = [System.Collections.Generic.List[object]]::new()
    $order = 0
    foreach ($entry in $entries) {
        if ($null -eq $entry) { continue }

        $button = [string]$entry.button
        $label = [string]$entry.label
        # A row the palette cannot name or press is not a result, it is a broken config entry
        if ([string]::IsNullOrWhiteSpace($button) -or [string]::IsNullOrWhiteSpace($label)) { continue }

        $score = 0
        $match = ""

        if (0 -eq [string]::Compare($label, $text, $true)) {
            $score = 100
            $match = "label"
        } elseif (Test-WinUtilCommandPrefix -Text $label -Query $text) {
            $score = 80
            $match = "label"
        } elseif (Test-WinUtilCommandContains -Text $label -Query $text) {
            $score = 60
            $match = "label"
        } else {
            foreach ($token in @(([string]$entry.keywords) -split '\s+')) {
                if ([string]::IsNullOrWhiteSpace($token)) { continue }
                if ((Test-WinUtilCommandContains -Text $token -Query $text) -or
                    (Test-WinUtilCommandContains -Text $text -Query $token)) {
                    $score = 40
                    $match = "keyword"
                    break
                }
            }
        }

        if ($score -eq 0 -and (Test-WinUtilCommandContains -Text ([string]$entry.group) -Query $text)) {
            $score = 20
            $match = "group"
        }

        if ($score -eq 0) {
            # Typed names reach a control the operator knows by its code name, which is the one
            # case where an English query is worth honouring
            $name = $button -replace '^WPF', ''
            if (Test-WinUtilCommandContains -Text $name -Query $text) {
                $score = 10
                $match = "button"
            }
        }

        if ($score -eq 0) { continue }

        $found.Add([pscustomobject]@{
            Button   = $button
            Label    = $label
            Group    = [string]$entry.group
            Tab      = [string]$entry.tab
            Action   = [string]$entry.action
            Keywords = [string]$entry.keywords
            Match    = $match
            Score    = $score
            Order    = $order
        })

        $order++
    }

    $ranked = @($found | Sort-Object -Property @{Expression = "Score"; Descending = $true },
                                                 @{Expression = "Order"; Descending = $false })

    return @($ranked | Select-Object -First $Limit | ForEach-Object {
        [pscustomobject]@{
            Button   = $_.Button
            Label    = $_.Label
            Group    = $_.Group
            Tab      = $_.Tab
            Action   = $_.Action
            Keywords = $_.Keywords
            Match    = $_.Match
            Score    = $_.Score
        }
    })
}

function Get-WinUtilCommandGroup {

    <#

    .SYNOPSIS
        The catalog's group names, in the order the config lists them

    .DESCRIPTION
        Groups come from the navigation structure, so the palette can head its result list and order
        its shortcuts off this instead of a second list nobody maintains. Repeats collapse to their
        first appearance; a blank group is not a group.

    .PARAMETER Commands
        The command entries to read, as Search-WinUtilCommand takes them

    #>

    param($Commands)

    if ($null -eq $Commands) { return @() }

    $names = [ordered]@{}
    foreach ($entry in (Get-WinUtilCommandEntry -Commands $Commands)) {
        if ($null -eq $entry) { continue }

        $group = ([string]$entry.group).Trim()
        if ($group.Length -eq 0 -or $names.Contains($group)) { continue }
        $names[$group] = $true
    }

    return @($names.Keys)
}

function Format-WinUtilCommandResult {

    <#

    .SYNOPSIS
        One result row's display text: group, label, and what pressing it does

    .DESCRIPTION
        The palette paints rows as plain text, so this decides how a command reads: the group in
        brackets says where it lives, and the verb at the end says whether Enter presses a button or
        merely opens a page. Pure formatting, no state, no window.

    .PARAMETER Command
        A result from Search-WinUtilCommand

    #>

    param([pscustomobject]$Command)

    if ($null -eq $Command) { return "" }

    $label = ([string]$Command.Label).Trim()
    if ([string]::IsNullOrWhiteSpace($label)) { return "" }

    # "run" is what the catalog means by default, so a row that says nothing still reads correctly
    $verb = if ([string]$Command.Action -eq "goto") { "打开页面" } else { "执行" }
    $group = ([string]$Command.Group).Trim()

    $prefix = if ($group.Length -gt 0) { "[$group] " } else { "" }

    return "{0}{1} · {2}" -f $prefix, $label, $verb
}

function Test-WinUtilCommandContains {

    <#

    .SYNOPSIS
        Whether one string holds another, ignoring case and nothing else

    .DESCRIPTION
        Ordinal and literal on purpose: the query is whatever the operator typed, so a wildcard or a
        bracket in it stays a character rather than turning into a pattern.

    #>

    param([string]$Text, [string]$Query)

    if ([string]::IsNullOrEmpty($Text) -or [string]::IsNullOrEmpty($Query)) { return $false }

    return $Text.IndexOf($Query, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
}

function Test-WinUtilCommandPrefix {

    <#

    .SYNOPSIS
        Whether a string begins with the query, ignoring case

    #>

    param([string]$Text, [string]$Query)

    if ([string]::IsNullOrEmpty($Text) -or [string]::IsNullOrEmpty($Query)) { return $false }

    return $Text.IndexOf($Query, [System.StringComparison]::OrdinalIgnoreCase) -eq 0
}

function Get-WinUtilCommandEntry {

    <#

    .SYNOPSIS
        The command entries in a catalog, however the caller handed them over

    .DESCRIPTION
        The palette passes the entry array; a caller that passes the whole config node gets its
        commands list instead, and anything that is not a list of entries becomes an empty one.

    #>

    param($Commands)

    if ($null -eq $Commands) { return @() }

    $entries = @($Commands)
    if ($entries.Count -eq 1 -and $null -ne $entries[0] -and
        $null -ne (Get-Member -InputObject $entries[0] -Name "commands" -MemberType Properties)) {
        $entries = @($entries[0].commands)
    }

    return $entries
}
