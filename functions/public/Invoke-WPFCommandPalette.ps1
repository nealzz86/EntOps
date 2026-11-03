function Invoke-WPFCommandPalette {

    <#

    .SYNOPSIS
        Opens, closes or toggles the search palette

    #>

    param(
        [Parameter(Mandatory = $false)]
        [ValidateSet("Show", "Hide", "Toggle", "Refresh")]
        [string]$Action = "Toggle",

        [Parameter(Mandatory = $false)]
        [string]$Button
    )

    $popup = $sync["PalettePopup"]
    if ($null -eq $popup) {
        Write-WinUtilLog -Level "WARN" -Component "Palette" -Message "PalettePopup control is missing."
        return
    }

    if ($Action -eq "Refresh") {
        Update-WinUtilCommandPalette
        return
    }

    $shouldOpen = switch ($Action) {
        "Show" { $true }
        "Hide" { $false }
        default { -not $popup.IsOpen }
    }

    if (-not $shouldOpen) {
        $popup.IsOpen = $false
        return
    }

    $popup.IsOpen = $true
    Update-WinUtilCommandPalette
    Invoke-WPFUIThread -ScriptBlock {
        $box = $sync["WPFPaletteInput"]
        if ($box) {
            $box.Focus()
            $box.SelectAll()
        }
    }
}

function Update-WinUtilCommandPalette {

    <#

    .SYNOPSIS
        Re-searches the command catalog with whatever is in the palette box

    #>

    param([string]$Query)

    if ([string]::IsNullOrEmpty($Query)) {
        $box = $sync["WPFPaletteInput"]
        $Query = if ($box) { [string]$box.Text } else { "" }
    }

    $catalog = @()
    if ($sync.configs.commands -and $sync.configs.commands.commands) {
        $catalog = @($sync.configs.commands.commands)
    }

    $found = @(Search-WinUtilCommand -Query $Query -Commands $catalog)
    $sync.PaletteMatches = $found
    $sync.PaletteIndex = 0

    Show-WinUtilCommandPaletteResults -Items $found -SelectedIndex 0 -Query $Query
}

function Move-WinUtilCommandPaletteSelection {

    <#

    .SYNOPSIS
        Moves the keyboard selection one row up or down

    #>

    param([ValidateSet("Up", "Down")][string]$Direction)

    $items = @($sync.PaletteMatches)
    if ($items.Count -eq 0) { return }

    $current = 0
    if ($sync.PaletteIndex) { $current = [int]$sync.PaletteIndex }

    # Wraps rather than stopping: a palette with a dozen rows should not need twelve keystrokes to
    # reach the other end
    $next = if ($Direction -eq "Down") { ($current + 1) % $items.Count } else { ($current - 1 + $items.Count) % $items.Count }
    $sync.PaletteIndex = $next

    Show-WinUtilCommandPaletteResults -Items $items -SelectedIndex $next -Query ([string]$sync.WPFPaletteInput.Text)
}

function Invoke-WPFCommandPaletteRun {

    <#

    .SYNOPSIS
        Runs the command the operator picked in the palette

    .DESCRIPTION
        Shows the page first, then presses the real button. Doing it in that order means the action
        still arrives through the normal routing - confirmations, job wrapping and progress included
        - and the operator can see what the button it just pressed does.

    #>

    param($Command)

    if ($null -eq $Command) { return }

    Invoke-WPFCommandPalette -Action "Hide"

    $tab = [string]$Command.Tab
    # Any WPFTabNBT names the page, whether or not the sidebar has a toggle for it: AppX has none,
    # and Invoke-WPFTab only ever unchecks the toggles that actually exist.
    if ($tab -match '^WPFTab\d+BT$') {
        Invoke-WPFTab -ClickedTab $tab
    }

    if ([string]::IsNullOrWhiteSpace([string]$Command.Button)) { return }

    Invoke-WPFButton -Button ([string]$Command.Button)
}

function Invoke-WPFPaletteKey {

    <#

    .SYNOPSIS
        Handles the keys pressed while the palette box has focus

    #>

    param([System.Windows.Input.Key]$Key)

    switch ($Key) {
        "Escape" { Invoke-WPFCommandPalette -Action "Hide"; return $true }
        "Down" { Move-WinUtilCommandPaletteSelection -Direction "Down"; return $true }
        "Up" { Move-WinUtilCommandPaletteSelection -Direction "Up"; return $true }
        "Enter" {
            $items = @($sync.PaletteMatches)
            if ($items.Count -eq 0) { return $true }
            $index = 0
            if ($sync.PaletteIndex) { $index = [int]$sync.PaletteIndex }
            if ($index -ge $items.Count) { $index = 0 }
            Invoke-WPFCommandPaletteRun -Command $items[$index]
            return $true
        }
    }

    return $false
}
