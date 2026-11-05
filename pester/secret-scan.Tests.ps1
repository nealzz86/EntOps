Set-StrictMode -Version 3

BeforeAll {
    $script:scan = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..\lint\SecretScan.ps1")).Path

    function Invoke-WinUtilSecretScan {
        <#
        .SYNOPSIS
            Runs the scanner in a child process against a throwaway repository

        .DESCRIPTION
            The scanner ends with `exit`, so an in-process call would take Pester with it. A child
            process also proves the build gate behaves the way Compile.ps1 actually uses it.
        #>
        param([string]$Repo, [string]$Artifact)

        $arguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $scan, "-Path", $Repo)
        if ($Artifact) { $arguments += @("-ArtifactPath", $Artifact) }

        $text = & powershell.exe @arguments 2>&1
        return [pscustomobject]@{ Code = $LASTEXITCODE; Text = ($text -join "`n") }
    }

    function New-WinUtilScanRepo {
        <#
        .SYNOPSIS
            Creates a git work tree with one template config and, optionally, its local overlay
        #>
        param([string]$Name, [switch]$WithOverlay)

        $repo = Join-Path $env:TEMP "secret-scan-$Name"
        if (Test-Path -LiteralPath $repo) { Remove-Item -LiteralPath $repo -Recurse -Force }
        $null = New-Item -ItemType Directory -Path (Join-Path $repo "config") -Force

        # git's line-ending advice lands on stderr, which StrictMode turns into a failure.
        $preference = $ErrorActionPreference
        $ErrorActionPreference = "SilentlyContinue"
        $null = & git -C $repo init
        $ErrorActionPreference = $preference

        # The template's account label is deliberately different from the overlay's: the scanner
        # counts account names as site values, so reusing one here would trip the tracked-file check.
        $template = @'
{
    "shares": [ { "Name": "共享文件夹一", "User": "共享账号", "Pass": "" } ]
}
'@
        Set-Content -LiteralPath (Join-Path $repo "config\entprinters.json") -Value $template -Encoding UTF8
        if ($WithOverlay) {
            $overlay = @'
{
    "shares": [ { "Name": "共享文件夹一", "User": "shareuser", "Pass": "FakeSitePass123" } ]
}
'@
            Set-Content -LiteralPath (Join-Path $repo "config\entprinters.local.json") -Value $overlay -Encoding UTF8
        }
        # Only the template is staged: a tracked overlay is itself the thing the scanner reports.
        # core.safecrlf stays off so git's line-ending advice does not spray into the test log.
        $preference = $ErrorActionPreference
        $ErrorActionPreference = "SilentlyContinue"
        $null = & git -C $repo -c core.safecrlf=false add config/entprinters.json
        $ErrorActionPreference = $preference
        return $repo
    }

    function New-WinUtilArtifact {
        param([string]$Repo, [string]$Name, [string]$Body)

        $path = Join-Path $Repo $Name
        Set-Content -LiteralPath $path -Value $Body -Encoding UTF8
        return $path
    }
}

Describe "SecretScan 的产物脱敏检查" {
    It "产物干净时放行并说明比对了多少个现场值" {
        $repo = New-WinUtilScanRepo -Name "clean" -WithOverlay
        $artifact = New-WinUtilArtifact -Repo $repo -Name "product.ps1" -Body '$sync.configs.entprinters = "共享账号"'

        $result = Invoke-WinUtilSecretScan -Repo $repo -Artifact $artifact

        $result.Code | Should -Be 0
        $result.Text | Should -Match "产物脱敏检查通过"
    }

    It "产物带着现场口令时拦下" {
        $repo = New-WinUtilScanRepo -Name "dirty" -WithOverlay
        $artifact = New-WinUtilArtifact -Repo $repo -Name "product.ps1" -Body '"Pass": "FakeSitePass123"'

        $result = Invoke-WinUtilSecretScan -Repo $repo -Artifact $artifact

        $result.Code | Should -Be 1
        $result.Text | Should -Match "现场凭据出现在产物里"
    }

    It "读不到现场值时不许当成通过" {
        # Without this, renaming or emptying the overlay would make the artifact check vacuous.
        $repo = New-WinUtilScanRepo -Name "nooverlay"
        $artifact = New-WinUtilArtifact -Repo $repo -Name "product.ps1" -Body "nothing to see"

        $result = Invoke-WinUtilSecretScan -Repo $repo -Artifact $artifact

        $result.Code | Should -Be 1
        $result.Text | Should -Match "无法证明产物"
    }

    It "指定的产物不存在时报错而不是静默" {
        $repo = New-WinUtilScanRepo -Name "missing" -WithOverlay

        $result = Invoke-WinUtilSecretScan -Repo $repo -Artifact (Join-Path $repo "gone.ps1")

        $result.Code | Should -Be 1
        $result.Text | Should -Match "指定的产物不存在"
    }

    It "已提交的模板里填了真实口令也能拦下" {
        # The placeholder list used to start with an empty string, which matches everything and
        # turned this branch off: an empty field must pass, a filled one must not.
        $repo = New-WinUtilScanRepo -Name "template" -WithOverlay
        $template = @'
{
    "shares": [ { "Name": "共享文件夹一", "User": "shareuser", "Pass": "FakeSitePass123" } ]
}
'@
        Set-Content -LiteralPath (Join-Path $repo "config\entprinters.json") -Value $template -Encoding UTF8

        $result = Invoke-WinUtilSecretScan -Repo $repo

        $result.Code | Should -Be 1
        $result.Text | Should -Match "已提交的配置里写了真实凭据"
    }
}
