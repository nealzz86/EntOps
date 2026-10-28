function New-WinUtilNetToolResult {

    <#

    .SYNOPSIS
        The shape every network tool hands back: result rows, notes for the log, an error

    #>

    param(
        [object[]]$Rows = @(),
        [string[]]$Notes = @(),
        [string]$Problem = $null
    )

    return @{Rows = @($Rows); Notes = @($Notes); Problem = $Problem}
}

function New-WinUtilNetToolError {

    <#

    .SYNOPSIS
        A tool that refused to run, with the reason phrased for the operator

    #>

    param([string]$Message)

    return New-WinUtilNetToolResult -Problem $Message
}

function New-WinUtilNetToolRow {
    param([string]$Name, [string]$Detail, [string]$Status = "")
    return [pscustomobject]@{Name = $Name; Detail = $Detail; Status = $Status}
}

function ConvertFrom-WinUtilIPv4 {

    <#

    .SYNOPSIS
        A dotted quad as the 32 bit number it stands for, or null when it is not one

    #>

    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $parts = $Text.Trim() -split '\.'
    if ($parts.Count -ne 4) { return $null }

    $value = [long]0
    foreach ($part in $parts) {
        if ($part -notmatch '^\d{1,3}$') { return $null }
        if ([int]$part -gt 255) { return $null }
        $value = ($value * 256) + [int]$part
    }
    return $value
}

function ConvertTo-WinUtilIPv4 {

    <#

    .SYNOPSIS
        The 32 bit number back into a dotted quad

    #>

    param([long]$Value)

    if ($Value -lt 0 -or $Value -gt 4294967295) { return "" }
    $a = [int][Math]::Floor($Value / 16777216)
    $b = [int][Math]::Floor(($Value % 16777216) / 65536)
    $c = [int][Math]::Floor(($Value % 65536) / 256)
    $d = [int]($Value % 256)
    return "$a.$b.$c.$d"
}

function ConvertFrom-WinUtilNetMask {

    <#

    .SYNOPSIS
        A subnet mask as its prefix length, or null when the bits are not contiguous

    #>

    param([string]$Text)

    $value = ConvertFrom-WinUtilIPv4 -Text $Text
    if ($null -eq $value) { return $null }

    $bits = 0
    $remaining = $value
    for ($i = 0; $i -lt 32; $i++) {
        if ($remaining -ge [Math]::Pow(2, 31 - $i)) {
            $remaining -= [Math]::Pow(2, 31 - $i)
            $bits++
        } elseif ($remaining -eq 0) {
            return $bits
        } else {
            return $null
        }
    }
    if ($remaining -eq 0) { return $bits }
    return $null
}

function Get-WinUtilNetIpBlock {

    <#

    .SYNOPSIS
        Reads an address written either way round and works out everything about its subnet

    .DESCRIPTION
        Operators type "192.168.1.20/24" and "192.168.1.20 255.255.255.0", and the mask form is
        what a device left misconfigured shows them. A mask whose bits are broken up is reported
        rather than quietly rounded, because that is a wrong setting on the console rather than a
        number to look at.

    #>

    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return @{Ok = $false; Message = "请输入 IP 地址，例如 192.168.1.20/24 或 192.168.1.20 255.255.255.0。"}
    }

    $tokens = @((($Text.Trim() -replace '[，;；]', " ") -split '[\s/]+') | Where-Object { $_ } | Select-Object -First 3)
    if ($tokens.Count -eq 0) {
        return @{Ok = $false; Message = "请输入 IP 地址或子网掩码。"}
    }

    $ipValue = ConvertFrom-WinUtilIPv4 -Text $tokens[0]
    if ($null -eq $ipValue) {
        return @{Ok = $false; Message = "「$($tokens[0])」不是一个有效的 IPv4 地址。"}
    }

    $prefix = $null
    if ($tokens.Count -ge 2) {
        $second = $tokens[1]
        if ($second -match '^\d{1,2}$' -and [int]$second -le 32) {
            $prefix = [int]$second
        } else {
            $prefix = ConvertFrom-WinUtilNetMask -Text $second
            if ($null -eq $prefix) {
                return @{Ok = $false; Message = "「$second」无法作为掩码：子网掩码的高位必须连续为 1（如 255.255.255.0），Windows 会拒绝不连续的掩码。"}
            }
        }
    } else {
        # No mask given: judge the address by its classful default so the number still means
        # something, and say so in the notes
        $prefix = if ($ipValue -lt 2122959872) { 8 } elseif ($ipValue -lt 3221225472) { 16 } else { 24 }
    }

    if ($prefix -lt 1) { return @{Ok = $false; Message = "前缀长度至少为 /1。"} }

    $maskOctets = @()
    for ($i = 0; $i -lt 4; $i++) {
        $bits = [Math]::Max(0, [Math]::Min(8, $prefix - ($i * 8)))
        $octet = if ($bits -eq 0) { 0 } elseif ($bits -eq 8) { 255 } else { [int](256 - [Math]::Pow(2, 8 - $bits)) }
        $maskOctets += [int]$octet
    }
    $maskValue = [long]$maskOctets[0] * 16777216 + [long]$maskOctets[1] * 65536 + [long]$maskOctets[2] * 256 + [long]$maskOctets[3]
    $wildcardValue = 4294967295 - $maskValue
    $networkValue = $ipValue -band $maskValue
    $broadcastValue = $networkValue -bor $wildcardValue
    $size = $broadcastValue - $networkValue + 1

    $usableFirst = $networkValue
    $usableLast = $broadcastValue
    $usableCount = $size
    if ($size -eq 1) {
        $usableCount = 1
    } elseif ($size -eq 2) {
        # /31 point-to-point links carry addresses with no network or broadcast (RFC 3074)
        $usableCount = 2
    } else {
        $usableFirst = $networkValue + 1
        $usableLast = $broadcastValue - 1
        $usableCount = $size - 2
    }

    return @{
        Ok             = $true
        IP             = ConvertTo-WinUtilIPv4 -Value $ipValue
        IPValue        = $ipValue
        Prefix         = $prefix
        Mask           = ($maskOctets -join ".")
        MaskValue      = $maskValue
        Wildcard       = ConvertTo-WinUtilIPv4 -Value $wildcardValue
        Network        = ConvertTo-WinUtilIPv4 -Value $networkValue
        NetworkValue   = $networkValue
        Broadcast      = ConvertTo-WinUtilIPv4 -Value $broadcastValue
        BroadcastValue = $broadcastValue
        First          = ConvertTo-WinUtilIPv4 -Value $usableFirst
        Last           = ConvertTo-WinUtilIPv4 -Value $usableLast
        Hosts          = [int]$usableCount
        Size           = $size
        Implicit       = ($tokens.Count -lt 2)
    }
}

function Get-WinUtilNetAddressKind {

    <#

    .SYNOPSIS
        What sort of address this is, in the words an operator expects

    #>

    param([long]$Value)

    $first = [int][Math]::Floor($Value / 16777216)
    $second = [int][Math]::Floor(($Value % 16777216) / 65536)

    if ($first -eq 10) { return "私有地址（10.0.0.0/8）" }
    if ($first -eq 172 -and $second -ge 16 -and $second -le 31) { return "私有地址（172.16.0.0/12）" }
    if ($first -eq 192 -and $second -eq 168) { return "私有地址（192.168.0.0/16）" }
    if ($first -eq 127) { return "环回地址，仅本机可达" }
    if ($first -eq 169 -and $second -eq 254) { return "链路本地地址（DHCP 取不到地址时自动私有）" }
    if ($first -eq 100 -and $second -ge 64 -and $second -le 127) { return "运营商级 NAT 共享地址（100.64.0.0/10）" }
    if ($first -ge 224 -and $first -lt 240) { return "组播地址" }
    if ($first -ge 240) { return "保留/广播地址" }
    if ($first -eq 0) { return "本网络地址/保留" }
    return "公网地址"
}

