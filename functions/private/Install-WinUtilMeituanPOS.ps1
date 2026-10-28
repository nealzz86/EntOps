function Install-WinUtilMeituanPOS {

    <#

    .SYNOPSIS
        Installs the Meituan POS client from a shared folder, or opens the official site

    .DESCRIPTION
        Meituan POS is not published to winget or Chocolatey and its PC installer is
        distributed through the official site and service providers, so this resolves the
        installer from the company shares first and falls back to opening the download page.

    #>

    $downloadPage = "https://shouyin.meituan.com/"

    Step-WinUtilJob -Status "正在查找美团收银安装包" -Percent 10

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
            Where-Object { $_.Name -imatch "^(meituan|美团).*\.exe$" -or $_.Name -imatch "(收银|POS).*\.exe$" }) |
            Select-Object -First 1
        if ($hit) { $source = $hit.FullName; break }
    }

    if ($source) {
        Write-WinUtilLog -Component "RemoteOps" -Message "Using shared installer for Meituan POS: $source"
        Step-WinUtilJob -Status "已找到共享目录安装包，启动安装程序" -Percent 60
        Start-Process -FilePath $source
        Step-WinUtilJob -Status "安装程序已启动，请按向导完成安装" -Percent 90
        Write-Host "美团收银安装程序已启动，请按向导完成安装。"
        Write-Host "安装完成后需要门店激活码，请联系信息部或美团服务商协助激活。"
        return
    }

    Write-WinUtilLog -Component "RemoteOps" -Message "No shared Meituan POS installer found, opening download page: $downloadPage"
    Step-WinUtilJob -Status "共享目录未找到安装包，打开美团收银官网" -Percent 60
    Start-Process $downloadPage
    Write-Host "共享目录中没有找到美团收银安装包，已打开美团收银官网。"
    Write-Host "美团收银 PC 端安装包由服务商/信息部提供，请获取后放到共享目录根目录再重试。"
    Step-WinUtilJob -Status "请在官网或联系服务商获取安装包" -Percent 90
}
