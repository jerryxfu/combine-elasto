<#
.SYNOPSIS
    Combines v1, v3, and v4 segmentation videos side-by-side.

.DESCRIPTION
    Finds video triplets matching the pattern:
        VS_{patient}_{clip}.dat_BmodeSeg_{v1,v3,v4}.mp4
    and stacks them horizontally into a single output video using FFmpeg.

    Works on Windows, macOS, and Linux (requires PowerShell 7+ and FFmpeg).

.PARAMETER Patient
    Patient number to process (required).

.PARAMETER InputDir
    Folder containing the input videos. Defaults to current directory.

.PARAMETER OutputDir
    Folder to save combined videos. Defaults to ./combined

.PARAMETER Clip
    Only process a specific clip number (e.g. 1, 31, 108).

.EXAMPLE
    ./combine.ps1 -Patient 55
    ./combine.ps1 -Patient 55 -Clip 31
    ./combine.ps1 -Patient 79 -InputDir C:\data -OutputDir C:\output
#>

param(
    [Parameter(Mandatory)] [int] $Patient,
    [string] $InputDir = ".",
    [string] $OutputDir = "./combined",
    [int]    $Clip = -1
)

# Configuration

# Crop margins: pixels to remove from each edge of every input video.
$Crop = @{ Top = 50; Bottom = 76; Left = 110; Right = 110 }

# Label style
$Label = @{ FontSize = 24; Color = "white"; BorderWidth = 2; YOffset = 10; XOffset = 10 }

# Versions to combine (left to right)
$Versions = @("v1", "v3", "v4")

# Encoding quality (0 = lossless, 51 = worst, 18 = visually lossless)
$Crf = 18

# Logging

function Write-Info($msg) {
    Write-Host "  $msg"
}
function Write-Ok($msg) {
    Write-Host "  OK    $msg" -ForegroundColor Green
}
function Write-Warn($msg) {
    Write-Host "  WARN  $msg" -ForegroundColor Yellow
}
function Write-Err($msg) {
    Write-Host "  ERROR $msg" -ForegroundColor Red
}

function Format-Bytes([long] $bytes) {
    if ($bytes -ge 1MB) {
        return "{0:N1} MB" -f ($bytes / 1MB)
    }
    elseif ($bytes -ge 1KB) {
        return "{0:N1} KB" -f ($bytes / 1KB)
    }
    else {
        return "$bytes B"
    }
}

function Build-CropFilter {
    $w = "iw-$( $Crop.Left )-$( $Crop.Right )"
    $h = "ih-$( $Crop.Top )-$( $Crop.Bottom )"
    return "crop=${w}:${h}:$( $Crop.Left ):$( $Crop.Top )"
}

function Build-LabelFilter([string[]] $versions, [int] $panelCount) {
    # Build chained drawtext filters for each panel
    $parts = @()
    for ($i = 0; $i -lt $panelCount; $i++) {
        $xExpr = if ($i -eq 0) {
            "$( $Label.XOffset )"
        }
        else {
            "$i*w/$panelCount+$( $Label.XOffset )"
        }
        $parts += "drawtext=text='$( $versions[$i] )':fontsize=$( $Label.FontSize ):fontcolor=$( $Label.Color ):borderw=$( $Label.BorderWidth ):x=$xExpr`:y=$( $Label.YOffset )"
    }
    return $parts -join ","
}

function Build-FilterGraph([switch] $WithLabels) {
    $crop = Build-CropFilter
    $n = $Versions.Count

    # Crop each input
    $cropStage = @()
    $cropLabels = @()
    for ($i = 0; $i -lt $n; $i++) {
        $tag = [char]([int][char]'a' + $i)
        $cropStage += "[$i`:v]${crop}[$tag]"
        $cropLabels += "[$tag]"
    }

    # hstack
    $stackInput = $cropLabels -join ""
    $filter = ($cropStage -join ";") + ";${stackInput}hstack=inputs=${n}"

    if ($WithLabels) {
        $filter += "[h];[h]" + (Build-LabelFilter $Versions $n) + "[out]"
    }
    else {
        $filter += "[out]"
    }

    return $filter
}

