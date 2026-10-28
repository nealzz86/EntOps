#Requires -Version 5.1

<#

.SYNOPSIS
    Renders the in-app vector logo into the executable's .ico file.

.DESCRIPTION
    The sidebar logo is drawn from geometry in Invoke-WinUtilAssets, so the icon is produced by
    rendering that same geometry with WPF rather than maintaining a second copy of the artwork.
    Keeps the mark on a rounded tile so it stays legible against a light desktop.

#>

param(
    [int]$MasterSize = 1024,
    [int[]]$IconSizes = @(256, 128, 64, 48, 32, 24, 16)
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Drawing

$assets = Join-Path $PSScriptRoot "assets"
$pngPath = Join-Path $assets "entops-icon.png"
$icoPath = Join-Path $assets "entops-icon.ico"

# The three logo paths and their fills, kept in step with the 'logo' branch of Invoke-WinUtilAssets
$source = Get-Content -LiteralPath (Join-Path $PSScriptRoot "functions\private\Invoke-WinUtilAssets.ps1") -Raw
function Get-LogoPathData {
    param([string]$Source, [string]$VariableName)
    $marker = ('${0} = @' + [char]34) -f $VariableName
    $start = $Source.IndexOf($marker)
    if ($start -lt 0) { throw "Logo geometry variable $VariableName is missing." }
    $from = $Source.IndexOf([char]10, $start + $marker.Length) + 1
    $end = $Source.IndexOf(([char]34 + '@'), $from)
    return $Source.Substring($from, $end - $from)
}

function Get-LogoPathFill {
    param([string]$Source, [string]$VariableName)
    $pattern = [regex]::Escape($VariableName) + '\.Fill\s*=.*ConvertFromString\("([^"]+)"\)'
    $match = [regex]::Match($Source, $pattern)
    if (-not $match.Success) { throw "Logo fill for $VariableName is missing." }
    return $match.Groups[1].Value
}

$paths = @(
    @{ Geometry = [Windows.Media.Geometry]::Parse((Get-LogoPathData -Source $source -VariableName "LogoPathData1")); Fill = (Get-LogoPathFill -Source $source -VariableName "LogoPath1") },
    @{ Geometry = [Windows.Media.Geometry]::Parse((Get-LogoPathData -Source $source -VariableName "LogoPathData2")); Fill = (Get-LogoPathFill -Source $source -VariableName "LogoPath2") },
    @{ Geometry = [Windows.Media.Geometry]::Parse((Get-LogoPathData -Source $source -VariableName "LogoPathData3")); Fill = (Get-LogoPathFill -Source $source -VariableName "LogoPath3") }
)

$bounds = [Windows.Rect]::Empty
foreach ($path in $paths) {
    $bounds = [Windows.Rect]::Union($bounds, $path.Geometry.Bounds)
}

$brushConverter = New-Object System.Windows.Media.BrushConverter

function New-LogoBitmap {
    param([int]$Size)

    $visual = New-Object System.Windows.Media.DrawingVisual
    $dc = $visual.RenderOpen()

    # Rounded tile in the console's sidebar navy, so the mark reads on any desktop theme
    $tileRect = New-Object System.Windows.Rect (0, 0, $Size, $Size)
    $tileBrush = New-Object System.Windows.Media.LinearGradientBrush(
        [System.Windows.Media.Color]::FromRgb(0x22, 0x3B, 0x60),
        [System.Windows.Media.Color]::FromRgb(0x15, 0x25, 0x3C),
        [System.Windows.Point]::new(0, 0), [System.Windows.Point]::new(0, $Size))
    $dc.DrawRoundedRectangle($tileBrush, $null, $tileRect, ($Size * 0.22), ($Size * 0.22))

    # Center the mark and leave a margin wide enough that it survives the rounded corners
    $target = $Size * 0.66
    $scale = [Math]::Min($target / $bounds.Width, $target / $bounds.Height)
    $offsetX = ($Size - $bounds.Width * $scale) / 2 - $bounds.X * $scale
    $offsetY = ($Size - $bounds.Height * $scale) / 2 - $bounds.Y * $scale

    $transform = New-Object Windows.Media.TransformGroup
    $transform.Children.Add((New-Object Windows.Media.ScaleTransform($scale, $scale))) | Out-Null
    $transform.Children.Add((New-Object Windows.Media.TranslateTransform($offsetX, $offsetY))) | Out-Null

    foreach ($path in $paths) {
        $filled = $path.Geometry.Clone()
        $filled.Transform = $transform
        $filled.Freeze()
        $dc.DrawGeometry($brushConverter.ConvertFromString($path.Fill), $null, $filled)
    }

    $dc.Close()

    $render = New-Object Windows.Media.Imaging.RenderTargetBitmap ($Size, $Size, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
    $render.Render($visual)
    $render.Freeze()
    return $render
}

function Save-PngBytes {
    param([Windows.Media.Imaging.BitmapSource]$Image)
    $encoder = New-Object Windows.Media.Imaging.PngBitmapEncoder
    $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($Image))
    $stream = New-Object System.IO.MemoryStream
    $encoder.Save($stream)
    $bytes = $stream.ToArray()
    $stream.Dispose()
    return $bytes
}

[System.IO.File]::WriteAllBytes($pngPath, (Save-PngBytes -Image (New-LogoBitmap -Size $MasterSize)))

# The icon frames are downscales of the master render, done with GDI+ because it writes the
# 32-bit PNG entries an .ico needs
$master = New-Object System.Drawing.Bitmap $pngPath
$entries = foreach ($size in $IconSizes) {
    $frame = New-Object System.Drawing.Bitmap ($size, $size)
    $graphics = [System.Drawing.Graphics]::FromImage($frame)
    $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $graphics.DrawImage($master, (New-Object System.Drawing.Rectangle (0, 0, $size, $size)))
    $graphics.Dispose()
    $frameMs = New-Object System.IO.MemoryStream
    $frame.Save($frameMs, [System.Drawing.Imaging.ImageFormat]::Png)
    $frame.Dispose()
    $frameBytes = $frameMs.ToArray()
    $frameMs.Dispose()
    @{ Size = $size; Data = $frameBytes }
}
$master.Dispose()

$writer = New-Object System.IO.BinaryWriter ([System.IO.File]::Create($icoPath))
try {
    $writer.Write([uint16]0)
    $writer.Write([uint16]1)
    $writer.Write([uint16]$entries.Count)
    $offset = 6 + (16 * $entries.Count)
    foreach ($entry in $entries) {
        $dim = if ($entry.Size -ge 256) { 0 } else { $entry.Size }
        $writer.Write([byte]$dim)
        $writer.Write([byte]$dim)
        $writer.Write([byte]0)
        $writer.Write([byte]0)
        $writer.Write([uint16]1)
        $writer.Write([uint16]32)
        $writer.Write([uint32]$entry.Data.Length)
        $writer.Write([uint32]$offset)
        $offset += $entry.Data.Length
    }
    foreach ($entry in $entries) { $writer.Write($entry.Data) }
} finally {
    $writer.Close()
}

Write-Output ("图标已生成：{0}（{1:N0} 字节，含 {2} 个尺寸）" -f $icoPath, (Get-Item -LiteralPath $icoPath).Length, $entries.Count)
