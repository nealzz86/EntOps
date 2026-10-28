function Get-WinUtilPktmonDir {

    <#

    .SYNOPSIS
        Where captures are written, created on demand

    #>

    $root = if ($sync -and $sync.winutildir) { $sync.winutildir } else { Join-Path $env:LocalAppData "winutil" }
    $dir = Join-Path $root "captures"
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    return $dir
}

function Get-WinUtilNativeText {

    <#

    .SYNOPSIS
        Native command output merged into plain lines

    .DESCRIPTION
        A command's error stream arrives as error records; joined straight into a message they
        print their exception type after every line, which is noise an operator has to read past.

    #>

    param([object]$Records)

    return (@($Records | ForEach-Object {
        if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { [string]$_ }
    }) -join "`n")
}

function Start-WinUtilPktmonCapture {

    <#

    .SYNOPSIS
        Starts a system packet capture with the built-in pktmon

    .DESCRIPTION
        No driver and no download: pktmon ships with Windows 10 and above. Port filters are
        optional and are what keeps a capture on a busy store link readable.

    #>

    param(
        [int[]]$Ports = @()
    )

    if (-not (Get-Command pktmon.exe -ErrorAction SilentlyContinue)) {
        throw "系统未提供 pktmon.exe（需要 Windows 10 1809 及以上），无法抓包。"
    }

    # A leftover session from a crashed run would make pktmon start refuse, so clear it first
    $null = pktmon.exe stop 2>&1
    $null = pktmon.exe filter remove 2>&1

    # One filter per port: pktmon matches every condition inside a single filter, so two ports in
    # one filter would mean traffic between them, not traffic on either.
    foreach ($port in $Ports) {
        $null = pktmon.exe filter add "entops$port" -p $port 2>&1
    }

    $file = Join-Path (Get-WinUtilPktmonDir) ("capture_{0}.etl" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
    $started = pktmon.exe start --capture --pkt-size 0 -f $file 2>&1
    $startCode = $LASTEXITCODE
    if ($startCode -ne 0) {
        $null = pktmon.exe filter remove 2>&1
        $text = Get-WinUtilNativeText -Records $started
        throw "pktmon 启动失败（抓包需要以管理员身份运行本工具）：$($text -replace "`r?`n", ' ')"
    }

    $sync.PktmonFile = $file
    $sync.PktmonStarted = Get-Date
    return $file
}

function Stop-WinUtilPktmonImmediately {

    <#

    .SYNOPSIS
        Ends a capture without converting it, for the paths that cannot wait on a conversion

    .DESCRIPTION
        Leaving the capture running keeps the PktMon driver writing to disk with nothing left to
        stop it, which is worse than losing the analysis of a session nobody asked to read.

    #>

    $file = if ($sync.PktmonFile) { [string]$sync.PktmonFile } else { $null }

    # Runs on the shutdown path: nothing here may throw, or the window cannot close
    try { $null = pktmon.exe stop 2>&1 } catch { }
    try { $null = pktmon.exe filter remove 2>&1 } catch { }
    $sync.PktmonFile = $null
    $sync.PktmonRunning = $false

    if ($file -and (Test-Path -LiteralPath $file)) {
        Write-WinUtilLog -Component "NetDiag" -Message "抓包已停止（未做文本分析），原始文件：$file"
    }
}

function Stop-WinUtilPktmonCapture {

    <#

    .SYNOPSIS
        Stops the capture and converts it to readable text

    #>

    if (-not (Get-Command pktmon.exe -ErrorAction SilentlyContinue)) {
        throw "系统未提供 pktmon.exe，无法抓包。"
    }

    $file = if ($sync.PktmonFile) { [string]$sync.PktmonFile } else { $null }
    $output = Get-WinUtilNativeText -Records (pktmon.exe stop 2>&1)
    $sync.PktmonFile = $null

    # pktmon names the file itself when the caller did not pass one, so read it back from output
    if (-not $file) {
        $match = [regex]::Match($output, "([A-Za-z]:\\[^\r\n`"]*?\.etl)")
        if ($match.Success) { $file = $match.Groups[1].Value }
    }
    if (-not $file) { $file = Join-Path (Get-WinUtilPktmonDir) "PktMon.etl" }

    $null = pktmon.exe filter remove 2>&1

    if (-not (Test-Path -LiteralPath $file)) {
        return [pscustomobject]@{ File = $null; Text = $null; Report = $null }
    }

    $textPath = [IO.Path]::ChangeExtension($file, ".txt")
    $converted = Get-WinUtilNativeText -Records (pktmon.exe etl2txt $file -o $textPath 2>&1)
    $convertCode = $LASTEXITCODE
    if ($convertCode -ne 0 -or -not (Test-Path -LiteralPath $textPath)) {
        # The etl is still there, so the capture is not lost even when the text step refuses
        return [pscustomobject]@{
            File   = $file
            Text   = $null
            Report = $null
            Error  = $converted
        }
    }

    return [pscustomobject]@{
        File   = $file
        Text   = $textPath
        Report = Get-WinUtilPktmonReport -Path $textPath
        Error  = $null
    }
}

