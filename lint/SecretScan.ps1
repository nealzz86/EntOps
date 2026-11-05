#Requires -Version 5.1

<#

.SYNOPSIS
    Fails when a field credential or a build artifact has entered the version-controlled source tree

.DESCRIPTION
    The compiled product is supposed to carry the share accounts: a machine without them cannot
    map the drives offline. The repository is the opposite - it is public, so only the template
    configs belong in it. This script therefore checks the tracked tree, never the product:
    overlay configs, compiled scripts and driver packages must stay untracked, and no value read
    from a local overlay may appear in a file git knows about.

    Run it from Compile.ps1 (before the product is written) and from the repository's CI.

.PARAMETER Path
    Repository root; defaults to the parent of this script

.EXAMPLE
    powershell -File lint\SecretScan.ps1

#>

param(
    [string]$Path = (Split-Path -Parent $PSScriptRoot),
    # A build product to check in addition to the tracked tree. The product is *supposed* to carry
    # the site's accounts, so the extension and size rules do not apply to it - only the value
    # comparison does. Pass it when a build is meant to leave the machine, to prove that it does
    # not carry those values.
    [string]$ArtifactPath
)

$ErrorActionPreference = "Stop"

# Anything matching these is a build artifact or a site-specific file and must never be tracked
$forbiddenTracked = @(
    @{ Pattern = '\.local\.json$'; Why = "现场凭据覆盖配置" },
    @{ Pattern = '(^|/)winutil\.ps1$'; Why = "编译产物" },
    @{ Pattern = '\.exe$'; Why = "打包产物" },
    @{ Pattern = '\.dll$'; Why = "第三方二进制" },
    @{ Pattern = '(^|/)drivers?/'; Why = "打印机驱动包目录" },
    @{ Pattern = '\.zip$'; Why = "驱动压缩包" },
    @{ Pattern = '\.iso$'; Why = "镜像文件" }
)

# Text files worth grepping; binaries are covered by the extension rules above
$scannable = @(".ps1", ".psm1", ".json", ".xaml", ".xml", ".md", ".yaml", ".yml", ".bat", ".cmd", ".txt")

# Values that mean "filled in by the site, not a real secret"
$placeholders = @("change_me", "changeme", "placeholder", "example", "password", "enterpasswordhere", "示例", "占位", "样例", "<")

# Only values sitting under a site-specific key count. Walking into every string would report
# driver filenames and other ordinary configuration as if they were secrets.
$secretKeys = '^(Pass|Password|Passwd|Secret|Token|UserCode|colorUserCode|User|UserName|Account|Ip|IPAddress|Paths|Path)$'

$problems = [System.Collections.Generic.List[string]]::new()

Set-Location -LiteralPath $Path

$isRepo = & git rev-parse --is-inside-work-tree 2>$null
if ($LASTEXITCODE -ne 0 -or $isRepo -ne "true") {
    Write-Output "跳过凭据扫描：当前目录不是 git 工作树（$Path）。"
    exit 0
}

$tracked = @(& git ls-files)
if ($LASTEXITCODE -ne 0 -or $tracked.Count -eq 0) {
    Write-Output "跳过凭据扫描：git ls-files 没有返回文件。"
    exit 0
}

foreach ($file in $tracked) {
    $normalized = $file -replace '\\', '/'
    foreach ($rule in $forbiddenTracked) {
        if ($normalized -match $rule.Pattern) {
            $problems.Add("不该入库的文件已被跟踪：$file（$($rule.Why)）")
            break
        }
    }

    if (Test-Path -LiteralPath $file -PathType Leaf) {
        $size = (Get-Item -LiteralPath $file).Length
        if ($size -gt 5MB) {
            $problems.Add("仓库里的文件过大：$file（$([math]::Round($size / 1MB, 2)) MB），源码仓库不放二进制")
        }
    }
}

function Add-WinUtilSecretStrings {
    <#
    .SYNOPSIS
        Collects every leaf string below a site-specific key, however deeply it is nested
    #>
    param(
        [object]$Node,
        [string]$Where,
        [System.Collections.Generic.List[psobject]]$Sink
    )

    if ($null -eq $Node) { return }

    if ($Node -is [System.Management.Automation.PSCustomObject]) {
        foreach ($p in $Node.PSObject.Properties) {
            Add-WinUtilSecretStrings -Node $p.Value -Where "$Where.$($p.Name)" -Sink $Sink
        }
        return
    }

    if ($Node -is [array]) {
        foreach ($item in $Node) { Add-WinUtilSecretStrings -Node $item -Where $Where -Sink $Sink }
        return
    }

    $text = [string]$Node
    # Short values (drive letters, widths) would match ordinary code and produce noise
    if ($text.Length -ge 4) {
        $null = $Sink.Add([pscustomobject]@{ Where = $Where; Value = $text })
    }
}

