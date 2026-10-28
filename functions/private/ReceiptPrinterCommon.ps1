function Test-WinUtilIPv4 {

    <#

    .SYNOPSIS
        Whether a string is a dotted-quad IPv4 address

    #>
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    $parts = $Text.Trim() -split '\.'
    if ($parts.Count -ne 4) { return $false }
    foreach ($part in $parts) {
        if ($part -notmatch '^\d{1,3}$') { return $false }
        if ([int]$part -gt 255) { return $false }
    }
    return $true
}

function Append-WinUtilReceiptLog {

    <#

    .SYNOPSIS
        Appends a timestamped line to the receipt printer output box on the UI thread

    #>
    param(
        [string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR")]
        [string]$Level = "INFO"
    )

    Write-WinUtilLog -Level $Level -Component "ReceiptPrinter" -Message $Message

    Invoke-WPFUIThread -Async -Parameters @{
        LogLine = "[$((Get-Date).ToString('HH:mm:ss'))] $Message"
    } -ScriptBlock {
        param($LogLine)

        $box = $sync["WPFReceiptOutput"]
        if ($null -eq $box) { return }

        if ($box.Text -eq "就绪。请先「搜索网段内的打印机」或填入打印机当前 IP。") {
            $box.Text = $LogLine
        } else {
            $box.Text += "`n$LogLine"
        }
        $box.ScrollToEnd()
    }
}
