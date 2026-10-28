function Expand-WinUtilEmbeddedPayload {
    <#

    .SYNOPSIS
        Unpacks the archive that Build-Exe.ps1 appends after the executable's own bytes, so a
        single .exe carries the offline material with it. Nothing happens when the script runs
        from a .ps1, where those folders already sit beside it.

    .OUTPUTS
        The folder holding drivers\ and tools\, or $null when there is no payload to unpack.

    #>

    param(
        [scriptblock]$StatusCallback
    )

    $exePath = try { [Environment]::GetCommandLineArgs()[0] } catch { $null }
    if (-not $exePath -or $exePath -notmatch '\.exe$' -or -not (Test-Path -LiteralPath $exePath)) {
        return $null
    }

    $payloadDir = Join-Path $sync.winutildir "payload"
    $stampFile = Join-Path $payloadDir "payload.stamp"
    $magic = "ENTOPS01"

    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem

        $stream = [System.IO.File]::Open($exePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            if ($stream.Length -lt 16) { return $null }

            $tail = New-Object byte[] 16
            $null = $stream.Seek(-16, [System.IO.SeekOrigin]::End)
            $null = $stream.Read($tail, 0, 16)
            if ([Text.Encoding]::ASCII.GetString($tail, 0, 8) -ne $magic) {
                Write-WinUtilLog "No embedded payload trailer found in $exePath" -Level DEBUG -Component Packaging
                return $null
            }

            $payloadLength = [BitConverter]::ToInt64($tail, 8)
            if ($payloadLength -le 0 -or $payloadLength -gt ($stream.Length - 16)) { return $null }

            # A rebuild changes the length, so the stamp is all the comparison the cache needs
            $alreadyUnpacked = (Test-Path -LiteralPath $stampFile) -and
                ((Get-Content -LiteralPath $stampFile -Raw).Trim() -eq "$payloadLength") -and
                (Test-Path -LiteralPath (Join-Path $payloadDir "drivers\driver.zip"))
            if ($alreadyUnpacked) {
                return $payloadDir
            }

            if ($StatusCallback) { & $StatusCallback "正在解包内置的驱动与工具..." }

            $null = $stream.Seek((-16 - $payloadLength), [System.IO.SeekOrigin]::End)
            $archivePath = Join-Path $env:TEMP "entops-payload-$PID.zip"
            $archive = [System.IO.File]::Create($archivePath)
            try {
                $stream.CopyTo($archive, 1048576)
            } finally {
                $archive.Dispose()
            }

            # .NET Framework's ExtractToDirectory cannot overwrite, so the cache is replaced whole
            if (Test-Path -LiteralPath $payloadDir) {
                Remove-Item -LiteralPath $payloadDir -Recurse -Force -ErrorAction SilentlyContinue
            }
            New-Item -ItemType Directory -Path $payloadDir -Force | Out-Null
            [System.IO.Compression.ZipFile]::ExtractToDirectory($archivePath, $payloadDir)
            Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue

            if (-not (Test-Path -LiteralPath (Join-Path $payloadDir "drivers\driver.zip"))) {
                Write-WinUtilLog "Embedded payload unpacked without the driver archive" -Level WARN -Component Packaging
                return $null
            }

            Set-Content -LiteralPath $stampFile -Value "$payloadLength" -Encoding ASCII -NoNewline
            Write-WinUtilLog "Embedded payload unpacked to $payloadDir" -Component Packaging
            return $payloadDir
        } finally {
            $stream.Dispose()
        }
    } catch {
        Write-WinUtilLog "Unable to unpack the embedded payload: $($_.Exception.Message)" -Level WARN -Component Packaging
        return $null
    }
}
