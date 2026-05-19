# Procedurally builds Hub.ico in the script's directory — multi-resolution
# 16/32/48/64/128/256 with 2x2 grid of Iris squares on Base background.
#
# Run once when the icon design changes; the .ico is checked in and consumed by
# both Hub.ps1 (tray) and Phase 6 PS2EXE compile.

[CmdletBinding()]
param(
    [string]$OutputPath = (Join-Path $PSScriptRoot 'Hub.ico')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Drawing

function New-HubBitmap {
    [OutputType([System.Drawing.Bitmap])]
    param([int]$Size)

    $bmp = New-Object System.Drawing.Bitmap $Size, $Size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.SmoothingMode    = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        # Rosé Pine Moon Base
        $g.Clear([System.Drawing.Color]::FromArgb(35, 33, 54))

        # Iris squares
        $iris = [System.Drawing.Color]::FromArgb(196, 167, 231)
        $brush = New-Object System.Drawing.SolidBrush $iris
        try {
            $pad = [Math]::Max(1, [int][Math]::Round($Size * 0.12))
            $gap = [Math]::Max(1, [int][Math]::Round($Size * 0.08))
            $sq  = [int][Math]::Round(($Size - $pad * 2 - $gap) / 2.0)
            $x0 = $pad
            $y0 = $pad
            $g.FillRectangle($brush, $x0,            $y0,           $sq, $sq)
            $g.FillRectangle($brush, $x0 + $sq + $gap, $y0,           $sq, $sq)
            $g.FillRectangle($brush, $x0,            $y0 + $sq + $gap, $sq, $sq)
            $g.FillRectangle($brush, $x0 + $sq + $gap, $y0 + $sq + $gap, $sq, $sq)
        } finally { $brush.Dispose() }
    } finally { $g.Dispose() }

    return $bmp
}

function Save-IcoFromBitmaps {
    param(
        [string]$Path,
        [System.Drawing.Bitmap[]]$Bitmaps
    )
    $pngs = New-Object 'System.Collections.Generic.List[byte[]]'
    foreach ($b in $Bitmaps) {
        $ms = New-Object System.IO.MemoryStream
        try {
            $b.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
            [void]$pngs.Add($ms.ToArray())
        } finally { $ms.Dispose() }
    }

    $count = $Bitmaps.Count
    $headerSize = 6 + 16 * $count

    $out = New-Object System.IO.MemoryStream
    $bw  = New-Object System.IO.BinaryWriter $out
    try {
        # ICONDIR (6 bytes)
        $bw.Write([uint16]0)        # Reserved
        $bw.Write([uint16]1)        # Type=1 (ICO)
        $bw.Write([uint16]$count)   # Number of images

        # ICONDIRENTRY × count (16 bytes each)
        $offset = $headerSize
        for ($i = 0; $i -lt $count; $i++) {
            $size = $Bitmaps[$i].Width
            $w = if ($size -ge 256) { [byte]0 } else { [byte]$size }
            $h = if ($size -ge 256) { [byte]0 } else { [byte]$size }
            $bw.Write([byte]$w)
            $bw.Write([byte]$h)
            $bw.Write([byte]0)         # ColorCount (0 for >= 256 colours)
            $bw.Write([byte]0)         # Reserved
            $bw.Write([uint16]1)       # Planes
            $bw.Write([uint16]32)      # BitCount
            $bw.Write([uint32]$pngs[$i].Length)
            $bw.Write([uint32]$offset)
            $offset += $pngs[$i].Length
        }

        foreach ($png in $pngs) { $bw.Write($png) }
        $bw.Flush()
        [System.IO.File]::WriteAllBytes($Path, $out.ToArray())
    } finally {
        $bw.Dispose()
        $out.Dispose()
    }
}

$sizes = @(16, 32, 48, 64, 128, 256)
$bitmaps = New-Object 'System.Collections.Generic.List[System.Drawing.Bitmap]'
try {
    foreach ($s in $sizes) {
        [void]$bitmaps.Add( (New-HubBitmap -Size $s) )
    }
    Save-IcoFromBitmaps -Path $OutputPath -Bitmaps $bitmaps.ToArray()
    "Wrote $OutputPath ($((Get-Item $OutputPath).Length) bytes, $($sizes.Count) sizes)"
} finally {
    foreach ($b in $bitmaps) { try { $b.Dispose() } catch { } }
}