function Get-WinUtilNetIpCalc {

    <#

    .SYNOPSIS
        IP address calculator: mask, CIDR, network, broadcast, usable range, gateway

    #>

    param([string]$Text)

    # "255.255.252.0" on its own is a question about the mask, and the only case where a bare
    # dotted quad does not mean an address
    if ($Text -and $Text.Trim() -match '^(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(\.\d{1,3}){3}$') {
        $firstOctet = [int]$matches[1]
        if ($firstOctet -ge 128 -and $Text.Trim() -notmatch '[/\s]') {
            $prefix = ConvertFrom-WinUtilNetMask -Text $Text
            if ($null -ne $prefix -and $prefix -ge 4) { return Get-WinUtilNetMaskCalc -Text $Text }
            if ($null -eq $prefix -and $firstOctet -eq 255) {
                return New-WinUtilNetToolError -Message "「$($Text.Trim())」的高位不连续：子网掩码必须写成 255.255.255.0 这类高位连续为 1 的形式，设备会拒绝不连续掩码。"
            }
        }
    }

    $block = Get-WinUtilNetIpBlock -Text $Text
    if (-not $block.Ok) { return New-WinUtilNetToolError -Message $block.Message }

    $rows = @()
    $rows += New-WinUtilNetToolRow -Name "CIDR 写法" -Detail "$($block.Network)/$($block.Prefix)" -Status "掩码 $($block.Mask)"
    $rows += New-WinUtilNetToolRow -Name "子网掩码" -Detail $block.Mask -Status "反掩码 $($block.Wildcard)"
    $rows += New-WinUtilNetToolRow -Name "网络地址" -Detail $block.Network -Status "广播 $($block.Broadcast)"
    $rows += New-WinUtilNetToolRow -Name "可用主机" -Detail "$($block.First) ~ $($block.Last)" -Status "$($block.Hosts) 台"
    $rows += New-WinUtilNetToolRow -Name "地址整数形式" -Detail "$($block.IPValue)" -Status ("十六进制 0x{0:X8}" -f $block.IPValue)
    if ($block.Size -ge 3) {
        $rows += New-WinUtilNetToolRow -Name "常用网关" -Detail "$($block.First) 或 $($block.Last)" -Status "按现场习惯二选一"
    }

    $notes = @()
    $notes += "$($block.IP) 属于$(Get-WinUtilNetAddressKind -Value $block.IPValue)。"
    if ($block.Implicit) {
        $notes += "未指定掩码，已按地址类别默认取 /$($block.Prefix)；与实际掩码不符请写成 192.168.1.20 255.255.255.0 或 /24。"
    }
    if ($block.IPValue -ne $block.NetworkValue) {
        $notes += "注意：$($block.IP) 不是该网段的网络地址，所在网段是 $($block.Network)/$($block.Prefix)。"
    }

    return New-WinUtilNetToolResult -Rows $rows -Notes $notes
}

function Get-WinUtilNetMaskCalc {

    <#

    .SYNOPSIS
        A bare mask on its own: what it means, and what it does not allow

    #>

    param([string]$Text)

    $prefix = ConvertFrom-WinUtilNetMask -Text $Text
    if ($null -eq $prefix) {
        return New-WinUtilNetToolError -Message "「$Text」不是有效的连续子网掩码。"
    }

    $block = Get-WinUtilNetIpBlock -Text "0.0.0.0 $Text"
    if (-not $block.Ok) { return New-WinUtilNetToolError -Message $block.Message }

    $rows = @()
    $rows += New-WinUtilNetToolRow -Name "前缀长度" -Detail "/$prefix" -Status "掩码 $($block.Mask)"
    $rows += New-WinUtilNetToolRow -Name "反掩码" -Detail $block.Wildcard -Status "ACL/路由汇总用"
    $rows += New-WinUtilNetToolRow -Name "地址总数" -Detail "$($block.Size) 个" -Status "可用主机 $($block.Hosts) 台"
    $rows += New-WinUtilNetToolRow -Name "网络号步长" -Detail "每 $($block.Size) 个地址一个网段" -Status "手算第四段起点用"

    $notes = @("$Text 即 /$prefix；不连续的掩码（如 255.0.255.0）在任何设备上都会被拒绝。")
    $notes += "路由器汇总/ACL 里用反掩码 $($block.Wildcard)；一个合法网络地址，其 32 位整数值必须能被 $($block.Size) 整除。"

    return New-WinUtilNetToolResult -Rows $rows -Notes $notes
}

function Get-WinUtilNetVlsmPlan {

    <#

    .SYNOPSIS
        Variable length subnetting: carve a base network into the sizes actually needed

    #>

    param([string]$Base, [string]$Hosts)

    $block = Get-WinUtilNetIpBlock -Text $Base
    if (-not $block.Ok) { return New-WinUtilNetToolError -Message "基网段：$($block.Message)" }
    $block = Get-WinUtilNetIpBlock -Text "$($block.Network)/$($block.Prefix)"

    $needs = @()
    foreach ($token in (@($Hosts -split '[,;、\s]+' | Where-Object { $_ }))) {
        if ($token -match '^(\d+)$') {
            $value = [int]$matches[1]
            if ($value -gt 0) { $needs += $value }
        }
    }

    $notes = @()
    if ($needs.Count -eq 0) {
        $prefix = [Math]::Min(30, $block.Prefix + 2)
        $blockCount = [int][Math]::Pow(2, $prefix - $block.Prefix)
        $notes += "未填写各部门主机数，已把 $($block.Network)/$($block.Prefix) 均分为 $blockCount 个 /$prefix 子网。"
        $needs = @()
        for ($i = 0; $i -lt $blockCount; $i++) {
            $needs += [int]([Math]::Pow(2, 32 - $prefix) - 2)
        }
    } else {
        # Largest first: a small block placed early strands space the big request cannot use
        $needs = @($needs | Sort-Object -Descending)
        $notes += "按从大到小分配（$($needs -join ' / ') 台），这样剩下的地址仍然连成一整块。"
    }

    $rows = @()
    $cursor = [long]$block.NetworkValue
    $limit = [long]$block.BroadcastValue
    $used = [long]0
    $index = 0

    foreach ($need in $needs) {
        $index++
        # The tightest block that holds the request, but never longer than the base network
        $prefix = 30
        while ($prefix -gt $block.Prefix -and ([Math]::Pow(2, 32 - $prefix) - 2) -lt $need) { $prefix-- }
        if (([Math]::Pow(2, 32 - $prefix) - 2) -lt $need) {
            $rows += New-WinUtilNetToolRow -Name "需求 $index" `
                -Detail "需要 $need 台，基网段 /$($block.Prefix) 最多只能切出 $([int]([Math]::Pow(2, 32 - $block.Prefix) - 2)) 台一块" `
                -Status "无法分配"
            $notes += "需求 $need 台放不进 $($block.Network)/$($block.Prefix)：请扩大基网段（例如改用 /23）或把该部门拆成两段。"
            continue
        }

        $size = [long][Math]::Pow(2, 32 - $prefix)
        if (($cursor % $size) -ne 0) {
            $cursor = $size * ([Math]::Floor($cursor / $size) + 1)
        }
        if (($cursor + $size - 1) -gt $limit) {
            $rows += New-WinUtilNetToolRow -Name "需求 $index" -Detail "需要 $need 台（/$prefix）" -Status "地址不够"
            $notes += "$($block.Network)/$($block.Prefix) 剩余地址不足以再容纳 $need 台，请扩大基网段或减少分段。"
            continue
        }

        $rows += New-WinUtilNetToolRow -Name "子网 $index" `
            -Detail "$(ConvertTo-WinUtilIPv4 -Value $cursor)/$prefix 可用 $(ConvertTo-WinUtilIPv4 -Value ($cursor + 1)) ~ $(ConvertTo-WinUtilIPv4 -Value ($cursor + $size - 2))" `
            -Status "需 $need 台 / 可 $([int]($size - 2)) 台"
        $cursor += $size
        $used += $size
    }

    $left = ($limit - $block.NetworkValue + 1) - $used
    if ($left -gt 0) {
        $rows += New-WinUtilNetToolRow -Name "剩余" `
            -Detail "$(ConvertTo-WinUtilIPv4 -Value $cursor) ~ $(ConvertTo-WinUtilIPv4 -Value $limit)" `
            -Status "$left 个地址"
    }

    $notes += "基网段 $($block.Network)/$($block.Prefix) 共 $($block.Size) 个地址，本次划分 $($needs.Count) 段。"

    return New-WinUtilNetToolResult -Rows $rows -Notes $notes
}

