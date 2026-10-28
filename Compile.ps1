param (
    [switch]$Run
)

$OFS = "`r`n"

# Site specific values (share accounts, printer addresses) live in config\<name>.local.json, which
# is not in version control. An overlay replaces whole arrays, so it carries the section it changes
# in full and nothing else.
function Merge-WinUtilConfigValue {
    param($Base, $Overlay)

    if ($Overlay -isnot [System.Management.Automation.PSCustomObject]) { return $Overlay }
    if ($Base -isnot [System.Management.Automation.PSCustomObject]) { return $Overlay }

    $merged = [ordered]@{}
    foreach ($p in $Base.PSObject.Properties) { $merged[$p.Name] = $p.Value }
    foreach ($p in $Overlay.PSObject.Properties) {
        $merged[$p.Name] = if ($merged.Contains($p.Name)) {
            Merge-WinUtilConfigValue -Base $merged[$p.Name] -Overlay $p.Value
        } else { $p.Value }
    }
    return [pscustomobject]$merged
}

# Variable to sync between runspaces
$sync = [Hashtable]::Synchronized(@{})
$sync.configs = @{}

$script = (Get-Content -Path scripts\start.ps1 -Encoding UTF8) -replace '#{replaceme}', (Get-Date -Format 'yy.MM.dd')
$isLocalCompile = -not [string]::Equals($env:GITHUB_ACTIONS, "true", [StringComparison]::OrdinalIgnoreCase)
$script = $script -replace '#{islocalcompile}', $isLocalCompile.ToString().ToLowerInvariant()

$script += Get-ChildItem -Path functions -Recurse -File | ForEach-Object {
    Get-Content -Path $_.FullName -Raw -Encoding UTF8
}

Get-ChildItem config -File | Where-Object { $_.Name -notlike "*.local.json" } | ForEach-Object {
    $obj = Get-Content -Path $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json

    if ($_.Name -eq "applications.json") {
        $fixed = [ordered]@{}
        foreach ($p in $obj.PSObject.Properties) {
            $fixed["WPFInstall$($p.Name)"] = $p.Value
        }
        $obj = [pscustomobject]$fixed
    }

    $overlayPath = Join-Path $_.DirectoryName "$($_.BaseName).local.json"
    if (Test-Path -LiteralPath $overlayPath) {
        $obj = Merge-WinUtilConfigValue -Base $obj -Overlay (Get-Content -LiteralPath $overlayPath -Raw -Encoding UTF8 | ConvertFrom-Json)
        Write-Output "   合入本地覆盖配置 $($_.BaseName).local.json"
    }

    $json = $obj | ConvertTo-Json -Depth 10

    $sync.configs[$_.BaseName] = $obj
    $script += "`$sync.configs.$($_.BaseName) = @'`r`n$json`r`n'@ | ConvertFrom-Json"
}

$xaml = Get-Content -Path xaml\inputXML.xaml -Raw -Encoding UTF8
$script += "`$inputXML = @'`r`n$xaml`r`n'@"

$autounattendXml = Get-Content -Path tools\autounattend.xml -Raw -Encoding UTF8
$script += "`$WinUtilAutounattendXml = @'`r`n$autounattendXml`r`n'@"

$script += Get-Content -Path scripts\main.ps1 -Raw -Encoding UTF8

Set-Content -Path winutil.ps1 -Value $script -Encoding UTF8

if ($Run) {
    .\Winutil.ps1
}