function Add-WinUtilPktmonFlow {

    <#

    .SYNOPSIS
        Records one packet block into the flow table, returning whether it was classifiable

    .DESCRIPTION
        The field labels in a pktmon dump are not a documented contract and differ between
        Windows builds, so each field is matched against the spellings seen in the wild. A block
        that names no address is left out of the table but still counted in the dump's totals,
        which is what lets the tool say "parsed nothing" rather than reporting an empty answer.

    #>

    param(
        [Parameter(Mandatory)][hashtable]$Table,
        [Parameter(Mandatory)][string]$Block
    )

    $src = $null
    $dst = $null
    $srcPort = $null
    $dstPort = $null
    $proto = $null
    $size = [int64]0

    $m = [regex]::Match($Block, '(?im)^\s*(?:SourceAddress|SrcIp|Src)\s*:\s*([0-9A-Fa-f\.:]+)')
    if ($m.Success) { $src = $m.Groups[1].Value }
    $m = [regex]::Match($Block, '(?im)^\s*(?:DestAddress|DstIp|Dst)\s*:\s*([0-9A-Fa-f\.:]+)')
    if ($m.Success) { $dst = $m.Groups[1].Value }
    if (-not $src -and -not $dst) { return $false }

    $m = [regex]::Match($Block, '(?im)^\s*(?:SourcePort|SrcPort)\s*:\s*(\d+)')
    if ($m.Success) { $srcPort = $m.Groups[1].Value }
    $m = [regex]::Match($Block, '(?im)^\s*(?:DestPort|DstPort)\s*:\s*(\d+)')
    if ($m.Success) { $dstPort = $m.Groups[1].Value }

    # The IPv4/IPv6 header line reads "Protocol: 06 (TCP)"; the transport header lines are the
    # ones carrying ports, so a numbered protocol always wins
    $m = [regex]::Match($Block, '(?im)^\s*(?:IP Protocol|Protocol)\s*:\s*(\d+)')
    if ($m.Success) { $proto = [int]$m.Groups[1].Value }

    $protoName = "其他"
    if ($null -ne $proto) {
        $protoName = switch ($proto) { 1 { "ICMP" } 6 { "TCP" } 17 { "UDP" } 58 { "ICMPv6" } default { "协议 $proto" } }
    } elseif ($srcPort -or $dstPort) {
        $protoName = "TCP/UDP"
    }

    $key = "{0}{1} → {2}{3} [{4}]" -f $src, $(if ($srcPort) { ":$srcPort" } else { "" }),
    $dst, $(if ($dstPort) { ":$dstPort" } else { "" }), $protoName

    if (-not $Table.ContainsKey($key)) {
        $Table[$key] = [pscustomobject]@{ Count = 0; Bytes = [int64]0 }
    }

    $m = [regex]::Match($Block, '(?im)^\s*(?:TotalSize|Size)\s*:\s*(\d+)')
    if ($m.Success) { $Table[$key].Bytes += [int64]$m.Groups[1].Value }
    $Table[$key].Count++

    return $true
}

function Get-WinUtilPktmonReport {

    <#

    .SYNOPSIS
        Summarises a pktmon text dump into the flows that carried the traffic

    .DESCRIPTION
        pktmon's own output is one block per packet, which nobody reads on a store network. This
        collapses it to per-flow counts, which is what answers "who is talking to whom, how much".

    #>

    param([string]$Path)

    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }

    $packets = 0
    $matched = 0
    $flowTable = @{}
    $block = New-Object System.Text.StringBuilder

    # Returns whether the block was classifiable: a scriptblock runs in a child scope, so the
    # counter itself has to be incremented by the caller
    $flushBlock = {
        if ($block.Length -eq 0) { return $false }
        $classified = Add-WinUtilPktmonFlow -Table $flowTable -Block $block.ToString()
        $null = $block.Clear()
        return $classified
    }

    $reader = [System.IO.File]::OpenText($Path)
    try {
        while (-not $reader.EndOfStream) {
            $line = $reader.ReadLine()

            if ($line -match '^\[Packet\s*#') {
                # The block belonging to a packet ends where the next one starts
                if ($packets -gt 0 -and (& $flushBlock)) { $matched++ }
                $packets++
                continue
            }
            $null = $block.AppendLine($line)
        }
        if (& $flushBlock) { $matched++ }
    } finally {
        $reader.Dispose()
    }

    $totalBytes = [int64]0
    foreach ($flow in $flowTable.Values) { $totalBytes += $flow.Bytes }

    $flows = @($flowTable.GetEnumerator() | Sort-Object { $_.Value.Count } -Descending | Select-Object -First 40 | ForEach-Object {
        [pscustomobject]@{
            Name   = $_.Key
            Detail = "{0} 个报文 · {1}" -f $_.Value.Count, (Format-WinUtilNetBytes $_.Value.Bytes)
            Status = $_.Value.Count
        }
    })

    return [pscustomobject]@{
        Packets = $packets
        Matched = $matched
        Bytes   = $totalBytes
        Flows   = $flows
    }
}
