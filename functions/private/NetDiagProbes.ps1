function Test-WinUtilPing {

    <#

    .SYNOPSIS
        Pings a host and returns the round trip statistics

    #>

    param(
        [Parameter(Mandatory)][string]$Target,
        [int]$Count = 4,
        [int]$TimeoutMs = 1000,
        [int]$BufferSize = 32
    )

    $rounds = @()
    $errorText = $null

    for ($i = 1; $i -le $Count; $i++) {
        $ping = New-Object System.Net.NetworkInformation.Ping
        try {
            $reply = $ping.Send($Target, $TimeoutMs, (New-Object byte[] $BufferSize))
            if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                $rounds += [pscustomobject]@{
                    Address = $reply.Address.ToString()
                    Round   = $reply.RoundtripTime
                    Ttl     = $reply.Options.Ttl
                }
            }
        } catch {
            $errorText = $_.Exception.Message
        } finally {
            $ping.Dispose()
        }
        if ($i -lt $Count) { Start-Sleep -Milliseconds 120 }
    }

    $received = @($rounds).Count
    $times = @($rounds | ForEach-Object { [double]$_.Round })

    return [pscustomobject]@{
        Target   = $Target
        Sent     = $Count
        Received = $received
        Loss     = [Math]::Round(100 * ($Count - $received) / $Count, 1)
        Min      = if ($received) { [Math]::Round(($times | Measure-Object -Minimum).Minimum, 1) } else { 0 }
        Max      = if ($received) { [Math]::Round(($times | Measure-Object -Maximum).Maximum, 1) } else { 0 }
        Avg      = if ($received) { [Math]::Round(($times | Measure-Object -Average).Average, 1) } else { 0 }
        Jitter   = if ($received -gt 1) {
            [Math]::Round((($times | ForEach-Object { [Math]::Abs($_ - (($times | Measure-Object -Average).Average)) } | Measure-Object -Average).Average), 1)
        } else { 0 }
        Rounds   = $rounds
        Address  = if ($received) { $rounds[0].Address } else { $null }
        Error    = if ($received -eq 0) { $errorText } else { $null }
    }
}

function Start-WinUtilTraceRoute {

    <#

    .SYNOPSIS
        Walks the path to a host one time to live at a time

    .DESCRIPTION
        Uses the same primitive as ping so it works without tracert.exe and reports the address
        each hop answered from, which is what identifies the hop.

    #>

    param(
        [Parameter(Mandatory)][string]$Target,
        [int]$MaxHops = 20,
        [int]$TimeoutMs = 1000
    )

    $resolved = $null
    try { $resolved = ([System.Net.Dns]::GetHostAddresses($Target) | Select-Object -First 1).IPAddressToString } catch { }

    $hops = @()
    for ($ttl = 1; $ttl -le $MaxHops; $ttl++) {
        $ping = New-Object System.Net.NetworkInformation.Ping
        $options = New-Object System.Net.NetworkInformation.PingOptions
        $options.Ttl = $ttl
        $answered = $null
        $round = -1
        try {
            $reply = $ping.Send($Target, $TimeoutMs, (New-Object byte[] 32), $options)
            if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                $answered = $reply.Address.ToString()
                $round = $reply.RoundtripTime
            } elseif ($reply.Address) {
                # A timed out reply carries the address that answered. When that is not the
                # destination, it is the router whose TTL expired, which is the hop being looked
                # for; when it is the destination, nothing answered and the hop stays blank.
                $candidate = $reply.Address.ToString()
                if ($candidate -ne $Target -and (-not $resolved -or $candidate -ne $resolved)) {
                    $answered = $candidate
                    $round = $reply.RoundtripTime
                }
            }
        } catch {
            $answered = $null
        } finally {
            $ping.Dispose()
        }

        $hops += [pscustomobject]@{
            Hop     = $ttl
            Address = if ($answered) { $answered } else { "*" }
            Round   = $round
        }

        if ($answered -and $resolved -and ($answered -eq $resolved)) { break }
        if ($answered -and $answered -eq $Target) { break }
    }

    return [pscustomobject]@{ Target = $Target; Resolved = $resolved; Hops = $hops }
}