function Get-WinUtilNetSummaryPlan {

    <#

    .SYNOPSIS
        The reverse: fold a list of subnets into the fewest CIDR blocks that cover them

    #>

    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return New-WinUtilNetToolError -Message "请输入要汇总的网段，例如 192.168.0.0/24,192.168.1.0/24。"
    }

    $blocks = @()
    foreach ($token in (@($Text -split '[,;、\s]+' | Where-Object { $_ }))) {
        $block = Get-WinUtilNetIpBlock -Text $token
        if (-not $block.Ok) { return New-WinUtilNetToolError -Message "网段「$token」：$($block.Message)" }
        $blocks += [pscustomobject]@{Network = [long]$block.NetworkValue; Prefix = [int]$block.Prefix}
    }
    if ($blocks.Count -lt 2) {
        return New-WinUtilNetToolError -Message "汇总至少需要两个网段。"
    }

    # Neighbours in numeric order are the only pairs that can fold up, so that is the order the
    # merge pass works in
    $sorted = @($blocks | Sort-Object -Property @{Expression = "Network"; Descending = $false}, @{Expression = "Prefix"; Descending = $false})

    $again = $true
    $rounds = 0
    while ($again -and $rounds -lt 32) {
        $again = $false
        $rounds++
        $merged = New-Object System.Collections.Generic.List[object]
        $i = 0
        while ($i -lt $sorted.Count) {
            if ($i -lt ($sorted.Count - 1)) {
                $a = $sorted[$i]
                $b = $sorted[$i + 1]
                $size = [long][Math]::Pow(2, 32 - $a.Prefix)
                # Two equal blocks fold up only when they are the two halves of the block above
                if ($a.Prefix -eq $b.Prefix -and ($b.Network - $a.Network) -eq $size -and ((($a.Network / $size) % 2) -eq 0)) {
                    $merged.Add([pscustomobject]@{Network = [long]$a.Network; Prefix = [int]($a.Prefix - 1)}) | Out-Null
                    $i += 2
                    $again = $true
                    continue
                }
            }
            $merged.Add($sorted[$i]) | Out-Null
            $i++
        }
        $sorted = @($merged | Sort-Object -Property @{Expression = "Network"; Descending = $false}, @{Expression = "Prefix"; Descending = $false})
    }

    $rows = @()
    foreach ($entry in ($sorted | Sort-Object -Property @{Expression = "Network"; Descending = $false})) {
        $size = [long][Math]::Pow(2, 32 - $entry.Prefix)
        $rows += New-WinUtilNetToolRow -Name "汇总网段" `
            -Detail "$(ConvertTo-WinUtilIPv4 -Value $entry.Network)/$($entry.Prefix)" `
            -Status "覆盖 $size 个地址"
    }

    $notes = @("$($blocks.Count) 个网段汇总为 $($sorted.Count) 个。")
    if ($sorted.Count -eq 1) {
        $notes += "可直接写一条静态路由或一条 ACL：$(ConvertTo-WinUtilIPv4 -Value $sorted[0].Network)/$($sorted[0].Prefix)，反掩码 $(Get-WinUtilNetSummaryWildcard -Prefix $sorted[0].Prefix)。"
    } else {
        $lowest = ($sorted | Sort-Object Network | Select-Object -First 1).Network
        $highestEntry = ($sorted | Sort-Object Network | Select-Object -Last 1)
        $highest = $highestEntry.Network + [long][Math]::Pow(2, 32 - $highestEntry.Prefix) - 1
        $notes += "无法继续合并：所填网段并不连续，路由器上需要写 $($sorted.Count) 条。整体区间是 $(ConvertTo-WinUtilIPv4 -Value $lowest) ~ $(ConvertTo-WinUtilIPv4 -Value $highest)。"
    }

    return New-WinUtilNetToolResult -Rows $rows -Notes $notes
}

function Get-WinUtilNetSummaryWildcard {

    <#

    .SYNOPSIS
        The wildcard mask a static route or ACL is written with

    #>

    param([int]$Prefix)

    $maskValue = 4294967295 - ([long][Math]::Pow(2, 32 - $Prefix) - 1)
    return ConvertTo-WinUtilIPv4 -Value (4294967295 - $maskValue)
}

function Get-WinUtilMacBytes {

    <#

    .SYNOPSIS
        A MAC address in any of the common spellings, as its six bytes

    #>

    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $hex = ($Text -replace "[^0-9A-Fa-f]", "").ToUpperInvariant()
    if ($hex.Length -ne 12) { return $null }

    $bytes = @()
    for ($i = 0; $i -lt 12; $i += 2) {
        $bytes += [Convert]::ToByte($hex.Substring($i, 2), 16)
    }
    return $bytes
}

function Get-WinUtilNetOuiTable {

    <#

    .SYNOPSIS
        The prefix-to-vendor table, built in plus anything the unit dropped in the tools folder

    .DESCRIPTION
        There is no internet on these machines, so a full IEEE OUI dump has to be a file on the
        share. The built-in entries cover what an IT operator actually meets on a store network
        (virtual NICs above all); the file, when present, is parsed and merged over them.

    #>

    if ($sync.NetOuiTable) { return $sync.NetOuiTable }

    $table = @{}
    foreach ($entry in @(
        @("000C29", "VMware 虚拟机网卡"),
        @("005056", "VMware ESXi/vCenter 网卡"),
        @("00155D", "微软 Hyper-V 虚拟机网卡"),
        @("0003FF", "微软 Hyper-V / 虚拟适配器"),
        @("00163E", "Xen 虚拟机网卡"),
        @("525400", "QEMU / KVM 虚拟机网卡"),
        @("0242AC", "Docker 容器网桥"),
        @("B827EB", "树莓派 Raspberry Pi Foundation"),
        @("DCA632", "树莓派 Raspberry Pi Trading"),
        @("001201", "海康威视设备常见前缀")
    )) {
        $table[$entry[0]] = $entry[1]
    }

    $source = "内置精简表"
    # Beside the program for the script build; in the local cache because the packaged exe keeps
    # its tools inside the payload and an operator cannot drop a file in there
    $localDir = if ($sync -and $sync.winutildir) { $sync.winutildir } else { Join-Path $env:LocalAppData "winutil" }
    $candidates = @((Join-Path (Get-WinUtilAppBaseDir) "tools\net\oui.txt"), (Join-Path $localDir "tools\net\oui.txt"))
    foreach ($candidate in $candidates) {
        if (-not (Test-Path -LiteralPath $candidate)) { continue }
        foreach ($line in ([System.IO.File]::ReadLines($candidate))) {
            # The IEEE file spells the same vendor twice, once in "xx-xx-xx (hex)" form and
            # once as a six digit block, and either may be the one the operator pasted
            if ($line -match '^\s*([0-9A-Fa-f]{2})[-:]([0-9A-Fa-f]{2})[-:]([0-9A-Fa-f]{2})\s*\(hex\)\s*(.+?)\s*$') {
                $table[("{0}{1}{2}" -f $matches[1], $matches[2], $matches[3]).ToUpperInvariant()] = $matches[4].Trim()
            } elseif ($line -match '^\s*([0-9A-Fa-f]{6})\s*\(OAB\)\s*(.+?)\s*$') {
                if (-not $table.ContainsKey($matches[1].ToUpperInvariant())) {
                    $table[$matches[1].ToUpperInvariant()] = $matches[2].Trim()
                }
            }
        }
        $source = "内置精简表 + $candidate"
        break
    }

    $sync.NetOuiSource = $source
    $sync.NetOuiTable = $table
    return $table
}

function Get-WinUtilNetOuiInfo {

    <#

    .SYNOPSIS
        Who made this address, or null when the offline table does not know

    #>

    param([string]$Hex6)

    if ([string]::IsNullOrWhiteSpace($Hex6)) { return $null }
    $table = Get-WinUtilNetOuiTable
    $key = ($Hex6 -replace "[^0-9A-Fa-f]", "").ToUpperInvariant()
    if ($key.Length -lt 6) { return $null }
    $key = $key.Substring(0, 6)
    if ($table.ContainsKey($key)) { return [string]$table[$key] }
    return $null
}