function Find-WinUtilSecrets {
    <#
    .SYNOPSIS
        Walks a parsed overlay and reports the values that identify this site
    #>
    param(
        [object]$Node,
        [string]$Where,
        [System.Collections.Generic.List[psobject]]$Sink
    )

    if ($Node -is [System.Management.Automation.PSCustomObject]) {
        foreach ($p in $Node.PSObject.Properties) {
            if ($p.Name -match $secretKeys) {
                Add-WinUtilSecretStrings -Node $p.Value -Where "$Where.$($p.Name)" -Sink $Sink
            } else {
                Find-WinUtilSecrets -Node $p.Value -Where "$Where.$($p.Name)" -Sink $Sink
            }
        }
        return
    }

    if ($Node -is [array]) {
        foreach ($item in $Node) { Find-WinUtilSecrets -Node $item -Where $Where -Sink $Sink }
    }
}

# Secret values are only known locally, so the check is "do these strings appear in a tracked file"
$secretValues = [System.Collections.Generic.List[psobject]]::new()
$localConfigs = @(Get-ChildItem -Path config -Filter "*.local.json" -File -ErrorAction SilentlyContinue)

foreach ($local in $localConfigs) {
    $overlay = Get-Content -LiteralPath $local.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    Find-WinUtilSecrets -Node $overlay -Where $local.Name -Sink $secretValues
}

$scannableTracked = @($tracked | Where-Object {
    $extension = [IO.Path]::GetExtension($_)
    $scannable -contains $extension -and $_ -notlike "*.local.json"
})

foreach ($secret in $secretValues) {
    $hits = @(Select-String -Path $scannableTracked -SimpleMatch -Pattern $secret.Value -ErrorAction SilentlyContinue)
    foreach ($hit in $hits) {
        $problems.Add("现场凭据出现在被跟踪的文件里：$($hit.Path)（来自 $($secret.Where) 的值）")
    }
}

if ($ArtifactPath) {
    # An overlay that is missing or renamed yields zero values, and a value comparison against
    # nothing passes silently. Treat that as a failure: the check exists to prove a build is clean.
    if ($secretValues.Count -eq 0) {
        $problems.Add("没有从 config\\*.local.json 读到任何现场凭据值，无法证明产物『$ArtifactPath』不含它们")
    } elseif (-not (Test-Path -LiteralPath $ArtifactPath -PathType Leaf)) {
        $problems.Add("指定的产物不存在，无法检查：$ArtifactPath")
    } else {
        $artifactText = Get-Content -LiteralPath $ArtifactPath -Raw -Encoding UTF8
        $leaked = @($secretValues | Where-Object { $artifactText.Contains($_.Value) })
        foreach ($secret in $leaked) {
            $problems.Add("现场凭据出现在产物里：$([IO.Path]::GetFileName($ArtifactPath))（来自 $($secret.Where) 的值）")
        }
        if ($leaked.Count -eq 0) {
            Write-Output "   产物脱敏检查通过：$([IO.Path]::GetFileName($ArtifactPath)) 未命中 $($secretValues.Count) 个现场值。"
        }
    }
}

# A credential field left filled in inside a committed config means the template itself leaked
foreach ($config in @($scannableTracked | Where-Object { $_ -like "config/*.json" })) {
    $obj = Get-Content -LiteralPath $config -Raw -Encoding UTF8 | ConvertFrom-Json

    $nodes = [System.Collections.Generic.Queue[psobject]]::new()
    $null = $nodes.Enqueue([pscustomobject]@{ Node = $obj; Where = $config })
    while ($nodes.Count -gt 0) {
        $current = $nodes.Dequeue()
        $node = $current.Node

        if ($node -is [array]) {
            foreach ($item in $node) { $null = $nodes.Enqueue([pscustomobject]@{ Node = $item; Where = $current.Where }) }
            continue
        }
        if ($node -isnot [System.Management.Automation.PSCustomObject]) { continue }

        foreach ($p in $node.PSObject.Properties) {
            if ($p.Value -is [System.Management.Automation.PSCustomObject] -or $p.Value -is [array]) {
                $null = $nodes.Enqueue([pscustomobject]@{ Node = $p.Value; Where = "$($current.Where).$($p.Name)" })
                continue
            }
            if ($p.Name -notmatch '^(Pass|Password|Passwd|Secret|Token|UserCode|colorUserCode)$') { continue }

            $text = if ($null -eq $p.Value) { "" } else { [string]$p.Value }
            # An empty field is the template's shape; only a filled-in one can be a real credential.
            if ($text.Trim().Length -eq 0) { continue }
            $isPlaceholder = @($placeholders | Where-Object { $text -like "*$_*" }).Count -gt 0
            if (-not $isPlaceholder) {
                $problems.Add("已提交的配置里写了真实凭据：$($current.Where).$($p.Name)，请改成空字符串并移到 *.local.json")
            }
        }
    }
}

if ($problems.Count -gt 0) {
    Write-Output "== 凭据扫描未通过 =="
    foreach ($problem in @($problems | Select-Object -Unique)) {
        Write-Output "   $problem"
    }
    Write-Output "   共 $(@($problems | Select-Object -Unique).Count) 条。现场账号与驱动包只应存在于 config\*.local.json 与仓库之外。"
    exit 1
}

Write-Output "   凭据扫描通过：跟踪文件 $($tracked.Count) 个，检查凭据值 $($secretValues.Count) 个。"
exit 0
