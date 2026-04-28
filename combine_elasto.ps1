<#
.SYNOPSIS
    Combines 3 video versions (v1, v3, v4) side-by-side for a given patient.

.DESCRIPTION
    Finds all video triplets matching the pattern:
        VS_{patient}_{clip}.dat_BmodeSeg_v1.mp4
        VS_{patient}_{clip}.dat_BmodeSeg_v3.mp4
        VS_{patient}_{clip}.dat_BmodeSeg_v4.mp4

    Then stacks them horizontally into a single output video using FFmpeg.

.PARAMETER Patient
    Patient number to process. Required.

.PARAMETER InputDir
    Folder containing the input videos. Defaults to current folder.

.PARAMETER OutputDir
    Folder to save combined videos. Defaults to .\combined

.PARAMETER Clip
    Only process a specific clip number (e.g. 31 or 031).

.PARAMETER Crf
    FFmpeg quality. 0 = best, 51 = worst. Default is 18.

.PARAMETER Help
    Show this help menu.

.EXAMPLE
    .\combine_videos.ps1 -Patient 55
    .\combine_videos.ps1 -Patient 55 -InputDir C:\videos -OutputDir C:\output
    .\combine_videos.ps1 -Patient 55 -Clip 31
    .\combine_videos.ps1 -Help
#>

param(
    [Parameter(Mandatory = $false)] [int] $Patient = 0,
    [string] $InputDir = ".",
    [string] $OutputDir = ".\combined",
    [int]    $Clip = -1,
    [int]    $Crf = 18,
    [switch] $Help
)

# Show full help and exit if -Help was passed
if ($Help)
{
    Get-Help $PSCommandPath -Detailed
    exit 0
}

# Patient is required if not asking for help
if ($Patient -eq 0)
{
    Write-Error "Patient number is required. Use -Patient 55, or run .\combine_videos.ps1 -Help"
    exit 1
}


# CROP SETTINGS (pixels to remove per side)
$CropTop = 50
$CropBottom = 76
$CropLeft = 110
$CropRight = 110

# VALIDATION
# Check FFmpeg is installed
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue))
{
    Write-Error "ffmpeg not found. Install from https://ffmpeg.org or run: winget install ffmpeg"
    exit 1
}

# Check if input folder exists
if (-not (Test-Path $InputDir))
{
    Write-Error "Input directory not found: $InputDir"
    exit 1
}

# Create output folder if it doesn't exist
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null


# INFO
Write-Host ""
Write-Host "Patient:    $Patient"
Write-Host "Input dir:  $InputDir"
Write-Host "Output dir: $OutputDir"
if ($Clip -ge 0)
{
    Write-Host "Clip:       $($Clip.ToString().PadLeft(3, '0') )"
}
Write-Host ""


# MAIN LOOP
$SuccessCount = 0
$FailCount = 0
$TotalCount = 0
$Found = $false

# Find all v1 files for this patient
$v1Files = Get-ChildItem -Path $InputDir -Filter "VS_${Patient}_*.dat_BmodeSeg_v1.mp4"

if (-not $v1Files)
{
    Write-Host "No matching files found in $InputDir"
    Write-Host "Expected files like: VS_${Patient}_031.dat_BmodeSeg_v1.mp4"
    exit 1
}