function Get-WinUtilNetMacTool {

    <#

    .SYNOPSIS
        MAC address tool: every separator style, the flag bits, and the vendor

    #>

    param([string]$Text)

    $bytes = Get-WinUtilMacBytes -Text $Text
    if (-not $bytes) {
        return New-WinUtilNetToolError -Message "请输入 MAC 地址，支持 aabb.ccdd.eeff / aa-bb-cc-dd-ee-ff / aa:bb:cc:dd:ee:ff / aabbccddeeff 任一写法。"
    }

    $pairs = @($bytes | ForEach-Object { $_.ToString("X2") })
    $lower = @($pairs | ForEach-Object { $_.ToLowerInvariant() })
    $hex6 = (($lower[0] + $lower[1] + $lower[2]).ToUpperInvariant())

    $rows = @()
    $rows += New-WinUtilNetToolRow -Name "冒号格式" -Detail ($pairs -join ":") -Status "Linux/交换机"
    $rows += New-WinUtilNetToolRow -Name "连字符格式" -Detail ($pairs -join "-") -Status "Windows ipconfig"
    $rows += New-WinUtilNetToolRow -Name "Cisco 格式" -Detail ("{0}.{1}.{2}" -f ($lower[0] + $lower[1]), ($lower[2] + $lower[3]), ($lower[4] + $lower[5])) -Status "小写点分"
    $rows += New-WinUtilNetToolRow -Name "无分隔" -Detail ($lower -join "") -Status "填表/脚本常用"
    $rows += New-WinUtilNetToolRow -Name "OUI 前缀" -Detail ($pairs[0..2] -join "-") -Status "厂商段"

    $vendor = Get-WinUtilNetOuiInfo -Hex6 $hex6
    if ($vendor) {
        $rows += New-WinUtilNetToolRow -Name "厂商" -Detail $vendor -Status "已识别"
    } else {
        $rows += New-WinUtilNetToolRow -Name "厂商" -Detail "离线精简表未收录 $($pairs[0..2] -join '-')" -Status "未知"
    }

    $notes = @()
    $notes += $(if (($bytes[0] -band 1) -eq 1) { "首字节 $($pairs[0])：组播地址，网卡不会把它当作本机地址接收。" } else { "首字节 $($pairs[0])：单播地址。" })
    $notes += $(if (($bytes[0] -band 2) -eq 2) { "本地管理地址（第 2 位为 1）：通常是虚拟机、容器或手工改写的 MAC，不是厂商烧录的。" } else { "全球唯一地址（IEEE 分配给厂商），前 3 字节即 OUI。" })
    if (-not $vendor) {
        $notes += "完整厂商表：把 IEEE 的 oui.txt 放到 tools\net\oui.txt，本工具会自动读取合并。当前使用$($sync.NetOuiSource)。"
    }

    return New-WinUtilNetToolResult -Rows $rows -Notes $notes
}

function Get-WinUtilNetIpConflict {

    <#

    .SYNOPSIS
        Whether an address is already answered for, and whether one MAC claims several

    .DESCRIPTION
        Without raw sockets a tool cannot put an ARP who-has on the wire by itself, so this reads
        what the stack already knows plus the neighbour table of the whole /24: an address that
        answers when it should be free, and one MAC holding two addresses, are the two shapes an
        IP conflict actually takes on a store LAN.

    #>

    param(
        [string]$Text,
        [scriptblock]$OnProgress
    )

    $local = Get-WinUtilNetLocalAddresses
    $localMacs = @($local.Adapters | ForEach-Object { (($_.Mac -replace "[^0-9A-Fa-f]", "")).ToUpperInvariant() })

    $rows = @()
    $notes = @()

    $targets = @()
    if ([string]::IsNullOrWhiteSpace($Text)) {
        $targets = @($local.IPv4 | ForEach-Object { $_.IPAddress })
        if ($targets.Count -eq 0) {
            return New-WinUtilNetToolError -Message "未填写要检测的 IP，本机也没有可用的 IPv4 地址。"
        }
        $notes += "未填写 IP，按本机现有的 $($targets.Count) 个 IPv4 地址逐个检测。"
    } else {
        foreach ($token in (@($Text -split '[,;、\s]+' | Where-Object { $_ }))) {
            if (-not (Test-WinUtilIPv4 -Text $token)) {
                return New-WinUtilNetToolError -Message "「$token」不是有效的 IPv4 地址。"
            }
            $targets += $token
        }
    }

    $neighbours = @(Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue)

    foreach ($target in $targets) {
        if ($OnProgress) { & $OnProgress "正在检测 $target……" }
        $ping = Test-WinUtilPing -Target $target -Count 2 -TimeoutMs 600
        $answered = $ping.Received -gt 0

        # Windows keeps unresolved entries with an all-zero link-layer address, and they can sort
        # ahead of the real record, so pick the first entry that actually carries a MAC
        $mac = $null
        foreach ($candidate in @($neighbours | Where-Object { $_.IPAddress -eq $target })) {
            $candidateMac = ($candidate.LinkLayerAddress -replace "[^0-9A-Fa-f]", "").ToUpperInvariant()
            if ($candidateMac -and $candidateMac -ne "000000000000") { $mac = $candidateMac; break }
        }

        $isMine = $false
        foreach ($mine in $local.IPv4) { if ($mine.IPAddress -eq $target) { $isMine = $true } }

        $status = "未占用"
        if ($answered) { $status = "已被占用" }
        if ($isMine) { $status = "本机地址" }
        if ($answered -and $mac -and ($mac -in $localMacs) -and -not $isMine) {
            $status = "冲突风险"
            $notes += "$target 应答的 MAC 与本机网卡相同，本机与该地址之间存在 IP 冲突。"
        }

        $detail = "ARP 表中无记录"
        if ($mac) {
            $vendor = Get-WinUtilNetOuiInfo -Hex6 $mac
            $detail = "$mac"
            if ($vendor) { $detail += " · $vendor" }
            if ($answered) { $detail += " · 平均 $($ping.Avg)ms" }
        }

        $rows += New-WinUtilNetToolRow -Name $target -Detail $detail -Status $status
    }

    # The neighbour table of the same prefix shows the other half of a conflict: one MAC holding
    # two addresses, which is what a cloned or manually set address leaves behind
    $prefix = ""
    foreach ($candidate in (@($Text -split '[,;、\s]+' | Where-Object { $_ }) + @($targets))) {
        if ($candidate -match '^(\d{1,3}\.\d{1,3}\.\d{1,3})\.\d{1,3}$') { $prefix = $matches[1]; break }
    }
    if ($prefix) {
        $byMac = @{}
        foreach ($neighbour in $neighbours) {
            if ($neighbour.IPAddress -notlike "$prefix.*") { continue }
            if (-not $neighbour.LinkLayerAddress) { continue }
            $mac = ($neighbour.LinkLayerAddress -replace "[^0-9A-Fa-f]", "").ToUpperInvariant()
            if ($mac.Length -ne 12 -or $mac -eq "000000000000" -or $mac -like "01005E*" -or $mac -eq "FFFFFFFFFFFF") { continue }
            if (-not $byMac.ContainsKey($mac)) { $byMac[$mac] = @() }
            if ($byMac[$mac] -notcontains $neighbour.IPAddress) { $byMac[$mac] += $neighbour.IPAddress }
        }
        foreach ($mac in @($byMac.Keys | Sort-Object)) {
            $held = @($byMac[$mac] | Sort-Object { [Version]$_ })
            if ($held.Count -lt 2) { continue }
            # One cloned NIC can fill the whole table, so the row names a few and counts the rest
            $shown = if ($held.Count -gt 6) { "$((@($held[0..5]) -join ', '))…共 $($held.Count) 个" } else { $held -join ', ' }
            $rows += New-WinUtilNetToolRow -Name "同一 MAC 多 IP" -Detail "$mac → $shown" -Status "冲突风险"
            $notes += "$shown 使用了同一个 MAC（$mac），是典型的 IP 冲突或网卡地址被克隆。"
        }
        $notes += "网段 $prefix.0/24 的邻居表中现有 $($byMac.Count) 个不同 MAC 的记录。"
    }

    $rows = @($rows | Select-Object -Unique)
    if (@($notes).Count -eq 0) { $notes = @("未发现冲突迹象：目标地址无人应答，邻居表内也没有一个 MAC 对应多个 IP。") }

    return New-WinUtilNetToolResult -Rows $rows -Notes $notes
}