function Search-WinUtilOpenPorts {

    <#

    .SYNOPSIS
        Parallel TCP connect scan over one or more hosts

    .DESCRIPTION
        Connects in batches with a shared deadline, which is what keeps a /24 sweep under a
        minute instead of one timeout per address. A completed connection is an open port;
        anything else, including refused, is closed.

    #>

    param(
        [Parameter(Mandatory)][string[]]$Targets,
        [Parameter(Mandatory)][int[]]$Ports,
        [int]$TimeoutMs = 700,
        [int]$BatchSize = 64,
        [scriptblock]$OnProgress
    )

    $open = @()
    $jobs = @()
    $index = 0
    $total = $Targets.Count * $Ports.Count

    foreach ($target in $Targets) {
        foreach ($port in $Ports) {
            $index++
            if ($OnProgress -and ($index % 200 -eq 0)) { & $OnProgress $index $total }

            $client = New-Object System.Net.Sockets.TcpClient
            $async = $null
            try {
                $async = $client.BeginConnect($target, $port, $null, $null)
            } catch {
                $client.Dispose()
                continue
            }
            $jobs += [pscustomobject]@{ Target = $target; Port = $port; Client = $client; Async = $async }

            if ($jobs.Count -ge $BatchSize) {
                $open += Complete-WinUtilPortBatch -Batch $jobs -TimeoutMs $TimeoutMs
                $jobs = @()
            }
        }
    }

    if ($jobs.Count -gt 0) {
        $open += Complete-WinUtilPortBatch -Batch $jobs -TimeoutMs $TimeoutMs
    }

    if ($OnProgress) { & $OnProgress $total $total }
    return $open
}

function Complete-WinUtilPortBatch {

    <#

    .SYNOPSIS
        Waits for one scan batch up to a shared deadline and reports what answered

    #>

    param(
        [Parameter(Mandatory)][object[]]$Batch,
        [int]$TimeoutMs = 700
    )

    $found = @()
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)

    while ((Get-Date) -lt $deadline) {
        $pending = $false
        foreach ($item in $Batch) {
            if (-not $item.Async.IsCompleted) { $pending = $true }
        }
        if (-not $pending) { break }
        Start-Sleep -Milliseconds 25
    }

    foreach ($item in $Batch) {
        try {
            if ($item.Async.IsCompleted) {
                try {
                    $item.Client.EndConnect($item.Async)
                    if ($item.Client.Connected) {
                        $found += [pscustomobject]@{ Target = $item.Target; Port = $item.Port }
                    }
                } catch { }
            }
        } finally {
            try { $item.Client.Close() } catch { }
            $item.Client.Dispose()
        }
    }

    return $found
}

function Search-WinUtilLiveHosts {

    <#

    .SYNOPSIS
        Finds the addresses answering inside a /24, with the neighbour table for MACs

    #>

    param(
        [Parameter(Mandatory)][string]$Prefix,
        [int]$TimeoutMs = 400,
        [scriptblock]$OnProgress
    )

    $targets = 1..254 | ForEach-Object { "$Prefix.$_" }
    $alive = @()
    $batchSize = 64
    $index = 0

    for ($start = 0; $start -lt $targets.Count; $start += $batchSize) {
        $slice = $targets[$start..([Math]::Min($start + $batchSize - 1, $targets.Count - 1))]
        $pending = @()

        foreach ($address in $slice) {
            $index++
            $ping = New-Object System.Net.NetworkInformation.Ping
            $task = $null
            try {
                # SendPingAsync, not SendAsync: the latter is the event-based API and returns
                # nothing to wait on, so a sweep with it would finish before any reply arrived
                $task = $ping.SendPingAsync($address, $TimeoutMs, (New-Object byte[] 32))
            } catch {
                $ping.Dispose()
                continue
            }
            $pending += [pscustomobject]@{ Address = $address; Ping = $ping; Task = $task }
        }

        $deadline = (Get-Date).AddMilliseconds(($TimeoutMs + 300))
        while ((Get-Date) -lt $deadline) {
            $outstanding = @($pending | Where-Object { -not $_.Task.IsCompleted })
            if ($outstanding.Count -eq 0) { break }
            Start-Sleep -Milliseconds 25
        }

        foreach ($item in $pending) {
            try {
                if ($item.Task.IsCompleted -and -not $item.Task.IsFaulted -and $item.Task.Result) {
                    $reply = $item.Task.Result
                    if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                        $alive += [pscustomobject]@{
                            Address = $reply.Address.ToString()
                            Round   = $reply.RoundtripTime
                            Ttl     = $reply.Options.Ttl
                        }
                    }
                }
            } catch { } finally {
                $item.Ping.Dispose()
            }
        }

        if ($OnProgress) { & $OnProgress $index $targets.Count }
    }

    $arp = @{}
    foreach ($entry in (Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue)) {
        if (-not $entry.LinkLayerAddress) { continue }
        # Windows reports these either as "aa-bb-cc-dd-ee-ff" or unseparated, depending on the
        # interface, so the hex digits are re-chunked rather than split on a fixed separator
        $hex = ($entry.LinkLayerAddress -replace "[^0-9A-Fa-f]", "")
        if ($hex.Length -ge 12) {
            $arp[$entry.IPAddress] = (($hex -split "(..)" | Where-Object { $_ }) -join ":")
        }
    }

    return @($alive | ForEach-Object {
        [pscustomobject]@{
            Address = $_.Address
            Round   = $_.Round
            Ttl     = $_.Ttl
            Mac     = if ($arp.ContainsKey($_.Address)) { $arp[$_.Address] } else { "" }
        }
    } | Sort-Object { [int](($_.Address -split '\.')[3]) })
}

