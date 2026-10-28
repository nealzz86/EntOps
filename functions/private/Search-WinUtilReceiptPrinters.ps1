function Search-WinUtilReceiptPrinters {

    <#

    .SYNOPSIS
        Finds devices answering on TCP 9100 in the local /24 segments plus receipt printer defaults

    .DESCRIPTION
        Receipt printers (Xprinter XQ200, Epson TM-T82III) expose their raw data port on TCP
        9100. Each active IPv4 interface contributes its /24, so a laptop plugged into the
        store switch finds the printer without being told the range. Probes run in batches of
        parallel BeginConnect calls with a short deadline to keep the scan a few seconds long.

    #>
    param([string]$KnownIp)

    $targets = [System.Collections.Generic.List[string]]::new()
    [void]$targets.Add("192.168.123.100")
    [void]$targets.Add("192.168.192.168")
    if (Test-WinUtilIPv4 $KnownIp) { [void]$targets.Add($KnownIp.Trim()) }

    $localIps = @()
    try {
        $localIps = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.254.*" -and $_.PrefixOrigin -ne "WellKnown" })
    } catch { }

    foreach ($local in $localIps) {
        $octets = $local.IPAddress -split '\.'
        if ($octets.Count -ne 4) { continue }
        $base = $octets[0..2] -join "."
        foreach ($hostId in 1..254) { [void]$targets.Add("$base.$hostId") }
    }

    $unique = @($targets | Select-Object -Unique)
    $open = [System.Collections.Generic.List[string]]::new()

    $batchSize = 64
    $timeoutMs = 700
    for ($start = 0; $start -lt $unique.Count; $start += $batchSize) {
        $end = [Math]::Min($start + $batchSize - 1, $unique.Count - 1)
        $conns = @()
        foreach ($ip in $unique[$start..$end]) {
            $client = New-Object System.Net.Sockets.TcpClient
            try {
                $ar = $client.BeginConnect($ip, 9100, $null, $null)
                $conns += @{ Ip = $ip; Client = $client; Ar = $ar }
            } catch {
                $client.Close()
            }
        }

        $waitStart = Get-Date
        while (((Get-Date) - $waitStart).TotalMilliseconds -lt $timeoutMs) {
            $allDone = $true
            foreach ($c in $conns) {
                if (-not $c.Ar.IsCompleted) { $allDone = $false; break }
            }
            if ($allDone) { break }
            Start-Sleep -Milliseconds 25
        }

        foreach ($c in $conns) {
            try {
                if ($c.Ar.IsCompleted) {
                    $c.Client.EndConnect($c.Ar)
                    [void]$open.Add($c.Ip)
                }
            } catch { }
            try { $c.Client.Close() } catch { }
        }

        Step-WinUtilJob -Status "正在扫描小票打印机（$($end + 1)/$($unique.Count)）" -Percent (10 + [int](80 * $end / [Math]::Max($unique.Count - 1, 1)))
    }

    return $open
}