function Get-WinUtilNetArpLookup {

    <#

    .SYNOPSIS
        IP to MAC and back, out of the neighbour table Windows already holds

    #>

    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return New-WinUtilNetToolError -Message "请输入 IP 或 MAC 地址。"
    }

    $token = $Text.Trim()
    $byIp = Test-WinUtilIPv4 -Text $token
    $bytes = Get-WinUtilMacBytes -Text $token
    if (-not $byIp -and -not $bytes) {
        return New-WinUtilNetToolError -Message "「$token」既不是 IP 也不是 MAC 地址。"
    }

    $wanted = ($token -replace "[^0-9A-Fa-f]", "").ToUpperInvariant()
    $entries = @(Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object {
        if ($byIp) { $_.IPAddress -eq $token }
        else {
            $found = ($_.LinkLayerAddress -replace "[^0-9A-Fa-f]", "").ToUpperInvariant()
            # the all-zero placeholder Windows leaves on unresolved entries is nobody's address
            $found -ne "000000000000" -and $found -eq $wanted
        }
    })
    if ($byIp -and $entries.Count -eq 0) {
        # An address the host has never spoken to is simply absent from the table, so ask for it
        # once and read the cache again
        $null = Test-WinUtilPing -Target $token -Count 2 -TimeoutMs 600
        $entries = @(Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -eq $token })
    }

    if ($entries.Count -eq 0) {
        $rows = @(New-WinUtilNetToolRow -Name $token -Detail "无 ARP 记录" -Status "未解析")
        return New-WinUtilNetToolResult -Rows $rows `
            -Notes @("邻居表中没有 $token 的记录。若目标是本机从未通信过的主机，可先用「主机发现」扫描该网段再查。")
    }

    $rows = @()
    $notes = @()
    foreach ($entry in $entries) {
        $mac = ($entry.LinkLayerAddress -replace "[^0-9A-Fa-f]", "").ToUpperInvariant()
        if ($mac -eq "000000000000") {
            $rows += New-WinUtilNetToolRow -Name $entry.IPAddress -Detail "这条 ARP 记录还没有解析出 MAC（状态 $($entry.State)）" -Status "未解析"
            continue
        }
        $pretty = if ($mac.Length -ge 12) { (($mac -split "(..)" | Where-Object { $_ }) -join ":") } else { [string]$entry.LinkLayerAddress }
        $vendor = Get-WinUtilNetOuiInfo -Hex6 $mac
        $rows += New-WinUtilNetToolRow -Name $entry.IPAddress -Detail "$pretty · $(if ($vendor) { $vendor } else { "厂商未知" })" -Status ([string]$entry.State)
        $adapter = (Get-NetAdapter -InterfaceIndex $entry.InterfaceIndex -ErrorAction SilentlyContinue).Name
        $notes += "$($entry.IPAddress) → $pretty（接口 $(if ($adapter) { $adapter } else { "IDX $($entry.InterfaceIndex)" })，状态 $($entry.State)）。"
    }
    $notes += "状态说明：Reachable 近期已确认；Stale/Delay 记录过期需重新解析；Unreachable 不通；Permanent 静态绑定。"

    return New-WinUtilNetToolResult -Rows $rows -Notes $notes
}

function New-WinUtilMagicPacket {

    <#

    .SYNOPSIS
        The Wake-on-LAN magic packet: six bytes of FF followed by the MAC sixteen times

    #>

    param([string]$Mac)

    $bytes = Get-WinUtilMacBytes -Text $Mac
    if (-not $bytes) { return $null }

    $packet = New-Object byte[] 102
    for ($i = 0; $i -lt 6; $i++) { $packet[$i] = [byte]255 }
    for ($copy = 0; $copy -lt 16; $copy++) {
        for ($i = 0; $i -lt 6; $i++) {
            $packet[6 + ($copy * 6) + $i] = $bytes[$i]
        }
    }
    return $packet
}

function Send-WinUtilWakeOnLan {

    <#

    .SYNOPSIS
        Sends the magic packet to the broadcast addresses an operator can actually reach

    #>

    param(
        [string]$Mac,
        [string]$Target,
        [int]$Port = 9
    )

    $packet = New-WinUtilMagicPacket -Mac $Mac
    if (-not $packet) { return @{Sent = @(); Failed = @("MAC 地址无效。"); Targets = @()} }

    $targets = @()
    foreach ($token in (@($Target -split '[,;、\s]+' | Where-Object { $_ }))) {
        $targets += $token
    }
    if ($targets.Count -eq 0) {
        # A station on the LAN reaches a sleeping NIC through the subnet broadcast; the limited
        # broadcast covers the case where the machine has no useful address at all
        $prefix = Get-WinUtilNetScanSubnet -Text ""
        if ($prefix) { $targets += "$prefix.255" }
        $targets += "255.255.255.255"
    }

    $sent = @()
    $failed = @()
    $client = New-Object System.Net.Sockets.UdpClient
    try {
        # UdpClient.EnableBroadcast only exists in .NET Core; on the Framework, where PowerShell 5
        # runs, SO_BROADCAST is a socket-level option — asking at UDP level fails 10022
        $client.Client.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::Socket, [System.Net.Sockets.SocketOptionName]::Broadcast, 1)
        foreach ($target in $targets) {
            try {
                $null = $client.Send($packet, $packet.Length, $target, $Port)
                $sent += ("{0}:{1}" -f $target, $Port)
            } catch {
                $failed += ("{0}:{1} —— {2}" -f $target, $Port, $_.Exception.Message)
            }
        }
    } finally {
        $client.Close()
    }

    return @{Sent = $sent; Failed = $failed; Targets = $targets}
}

function ConvertFrom-WinUtilNetSize {

    <#

    .SYNOPSIS
        "2.5GB", "500M", "1200" as a byte count

    #>

    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    if ($Text.Trim() -notmatch '^([0-9]+(?:\.[0-9]+)?)\s*([a-zA-Z\u4e00-\u9fa5]*)$') { return $null }

    $value = [double]$matches[1]
    $unit = (($matches[2] -replace "[\s]", "").ToLowerInvariant())

    $multiplier = $null
    switch ($unit) {
        "" { $multiplier = 1MB; break }
        {$_ -in @("b", "byte", "bytes", "字节")} { $multiplier = 1; break }
        {$_ -in @("k", "kb", "kib")} { $multiplier = 1KB; break }
        {$_ -in @("m", "mb", "mib", "兆")} { $multiplier = 1MB; break }
        {$_ -in @("g", "gb", "gib")} { $multiplier = 1GB; break }
        {$_ -in @("t", "tb", "tib")} { $multiplier = 1TB; break }
    }
    if ($null -eq $multiplier) { return $null }

    return $value * $multiplier
}

function Get-WinUtilNetDurationText {

    <#

    .SYNOPSIS
        A duration in seconds as the sentence an operator reads out

    #>

    param([double]$Seconds)

    if ($Seconds -lt 1) { return "不足 1 秒" }
    if ($Seconds -lt 60) { return "{0:N1} 秒" -f $Seconds }
    if ($Seconds -lt 3600) { return "{0:N1} 分钟" -f ($Seconds / 60) }
    if ($Seconds -lt 86400) { return "{0:N1} 小时" -f ($Seconds / 3600) }
    return "{0:N1} 天" -f ($Seconds / 86400)
}

function Get-WinUtilNetBandwidthPlan {

    <#

    .SYNOPSIS
        Bandwidth calculator: how long a file takes over a link, and what link a deadline needs

    #>

    param(
        [string]$Size,
        [string]$Link
    )

    $bytes = ConvertFrom-WinUtilNetSize -Text $Size
    if ($null -eq $bytes -or $bytes -le 0) {
        return New-WinUtilNetToolError -Message "请输入文件大小，例如 800MB、2.5G、1200（不带单位按 MB 计）。"
    }

    $typed = $null
    if (-not [string]::IsNullOrWhiteSpace($Link)) {
        $result = ConvertFrom-WinUtilNetRate -Text $Link
        if ($null -eq $result) {
            return New-WinUtilNetToolError -Message "无法识别带宽「$Link」。可写 千兆 / 百兆 / 万兆，或 100M、1000M、1G、100MB/s。"
        }
        $typed = $result.BitsPerSecond
    }

    $links = New-Object System.Collections.Generic.List[object]
    if ($typed) { $links.Add([pscustomobject]@{Name = "指定链路（$($Link.Trim())）"; Bits = $typed}) }
    foreach ($entry in @(
        @{Name = "百兆口 100M"; Bits = 100e6},
        @{Name = "千兆口 1000M"; Bits = 1e9},
        @{Name = "百兆实际 70M"; Bits = 70e6},
        @{Name = "无线链路 50M"; Bits = 50e6},
        @{Name = "万兆 10G"; Bits = 10e9}
    )) {
        if ($typed -and [Math]::Abs($entry.Bits - $typed) -lt 1) { continue }
        if ($links.Count -ge 4) { break }
        $links.Add([pscustomobject]@{Name = $entry.Name; Bits = [double]$entry.Bits}) | Out-Null
    }

    $rows = @()
    foreach ($entry in $links) {
        $parts = @()
        foreach ($pair in @(@("满速", 1.0), @("常见 80%", 0.8), @("拥堵 60%", 0.6))) {
            $parts += "$($pair[0]) $(Get-WinUtilNetDurationText -Seconds (($bytes * 8) / ($entry.Bits * $pair[1])))"
        }
        $rows += New-WinUtilNetToolRow -Name $entry.Name -Detail ($parts -join " | ") -Status (Format-WinUtilNetBitRate ($entry.Bits / 8))
    }

    $notes = @("文件大小 $(Format-WinUtilNetBytes $bytes)（$([int64]$bytes) 字节）。")
    $notes += "局域网实测一般能跑到标称带宽的 60%~80%；跨门店走 VPN/专线时更低，排计划按 60% 估算。"
    $notes += "若要求在 1 小时内传完，需要带宽 $(Format-WinUtilNetBitRate ($bytes / 3600))。"
    $notes += "若要求在 10 分钟内传完，需要带宽 $(Format-WinUtilNetBitRate ($bytes / 600))。"

    return New-WinUtilNetToolResult -Rows $rows -Notes $notes
}

function ConvertFrom-WinUtilNetRate {

    <#

    .SYNOPSIS
        A rate written the way people write it, as bits and bytes per second

    .DESCRIPTION
        "100M" on a switch means megabits and "10MB/s" in a copy dialog means megabytes; the eight
        fold difference between them is the single most common misreading on this tab, so both
        spellings are accepted and both answers are handed back.

    #>

    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }

    # A switch port is described as 千兆/百兆 without any number attached, and that is what an
    # operator types here too, so the bare words carry their own rate
    $wordBits = @{ "十兆" = 1e7; "百兆" = 1e8; "千兆" = 1e9; "万兆" = 1e10 }
    $word = ($Text.Trim() -replace "\s", "")
    if ($wordBits.ContainsKey($word)) {
        $bits = $wordBits[$word]
        return [pscustomobject]@{BitsPerSecond = $bits; BytesPerSecond = $bits / 8; Unit = $Text.Trim()}
    }

    if ($Text.Trim() -notmatch '^([0-9]+(?:\.[0-9]+)?)\s*([a-zA-Z\u4e00-\u9fa5/]*)$') { return $null }

    $value = [double]$matches[1]
    # Slashes and 秒 are dropped rather than read: "MB/s" leaves "mbs", which is the byte form,
    # while "Mbps" leaves "mbps", which is the bit form. "Mb/s" is the one spelling this reads as
    # bytes, so the tool says which convention it used.
    $unit = (($matches[2] -replace "[\s/秒]", "").ToLowerInvariant())

    $bits = $null
    switch ($unit) {
        "" { $bits = $value * 1e6; break }
        {$_ -in @("b", "bps")} { $bits = $value; break }
        {$_ -in @("k", "kb", "kbps")} { $bits = $value * 1e3; break }
        {$_ -in @("m", "mb", "mbps", "mps", "兆")} { $bits = $value * 1e6; break }
        {$_ -in @("g", "gb", "gbps", "千兆")} { $bits = $value * 1e9; break }
        {$_ -in @("t", "tb", "tbps")} { $bits = $value * 1e12; break }
        {$_ -in @("byte", "bytes", "字节", "兆字节")} { $bits = $value * 8; break }
        {$_ -in @("kbs", "kbyte")} { $bits = $value * 8 * 1024; break }
        {$_ -in @("mbs", "mbyte")} { $bits = $value * 8 * 1MB; break }
        {$_ -in @("gbs", "gbyte")} { $bits = $value * 8 * 1GB; break }
        {$_ -in @("tbs")} { $bits = $value * 8 * 1TB; break }
    }
    if ($null -eq $bits) { return $null }

    return [pscustomobject]@{BitsPerSecond = $bits; BytesPerSecond = $bits / 8; Unit = $unit}
}

function Get-WinUtilNetVlanPlan {

    <#

    .SYNOPSIS
        VLAN planner: hand out VLAN ids with the subnet, gateway and host count that go with them

    #>

    param(
        [string]$Range,
        [string]$Base
    )

    if ([string]::IsNullOrWhiteSpace($Range)) {
        return New-WinUtilNetToolError -Message "请输入 VLAN 范围或列表，例如 10-18 或 10,20,30。"
    }

    $ids = @()
    foreach ($token in (@($Range -split '[,;、\s]+' | Where-Object { $_ }))) {
        if ($token -match '^(\d+)$') {
            $ids += [int]$matches[1]
        } elseif ($token -match '^(\d+)[-~](\d+)$') {
            $from = [int]$matches[1]
            $to = [int]$matches[2]
            if ($to -lt $from) { $tmp = $from; $from = $to; $to = $tmp }
            if (($to - $from) -gt 63) {
                return New-WinUtilNetToolError -Message "一次最多规划 64 个 VLAN（$token 太长），请分段。"
            }
            for ($v = $from; $v -le $to; $v++) { $ids += $v }
        } else {
            return New-WinUtilNetToolError -Message "无法识别「$token」，可写单个 VLAN 号或范围 10-18。"
        }
    }
    $ids = @($ids | Select-Object -Unique | Sort-Object)

    $prefixOctets = @()
    if (-not [string]::IsNullOrWhiteSpace($Base)) {
        foreach ($octet in (@($Base.Trim() -split '\.') | Where-Object { $_ })) {
            if ($octet -notmatch '^\d{1,3}$' -or [int]$octet -gt 255) {
                return New-WinUtilNetToolError -Message "编号基址「$Base」不合法，请写 1~3 段数字，例如 10.10 或 172.20。"
            }
            $prefixOctets += [int]$octet
        }
        if ($prefixOctets.Count -gt 3) {
            return New-WinUtilNetToolError -Message "编号基址请写 1~3 段，例如 10.10（每 VLAN 一个 /24，第三段用 VLAN 号填）。"
        }
    }
    if ($prefixOctets.Count -eq 0) { $prefixOctets = @(10, 10) }

    $rows = @()
    $assigned = 0
    $wrapped = $false
    foreach ($id in $ids) {
        if ($id -lt 1 -or $id -gt 4094) {
            $rows += New-WinUtilNetToolRow -Name "VLAN $id" -Detail "802.1Q 的 VLAN ID 只能取 1~4094（12 位字段）" -Status "非法"
            continue
        }
        if ($id -eq 1) {
            $rows += New-WinUtilNetToolRow -Name "VLAN 1" -Detail "交换机默认 VLAN，所有端口默认属于它；建议改作它用或仅做管理" -Status "默认"
            continue
        }

        # Three octets given means the third one walks from the base by position; two octets means
        # the VLAN number itself is the third one, which is the arrangement most stores already use
        $third = if ($prefixOctets.Count -ge 3) { $prefixOctets[2] + $assigned } else { $id % 256 }
        if ($third -gt 255) {
            $rows += New-WinUtilNetToolRow -Name "VLAN $id" -Detail "第三段 $third 超出 255，改用 /22 一类更大网段或换编号基址" -Status "越界"
            continue
        }
        if ($prefixOctets.Count -lt 3 -and $id -gt 255) { $wrapped = $true }

        $network = "$($prefixOctets[0]).$($prefixOctets[1]).$third.0"
        $detail = "$network/24 · 网关 $($network -replace '\.0$', '.1') · 可用 254 台"
        $status = if ($id -ge 1006) { "扩展段" } else { "STP $((32768 + $id))" }
        $rows += New-WinUtilNetToolRow -Name "VLAN $id" -Detail $detail -Status $status
        $assigned++
    }

    $notes = @()
    $notes += "输入 $($ids.Count) 个 VLAN 号，输出 $(@($rows).Count) 行；编号基址 $($prefixOctets -join '.')，每 VLAN 对应一个 /24。"
    if ($prefixOctets.Count -ge 3) {
        $notes += "第三段从 $($prefixOctets[2]) 起按顺序递增，与 VLAN 号本身无关。"
    } else {
        $notes += "第三段直接取 VLAN 号，所以 10.10.10.0/24 就是 VLAN 10，一眼对得上。"
        if ($wrapped) {
            $notes += "有 VLAN 号超过 255：第三段按 256 取余，会和别的 VLAN 撞段。请填三段基址（如 10.30.0）或改用更大网段规划。"
        }
    }
    $notes += "VLAN 1~1005 是传统范围，1006~4094 在思科上属于扩展范围（透明模式或 VTP3 才能配置），非思科交换机一般全范围可用。"
    $notes += "三层交换机上每个 VLAN 建一个 SVI 作网关；VLAN 号会加进 STP 桥优先级（默认 32768 + VLAN ID）。"

    return New-WinUtilNetToolResult -Rows $rows -Notes $notes
}

function Get-WinUtilNetMtuPlan {

    <#

    .SYNOPSIS
        MTU calculator: what is left for data once every header and tunnel is counted

    #>

    param(
        [string]$Mtu,
        [string]$Payload
    )

    $base = 1500
    if (-not [string]::IsNullOrWhiteSpace($Mtu)) {
        if ($Mtu.Trim() -notmatch '^\d{2,5}$') {
            return New-WinUtilNetToolError -Message "MTU 请写 68~9000 之间的整数，例如 1500 或 9000。"
        }
        $base = [int]$Mtu.Trim()
        if ($base -lt 68 -or $base -gt 65535) {
            return New-WinUtilNetToolError -Message "MTU $base 超出可用范围（68~65535，常用 1500 或 9000）。"
        }
    }

    $need = $null
    if ($Payload -and $Payload.Trim() -match '^\d{1,5}$') { $need = [int]$Payload.Trim() }

    $rows = @()
    $rows += New-WinUtilNetToolRow -Name "IPv4 + TCP" -Detail "头部 40 字节，数据 $(($base - 40)) 字节" -Status "网页/RDP/SMB 载荷"
    $rows += New-WinUtilNetToolRow -Name "IPv4 + UDP" -Detail "头部 28 字节，数据 $(($base - 28)) 字节" -Status "DNS/NTP/语音"
    $rows += New-WinUtilNetToolRow -Name "ping 不分片探测" -Detail "ping -f -l N，N + 28 必须 ≤ 链路 MTU" -Status "N 最大 $(($base - 28))"

    foreach ($entry in @(
            @{Name = "纯以太网"; Over = 0},
            @{Name = "802.1Q VLAN 标签"; Over = 4},
            @{Name = "PPPoE 拨号"; Over = 8},
            @{Name = "GRE 隧道"; Over = 24},
            @{Name = "VXLAN 叠加网"; Over = 50},
            @{Name = "IPsec 传输模式"; Over = 56},
            @{Name = "WireGuard"; Over = 80}
        )) {
        $effective = $base - $entry.Over
        $status = if ($entry.Over -eq 0) { "基准" } else { "有效 MTU $effective" }
        $rows += New-WinUtilNetToolRow -Name $entry.Name -Detail "额外开销 $($entry.Over) 字节 · TCP 数据 $($effective - 40) 字节" -Status $status
    }

    $notes = @()
    $notes += "MTU $base 指 IP 层的最大报文；以太网帧头 14 + FCS 4 不计入 MTU，所以线上传的是 $($base + 18) 字节的帧。"
    if ($need) {
        $required = $need + 40
        $rows += New-WinUtilNetToolRow -Name "按数据量反推" -Detail "要一次装下 $need 字节 TCP 数据，MTU 至少 $required" -Status "含 IP+TCP 头 40"
        $notes += "承载 $need 字节 TCP 数据需要 MTU $required；若再走 PPPoE，物理链路 MTU 需 $((($required + 8)))，或把 MSS 压到 $($need - 8)。"
    }
    $notes += "内网千兆/万兆可全链路开 9000（jumbo），但网卡、交换机、路由器必须同时改，否则大包被丢弃且难以定位。"

    return New-WinUtilNetToolResult -Rows $rows -Notes $notes
}

function Get-WinUtilNetStpPriority {

    <#

    .SYNOPSIS
        STP bridge priority: the configured value, the VLAN folded into it, and who wins

    #>

    param(
        [string]$Priority,
        [string]$Vlan
    )

    $vlan = 1
    if (-not [string]::IsNullOrWhiteSpace($Vlan)) {
        if ($Vlan.Trim() -notmatch '^\d{1,4}$') {
            return New-WinUtilNetToolError -Message "VLAN ID 请写 1~4094 的整数。"
        }
        $vlan = [int]$Vlan.Trim()
        if ($vlan -lt 1 -or $vlan -gt 4094) {
            return New-WinUtilNetToolError -Message "VLAN ID $vlan 超出 1~4094。"
        }
    }

    $wanted = 32768
    if (-not [string]::IsNullOrWhiteSpace($Priority)) {
        if ($Priority.Trim() -notmatch '^\d{1,6}$') {
            return New-WinUtilNetToolError -Message "优先级请写数字，例如 4096、8192、32768。"
        }
        $wanted = [int]$Priority.Trim()
    }

    if ($wanted -gt 61440) {
        return New-WinUtilNetToolError -Message "STP 优先级只能取 0~61440，且必须是 4096 的整数倍（$wanted 太大）。"
    }

    $effective = [int]([Math]::Floor($wanted / 4096) * 4096)
    $combined = $effective + $vlan
    $defaultCombined = 32768 + $vlan

    $rows = @()
    $rows += New-WinUtilNetToolRow -Name "配置命令" -Detail "spanning-tree vlan $vlan priority $effective" -Status "4096 的整数倍"
    $rows += New-WinUtilNetToolRow -Name "组合桥优先级" -Detail "$effective + VLAN $vlan = $combined" -Status "比较用这个值"
    $rows += New-WinUtilNetToolRow -Name "十六进制" -Detail ("0x{0:X4}" -f $combined) -Status "BPDU 前两字节"
    $rows += New-WinUtilNetToolRow -Name "与默认相比" -Detail "默认 32768 + VLAN = $defaultCombined" -Status $(if ($combined -lt $defaultCombined) { "更优（更易成根桥）" } elseif ($combined -gt $defaultCombined) { "不如默认" } else { "与默认相同" })

    if ($wanted -ne $effective) {
        $nearby = @()
        foreach ($step in @(($effective - 4096), ($effective + 4096))) {
            if ($step -ge 0 -and $step -le 61440) { $nearby += $step }
        }
        $rows += New-WinUtilNetToolRow -Name "取整说明" -Detail "$wanted 不是 4096 的整数倍，交换机会向下取整为 $effective" -Status "相邻可用 $(@($nearby) -join ' / ')"
    }

    $notes = @()
    $notes += "STP 选根桥依次比较：桥优先级 → 到根的累积路径开销 → 发送者桥 ID（优先级 + MAC）→ 端口 ID。数字越小越优。"
    $notes += "要让某台成为 VLAN $vlan 的根桥，把它设成 4096 或 8192；备用根桥设 32768 与 4096 之间的 8192/16384。"
    $notes += "RSTP 同样是 4096 步长；MST 在实例上配置优先级，不再叠加 VLAN 号。"

    return New-WinUtilNetToolResult -Rows $rows -Notes $notes
}

function Get-WinUtilNetRadix {

    <#

    .SYNOPSIS
        Base conversion, including the dotted-quad form an ACL or wildcard is written in

    #>

    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return New-WinUtilNetToolError -Message "请输入要转换的数值：500、0x1F4、111110100b 或 10.0.0.1 均可。"
    }

    $token = $Text.Trim()
    $dec = [long]0
    $from = ""

    if ($token -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') {
        $value = ConvertFrom-WinUtilIPv4 -Text $token
        if ($null -eq $value) {
            return New-WinUtilNetToolError -Message "「$token」各段都必须在 0~255 之间。"
        }
        $dec = [long]$value
        $from = "IPv4 点分十进制"
    } elseif ($token -match '^(0[xX])[0-9A-Fa-f]{1,8}$') {
        $dec = [long][Convert]::ToUInt64($token.Substring(2), 16)
        $from = "十六进制"
    } elseif ($token -match '^[0-9A-Fa-f]{1,8}[hH]$') {
        $dec = [long][Convert]::ToUInt64($token.Substring(0, $token.Length - 1), 16)
        $from = "十六进制（h 后缀）"
    } elseif ($token -match '^[01]{1,32}[bB]$') {
        $dec = [long][Convert]::ToUInt64($token.Substring(0, $token.Length - 1), 2)
        $from = "二进制"
    } elseif ($token -match '^[0-7]{1,12}[oO]$') {
        $dec = [long][Convert]::ToUInt64($token.Substring(0, $token.Length - 1), 8)
        $from = "八进制"
    } elseif ($token -match '^\d+$') {
        if ([long]::TryParse($token, [ref]$dec) -eq $false -or $dec -gt 4294967295) {
            return New-WinUtilNetToolError -Message "「$token」超出本工具支持的 0~4294967295 范围。"
        }
        $from = "十进制"
    } else {
        return New-WinUtilNetToolError -Message "无法识别「$token」。可写 500、0x1F4、1F4h、111110100b 或 10.0.0.1。"
    }

    $binary = [Convert]::ToString($dec, 2)
    $padded = $binary.PadLeft([Math]::Ceiling($binary.Length / 4) * 4, "0")
    $grouped = (($padded -split '(.{4})' | Where-Object { $_ }) -join " ")

    $rows = @()
    $rows += New-WinUtilNetToolRow -Name "十进制" -Detail "$dec" -Status "输入按 $from 读取"
    $rows += New-WinUtilNetToolRow -Name "十六进制" -Detail ("0x{0}" -f [Convert]::ToString($dec, 16).ToUpperInvariant()) -Status "每 4 位二进制一位十六进制"
    $rows += New-WinUtilNetToolRow -Name "二进制" -Detail $binary -Status "共 $($binary.Length) 位"
    $rows += New-WinUtilNetToolRow -Name "二进制分组" -Detail $grouped -Status "四位一组便于手算掩码"
    $rows += New-WinUtilNetToolRow -Name "八进制" -Detail ("0{0}" -f [Convert]::ToString($dec, 8)) -Status ""
    $rows += New-WinUtilNetToolRow -Name "点分十进制" -Detail (ConvertTo-WinUtilIPv4 -Value $dec) -Status "按 IPv4 解释"

    $notes = @("$from $token 的数值为 $dec。")
    if ($dec -le 255) {
        $octetBinary = [Convert]::ToString($dec, 2).PadLeft(8, "0")
        $notes += "作为单个八位组：$dec = $octetBinary，按 128+64+32+16+8+4+2+1 逐项相加得到，其中有 $(Get-WinUtilNetMaskBits -Octet $dec) 个 1。"
    }
    $notes += "掩码手算就是这个加法：255.255.252.0 里的 252 = 128+64+32+16+8+4，所以是 /22。"

    return New-WinUtilNetToolResult -Rows $rows -Notes $notes
}

function Get-WinUtilNetMaskBits {
    param([int]$Octet)

    $bits = 0
    $value = $Octet
    for ($i = 0; $i -lt 8; $i++) {
        if ($value % 2 -eq 1) { $bits++ }
        $value = [int][Math]::Floor($value / 2)
    }
    return $bits
}

function Get-WinUtilNetRateTool {

    <#

    .SYNOPSIS
        Rate units: bits per second against bytes per second, which is where the 8x confusion lives

    #>

    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return New-WinUtilNetToolError -Message "请输入速率，例如 100M、1Gbps、10MB/s、500Kbps。"
    }

    $result = ConvertFrom-WinUtilNetRate -Text $Text
    if ($null -eq $result) {
        return New-WinUtilNetToolError -Message "无法识别「$Text」。网络速率用 bps/Kbps/Mbps/Gbps，文件速度用 B/s、KB/s、MB/s、GB/s。"
    }

    $bits = $result.BitsPerSecond
    $bytesPerSecond = $result.BytesPerSecond

    $rows = @()
    $rows += New-WinUtilNetToolRow -Name "比特每秒" -Detail ("{0:N0} bps" -f $bits) -Status "链路标称口径"
    $rows += New-WinUtilNetToolRow -Name "十进制换算" -Detail ("{0:N2} Mbps · {1:N4} Gbps" -f ($bits / 1e6), ($bits / 1e9)) -Status "网络按 1000 进位"
    $rows += New-WinUtilNetToolRow -Name "字节每秒" -Detail ("{0:N2} MB/s（1024 进位）" -f ($bytesPerSecond / 1MB)) -Status "复制进度条上的数"
    $rows += New-WinUtilNetToolRow -Name "字节每秒(十进制)" -Detail ("{0:N2} MB/s" -f ($bytesPerSecond / 1e6)) -Status "厂商标称口径"
    $rows += New-WinUtilNetToolRow -Name "每小时流量" -Detail (Format-WinUtilNetBytes ($bytesPerSecond * 3600)) -Status "带宽占用/流量费估算"
    $rows += New-WinUtilNetToolRow -Name "传 1 GB 需" -Detail (Get-WinUtilNetDurationText -Seconds (1GB / [Math]::Max(1, $bytesPerSecond))) -Status ""

    $notes = @("$($Text.Trim()) = 每秒 $([int64]$bits) 比特，即每秒 $([int64]$bytesPerSecond) 字节。")
    $notes += "运营商说的 100M 是 100 Mbps，下载上限约 12.5 MB/s；测到 5 MB/s 说明链路或对方限速，不是线路断了。"

    return New-WinUtilNetToolResult -Rows $rows -Notes $notes
}

function Get-WinUtilNetTimestampTool {

    <#

    .SYNOPSIS
        Unix time to local date and back

    #>

    param([string]$Text)

    $notes = @()
    $token = if ($Text) { $Text.Trim() } else { "" }
    $offset = $null

    if ([string]::IsNullOrWhiteSpace($token)) {
        $offset = [DateTimeOffset]::UtcNow
        $notes += "未填写，取当前时间。"
    } elseif ($token -match '^\d{13}$') {
        $offset = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$token)
        $notes += "$token 是 13 位毫秒时间戳。"
    } elseif ($token -match '^\d{10}$') {
        $offset = [DateTimeOffset]::FromUnixTimeSeconds([long]$token)
        $notes += "$token 是 10 位秒时间戳。"
    } elseif ($token -match '^\d{1,9}$') {
        $offset = [DateTimeOffset]::FromUnixTimeSeconds([long]$token)
        $notes += "$token 不足 10 位，按秒时间戳读取。"
    } else {
        foreach ($format in @("yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy/MM/dd HH:mm:ss", "yyyy/MM/dd HH:mm", "yyyyMMddHHmmss", "yyyy-MM-dd", "yyyy/M/d H:mm", "yyyy/M/d")) {
            $parsed = [DateTime]::MinValue
            if ([DateTime]::TryParseExact($token, $format, [System.Globalization.CultureInfo]::GetCultureInfo("zh-CN"), [System.Globalization.DateTimeStyles]::None, [ref]$parsed)) {
                $offset = [DateTimeOffset]::new($parsed, [TimeZoneInfo]::Local.GetUtcOffset($parsed))
                break
            }
        }
        if (-not $offset) {
            $loose = [DateTime]::MinValue
            if ([DateTime]::TryParse($token, [ref]$loose)) {
                $offset = [DateTimeOffset]::new($loose, [TimeZoneInfo]::Local.GetUtcOffset($loose))
                $notes += "按本机区域设置读作 $loose。"
            }
        }
        if (-not $offset) {
            return New-WinUtilNetToolError -Message "无法识别「$token」。可用 2026-10-26 14:30:00 这类日期，或 10/13 位时间戳。"
        }
    }

    $local = $offset.ToLocalTime()
    # DateTimeOffset.ToUtc is .NET Core only; Framework, where PowerShell 5 runs, spells it
    # ToUniversalTime and returns the same zero-offset value
    $utc = $offset.ToUniversalTime()
    $weekday = @("星期日", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六")[[int]$local.DayOfWeek]

    $delta = [DateTimeOffset]::UtcNow - $offset
    $span = [TimeSpan]::FromSeconds([Math]::Abs($delta.TotalSeconds))
    $when = if ($span.TotalDays -ge 1) {
        "$([int]$span.Days) 天 $([int]$span.Hours) 小时"
    } elseif ($span.TotalHours -ge 1) {
        "$([int]$span.Hours) 小时 $([int]$span.Minutes) 分钟"
    } elseif ($span.TotalMinutes -ge 1) {
        "$([int]$span.Minutes) 分钟"
    } else {
        "$([int]$span.TotalSeconds) 秒"
    }
    $direction = if ($delta.TotalSeconds -ge 0) { "之前" } else { "之后" }

    $rows = @()
    $rows += New-WinUtilNetToolRow -Name "本地时间" -Detail $local.ToString("yyyy-MM-dd HH:mm:ss") -Status $weekday
    $rows += New-WinUtilNetToolRow -Name "UTC 时间" -Detail $utc.ToString("yyyy-MM-dd HH:mm:ss") -Status $local.ToString("yyyy-MM-ddTHH:mm:sszzz")
    $rows += New-WinUtilNetToolRow -Name "秒时间戳" -Detail "$($offset.ToUnixTimeSeconds())" -Status "毫秒 $($offset.ToUnixTimeMilliseconds())"
    $rows += New-WinUtilNetToolRow -Name "相对当前" -Detail "$when$direction" -Status "时区 $((Get-TimeZone).Id)"

    $notes += "本机时区 UTC$((Get-TimeZone).BaseUtcOffset.ToString())（$((Get-TimeZone).DisplayName)）；日志与文件时间戳都是本地时间。"
    $notes += "10 位是秒、13 位是毫秒；Excel 里的日期序列号请在 Excel 内用 =TEXT(A1,""yyyy-mm-dd hh:mm:ss"") 转换。"

    return New-WinUtilNetToolResult -Rows $rows -Notes $notes
}