function Resolve-WinUtilNetName {

    <#

    .SYNOPSIS
        Forward and reverse lookup results for a name or address

    #>

    param([Parameter(Mandatory)][string]$Target)

    $addresses = @()
    $hostName = $null
    $failure = $null

    if (Test-WinUtilIPv4 -Text $Target) {
        $addresses = @($Target)
        try { $hostName = [System.Net.Dns]::GetHostEntry($Target).HostName } catch { }
    } else {
        try {
            $addresses = @([System.Net.Dns]::GetHostAddresses($Target) | ForEach-Object { $_.IPAddressToString })
        } catch {
            $failure = $_.Exception.Message
        }
    }

    return [pscustomobject]@{
        Target    = $Target
        Addresses = $addresses
        HostName  = $hostName
        Error     = $failure
    }
}

function Measure-WinUtilHttpDownload {

    <#

    .SYNOPSIS
        Downloads a known amount over HTTP and reports the achieved rate

    .DESCRIPTION
        Reads the response stream rather than letting Invoke-WebRequest buffer it, so the timing
        covers the transfer and the sample can be stopped once it is long enough to mean
        something. Only used when the machine really does have a route to the internet.

    #>

    param(
        [Parameter(Mandatory)][string]$Url,
        [int]$MaxMb = 16,
        [int]$TimeoutSec = 25
    )

    # https test servers are TLS 1.2 only, and a Windows PowerShell host left on the framework
    # default will not offer it on an unpatched machine
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12,
            [Net.SecurityProtocolType]::Tls11, [Net.SecurityProtocolType]::Tls
    } catch { }

    $request = [System.Net.HttpWebRequest]::Create($Url)
    $request.Method = "GET"
    $request.Timeout = ($TimeoutSec * 1000)
    $request.ReadWriteTimeout = ($TimeoutSec * 1000)
    $request.UserAgent = "EntOps/NetDiag"

    $response = $request.GetResponse()
    try {
        $stream = $response.GetResponseStream()
        $buffer = New-Object byte[] 65536
        $total = [int64]0
        $limit = [int64]$MaxMb * 1MB
        $watch = [System.Diagnostics.Stopwatch]::StartNew()

        while ($total -lt $limit) {
            $read = $stream.Read($buffer, 0, $buffer.Length)
            if ($read -le 0) { break }
            $total += $read
            if ($watch.Elapsed.TotalSeconds -gt ($TimeoutSec - 2)) { break }
        }

        $watch.Stop()
        return [pscustomobject]@{
            Url      = $Url
            Bytes    = $total
            Seconds  = [Math]::Round($watch.Elapsed.TotalSeconds, 3)
            BytesPerSecond = $total / [Math]::Max(0.001, $watch.Elapsed.TotalSeconds)
            ServerBytes = $response.ContentLength
        }
    } finally {
        $response.Close()
    }
}