foreach ($v1File in $v1Files)
{
    # Extract clip number from filename (VS_55_031.dat_BmodeSeg_v1.mp4)
    if ($v1File.BaseName -match "VS_${Patient}_(.+?)\.dat")
    {
        $clipNum = $Matches[1]
    }
    else
    {
        continue
    }

    # Pad clip number to 3 digits
    $clipNum = $clipNum.PadLeft(3, '0')

    # Skip if clip filter does not match this clip
    if ($Clip -ge 0 -and $clipNum -ne $Clip.ToString().PadLeft(3, '0'))
    {
        continue
    }

    $Found = $true
    $TotalCount++

    # Build the 3 input paths
    $v1 = Join-Path $InputDir "VS_${Patient}_${clipNum}.dat_BmodeSeg_v1.mp4"
    $v3 = Join-Path $InputDir "VS_${Patient}_${clipNum}.dat_BmodeSeg_v3.mp4"
    $v4 = Join-Path $InputDir "VS_${Patient}_${clipNum}.dat_BmodeSeg_v4.mp4"

    # Check all 3 exist
    $missing = @($v1, $v3, $v4) | Where-Object { -not (Test-Path $_) }
    if ($missing)
    {
        $missing | ForEach-Object { Write-Host "MISSING: $_" }
        Write-Host "Skipping clip $clipNum -- not all 3 versions found."
        Write-Host ""
        $FailCount++
        continue
    }

    # Output path
    $out = Join-Path $OutputDir "VS_${Patient}_${clipNum}_combined.mp4"

    Write-Host "Combining clip $clipNum"
    Write-Host "  v1 -> $v1"
    Write-Host "  v3 -> $v3"
    Write-Host "  v4 -> $v4"
    Write-Host "  out -> $out"

    # Build the FFmpeg filter
    # 1. Crop each video, remove borders
    # 2. hstack, place videos side by side
    # 3. drawtext labels (optional - will be skipped if fontconfig unavailable)
    $crop = "crop=iw-${CropLeft}-${CropRight}:ih-${CropTop}-${CropBottom}:${CropLeft}:${CropTop}"

    # Filter with labels
    $filterWithLabels = "[0:v]${crop}[a];[1:v]${crop}[b];[2:v]${crop}[c];" +
            "[a][b][c]hstack=inputs=3[h];" +
            "[h]drawtext=text='v1':fontsize=24:fontcolor=white:borderw=2:x=10:y=10," +
            "drawtext=text='v3':fontsize=24:fontcolor=white:borderw=2:x=w/3+10:y=10," +
            "drawtext=text='v4':fontsize=24:fontcolor=white:borderw=2:x=2*w/3+10:y=10[out]"

    # Filter without labels (fallback)
    $filterNoLabels = "[0:v]${crop}[a];[1:v]${crop}[b];[2:v]${crop}[c];[a][b][c]hstack=inputs=3[out]"

    # Try with labels first
    $labelsAttempted = $false
    $ffmpegArgs = @(
        "-y",
        "-i", $v1,
        "-i", $v3,
        "-i", $v4,
        "-filter_complex", $filterWithLabels,
        "-map", "[out]",
        "-c:v", "libx264",
        "-crf", $Crf,
        "-preset", "medium",
        "-pix_fmt", "yuv420p",
        $out,
        "-loglevel", "warning"
    )

    & ffmpeg @ffmpegArgs 2>&1 | Out-Null
    $ffmpegSuccess = $LASTEXITCODE -eq 0

    # If labels failed (e.g., fontconfig error), retry without labels
    if (-not $ffmpegSuccess -and (Test-Path $out))
    {
        Remove-Item $out -Force
    }

    if (-not $ffmpegSuccess)
    {
        Write-Host "  (Labels skipped - fontconfig unavailable, retrying without labels...)"
        $labelsAttempted = $true

        $ffmpegArgs = @(
            "-y",
            "-i", $v1,
            "-i", $v3,
            "-i", $v4,
            "-filter_complex", $filterNoLabels,
            "-map", "[out]",
            "-c:v", "libx264",
            "-crf", $Crf,
            "-preset", "medium",
            "-pix_fmt", "yuv420p",
            $out,
            "-loglevel", "warning"
        )

        & ffmpeg @ffmpegArgs 2>&1 | Out-Null
        $ffmpegSuccess = $LASTEXITCODE -eq 0
    }

    # Check output was created and is non-empty
    if (-not (Test-Path $out) -or (Get-Item $out).Length -eq 0)
    {
        Write-Host "FAILED: FFmpeg error for clip $clipNum"
        if (Test-Path $out)
        {
            Remove-Item $out
        }
        $FailCount++
    }
    else
    {
        $size = (Get-Item $out).Length
        $labelStatus = if ($labelsAttempted)
        {
            " (without labels)"
        }
        else
        {
            " (with labels)"
        }
        Write-Host "OK: $out ($size bytes)$labelStatus"
        $SuccessCount++
    }

    Write-Host ""
}

# SUMMARY
Write-Host "Done: $SuccessCount combined, $FailCount failed, $TotalCount total."