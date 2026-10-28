function Install-WinUtilSunloginEnterprise {

    <#

    .SYNOPSIS
        Installs the Sunlogin enterprise SOS client from a shared folder or the official CDN

    .DESCRIPTION
        Sunlogin enterprise is not published to winget or Chocolatey and the public download page
        hides the enterprise entry, so this resolves the installer from the company shares first
        and falls back to the official down.oray.com direct link, which only serves requests that
        look like a browser. The installer itself runs interactively; silent flags are unverified.

    #>

    $is64 = [Environment]::Is64BitOperatingSystem
    $fileName = if ($is64) { "SunloginSOS_1.2.1.61234_x64.exe" } else { "SunloginSOS_1.2.1.61234_Win32.exe" }
    $downloadUrl = "https://down.oray.com/sunlogin/windows/$fileName"
    $target = Join-Path $env:TEMP $fileName

    Step-WinUtilJob -Status "正在查找向日葵企业版安装包" -Percent 10

    $source = $null
    $shareCfg = $sync.configs.entprinters
    $roots = @()
    foreach ($share in @($shareCfg.shares)) {
        foreach ($path in @($share.Paths)) { $roots += $path }
        if ($share.Drive) { $roots += [string]$share.Drive + "\" }
    }

    foreach ($root in ($roots | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $root -ErrorAction SilentlyContinue)) { continue }
        $hit = @(Get-ChildItem -LiteralPath $root -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -imatch "^Sunlogin.*\.exe$" -or $_.Name -imatch "向日葵.*(企业|SOS).*\.exe$" }) |
            Select-Object -First 1
        if ($hit) { $source = $hit.FullName; break }
    }

    if ($source) {
        Write-WinUtilLog -Component "RemoteOps" -Message "Using shared installer for Sunlogin enterprise: $source"
        Step-WinUtilJob -Status "已找到共享目录安装包" -Percent 60
    } else {
        Write-WinUtilLog -Component "RemoteOps" -Message "No shared installer found, downloading from official CDN: $downloadUrl"
        Step-WinUtilJob -Status "正在从贝锐官方服务器下载向日葵企业版" -Percent 30
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        } catch { }
        $ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        Invoke-WebRequest -Uri $downloadUrl -OutFile $target -UserAgent $ua `
            -Headers @{ Referer = "https://sunlogin.oray.com/" } -TimeoutSec 300
        $size = if (Test-Path -LiteralPath $target) { (Get-Item -LiteralPath $target).Length } else { 0 }
        if ($size -lt 1MB) {
            throw "下载的安装包不完整（$size 字节）。请确认电脑能访问外网，或把向日葵企业版安装包放到共享目录根目录后重试。"
        }
        $source = $target
        Step-WinUtilJob -Status "下载完成（$([Math]::Round($size / 1MB, 1)) MB）" -Percent 60
    }

    Write-WinUtilLog -Component "RemoteOps" -Message "Launching Sunlogin enterprise installer: $source"
    Start-Process -FilePath $source
    Step-WinUtilJob -Status "安装程序已启动，请按向导完成安装" -Percent 90

    Write-Host "向日葵企业版（SOS 被控端）安装程序已启动，请按向导完成安装。"
    Write-Host "安装完成后请在客户端上生成识别码或绑定葵码，并由信息部在管理平台确认绑定。"
}