function Measure-WinUtilShareThroughput {

    <#

    .SYNOPSIS
        Writes and reads a scratch file across a share to measure real throughput

    .DESCRIPTION
        The only offline-safe bandwidth test there is on a closed network: it measures the path
        the users actually push files over, rather than a public speed test server.

    #>

    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$SizeMb = 32
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "共享路径不可访问：$Path"
    }

    $scratch = Join-Path $Path ("entops-net-probe-{0}.tmp" -f (Get-Date -Format "yyyyMMddHHmmss"))
    $block = New-Object byte[] 1048576
    (New-Object Random).NextBytes($block)
    $blocks = [Math]::Max(1, $SizeMb)

    try {
        $writeWatch = [System.Diagnostics.Stopwatch]::StartNew()
        $stream = [System.IO.File]::Create($scratch, $block.Length)
        try {
            for ($i = 0; $i -lt $blocks; $i++) { $stream.Write($block, 0, $block.Length) }
            $stream.Flush($true)
        } finally {
            $stream.Dispose()
        }
        $writeWatch.Stop()

        $readWatch = [System.Diagnostics.Stopwatch]::StartNew()
        # FileStream rather than File.Open: the buffered overload File.Open only offers on
        # .NET Core, and the buffer is what keeps a 1 GB/s link from being measured as metadata cost
        $stream = New-Object System.IO.FileStream($scratch, [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read, $block.Length)
        try {
            $received = 0
            while (($n = $stream.Read($block, 0, $block.Length)) -gt 0) { $received += $n }
        } finally {
            $stream.Dispose()
        }
        $readWatch.Stop()

        return [pscustomobject]@{
            Bytes        = [int64]$blocks * $block.Length
            WriteSeconds = [Math]::Round($writeWatch.Elapsed.TotalSeconds, 3)
            ReadSeconds  = [Math]::Round($readWatch.Elapsed.TotalSeconds, 3)
            WriteBps     = ([int64]$blocks * $block.Length) / [Math]::Max(0.001, $writeWatch.Elapsed.TotalSeconds)
            ReadBps      = $received / [Math]::Max(0.001, $readWatch.Elapsed.TotalSeconds)
        }
    } finally {
        Remove-Item -LiteralPath $scratch -Force -ErrorAction SilentlyContinue
    }
}

function Test-WinUtilConcurrentSessions {

    <#

    .SYNOPSIS
        Opens many connections at once to see whether the service keeps up

    .DESCRIPTION
        The answer operators actually need when a store reports the till hanging: not whether one
        connection works, but whether twenty do.

    #>

    param(
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][int]$Port,
        [int]$Sessions = 20,
        [int]$TimeoutMs = 2000
    )

    $clients = @()
    $asyncs = @()
    $watch = [System.Diagnostics.Stopwatch]::StartNew()

    for ($i = 0; $i -lt $Sessions; $i++) {
        $client = New-Object System.Net.Sockets.TcpClient
        try {
            $asyncs += $client.BeginConnect($Target, $Port, $null, $null)
            $clients += $client
        } catch {
            $client.Dispose()
        }
    }

    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ((Get-Date) -lt $deadline) {
        if (@($asyncs | Where-Object { -not $_.IsCompleted }).Count -eq 0) { break }
        Start-Sleep -Milliseconds 25
    }

    $succeeded = 0
    for ($i = 0; $i -lt $clients.Count; $i++) {
        # EndConnect is what turns a refused handshake into an exception, so counting without it
        # would report a port that rejects every session as healthy
        try {
            $clients[$i].EndConnect($asyncs[$i])
            if ($clients[$i].Connected) { $succeeded++ }
        } catch { }
    }

    $elapsed = $watch.Elapsed.TotalMilliseconds
    foreach ($client in $clients) { try { $client.Close() } catch { }; $client.Dispose() }

    return [pscustomobject]@{
        Target    = $Target
        Port      = $Port
        Requested = $Sessions
        Succeeded = $succeeded
        Milliseconds = [Math]::Round($elapsed, 0)
    }
}