function Invoke-FFmpeg([string[]] $inputs, [string] $filter, [string] $output, [int] $crf) {
    $args = @("-y", "-hide_banner")

    foreach ($f in $inputs) {
        $args += @("-i", $f)
    }

    $args += @(
        "-filter_complex", $filter,
        "-map", "[out]",
        "-c:v", "libx264",
        "-crf", $crf,
        "-preset", "medium",
        "-pix_fmt", "yuv420p",
        "-an",
        $output
    )

    # Run FFmpeg, capture stderr for error reporting
    $proc = Start-Process -FilePath "ffmpeg" -ArgumentList $args `
        -NoNewWindow -Wait -PassThru `
        -RedirectStandardError (Join-Path ([System.IO.Path]::GetTempPath()) "ffmpeg_err.txt")

    return $proc.ExitCode -eq 0
}

function Test-OutputValid([string] $path) {
    return (Test-Path $path) -and ((Get-Item $path).Length -gt 0)
}

# Validation

if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
    Write-Err "ffmpeg not found in PATH."
    Write-Host ""
    Write-Host "  Install with:"
    Write-Host "    Windows:  winget install ffmpeg"
    Write-Host "    macOS:    brew install ffmpeg"
    Write-Host "    Linux:    sudo apt install ffmpeg"
    exit 1
}

if (-not (Test-Path $InputDir)) {
    Write-Err "Input directory not found: $InputDir"
    exit 1
}

$InputDir = Resolve-Path $InputDir
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$OutputDir = Resolve-Path $OutputDir

# Header

Write-Host ""
Write-Host "  Video Combiner" -ForegroundColor Cyan
Write-Host "  Patient:    $Patient"
Write-Host "  Versions:   $( $Versions -join ', ' )"
Write-Host "  Input:      $InputDir"
Write-Host "  Output:     $OutputDir"
if ($Clip -ge 0) {
    Write-Host "  Clip:       $($Clip.ToString().PadLeft(3, '0') )"
}
Write-Host ""

# Discovery

# Find all v1 files for this patient
$v1Files = Get-ChildItem -Path $InputDir -Filter "VS_${Patient}_*.dat_BmodeSeg_v1.mp4"

if (-not $v1Files) {
    Write-Err "No v1 files found for patient $Patient in $InputDir"
    Write-Info "Expected: VS_${Patient}_001.dat_BmodeSeg_v1.mp4"
    exit 1
}

# Processing

$success = 0
$failed = 0
$skipped = 0

foreach ($v1File in $v1Files | Sort-Object Name) {

    # Extract clip number from filename
    if ($v1File.BaseName -notmatch "VS_${Patient}_(.+?)\.dat") {
        continue
    }
    $clipNum = $Matches[1].PadLeft(3, '0')

    # Apply clip filter (compare as integers to ignore padding differences)
    if ($Clip -ge 0 -and [int]$clipNum -ne $Clip) {
        continue
    }

    # Build input paths for all versions
    $inputs = $Versions | ForEach-Object {
        Join-Path $InputDir "VS_${Patient}_${clipNum}.dat_BmodeSeg_${_}.mp4"
    }

    # Check all versions exist
    $missing = $inputs | Where-Object { -not (Test-Path $_) }
    if ($missing) {
        Write-Warn "Clip $clipNum -- missing versions:"
        $missing | ForEach-Object { Write-Warn "  $_" }
        $skipped++
        continue
    }

    $outPath = Join-Path $OutputDir "VS_${Patient}_${clipNum}_combined.mp4"
    Write-Info "Clip $clipNum ..."

    # Try with labels first, fall back to without if it fails
    $useLabels = $true
    $ok = $false

    $filter = Build-FilterGraph -WithLabels
    $ok = Invoke-FFmpeg $inputs $filter $outPath $Crf

    if (-not (Test-OutputValid $outPath)) {
        Write-Warn "Labels failed (fontconfig issue?), retrying without ..."
        $useLabels = $false
        $filter = Build-FilterGraph
        Invoke-FFmpeg $inputs $filter $outPath $Crf | Out-Null
    }

    # Verify output
    if (Test-OutputValid $outPath) {
        $size = Format-Bytes (Get-Item $outPath).Length
        $labelTag = if ($useLabels) {
            ""
        }
        else {
            " (no labels)"
        }
        Write-Ok "$outPath ($size)$labelTag"
        $success++
    }
    else {
        Write-Err "Failed for clip $clipNum"
        if (Test-Path $outPath) {
            Remove-Item $outPath -Force
        }
        $failed++
    }
}

# Summary

$total = $success + $failed + $skipped
Write-Host ""
Write-Host "  Done: $success combined, $failed failed, $skipped skipped ($total total)" -ForegroundColor $(
if ($failed -gt 0) {
    "Yellow"
}
else {
    "Green"
}
)
Write-Host ""