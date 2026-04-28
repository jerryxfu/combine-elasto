# combine-elasto

Combine 3 video versions (`v1`, `v3`, `v4`) side-by-side into one output video using FFmpeg.

Script: `combine_elasto.ps1`

## Requirements

- PowerShell 7+ (`pwsh`) recommended
- FFmpeg installed and available in `PATH`
- Fontconfig (optional - for video labels, will auto-skip if unavailable)
- Input videos named like:

`VS_{patient}_{clip}.dat_BmodeSeg_v1.mp4`  
`VS_{patient}_{clip}.dat_BmodeSeg_v3.mp4`  
`VS_{patient}_{clip}.dat_BmodeSeg_v4.mp4`

Example:

`VS_55_031.dat_BmodeSeg_v1.mp4`  
`VS_55_031.dat_BmodeSeg_v3.mp4`  
`VS_55_031.dat_BmodeSeg_v4.mp4`

## 1) Install FFmpeg

### macOS (Homebrew)

```bash
brew install ffmpeg
ffmpeg -version
```

### Windows (winget)

```powershell
winget install ffmpeg
ffmpeg -version
```

### Ubuntu/Debian

```bash
sudo apt update
sudo apt install -y ffmpeg
ffmpeg -version
```

## 2) Run the script

From the project folder:

```bash
pwsh ./combine_elasto.ps1 -Patient 55
```

Optional arguments:

- `-InputDir` folder with input videos (default: current folder)
- `-OutputDir` output folder (default: `./combined`)
- `-Clip` process one clip only (e.g. `31` or `031`)
- `-Crf` quality (0 best, 51 worst, default `18`)
- `-Help` show script help

Examples:

```bash
pwsh ./combine_elasto.ps1 -Patient 55
pwsh ./combine_elasto.ps1 -Patient 55 -InputDir ./videos -OutputDir ./combined
pwsh ./combine_elasto.ps1 -Patient 55 -Clip 31
pwsh ./combine_elasto.ps1 -Help
```

## Output

Combined videos are written to the output folder as:

`VS_{patient}_{clip}_combined.mp4`

**Note on Labels:** The script will automatically add text labels (v1, v3, v4) to each video section if fontconfig is available. If fontconfig is not installed,
the script will automatically retry without labels, so the video will still be created successfully—just without the text overlays.

## Troubleshooting

- **`ffmpeg not found`**  
  Install FFmpeg and ensure `ffmpeg` is on your `PATH`.

- **`No matching files found`**  
  Check patient ID and file naming pattern exactly.

- **Clip skipped / missing files**  
  For each clip, all 3 files (`v1`, `v3`, `v4`) must exist.

- **Videos created without labels**  
  The script automatically skips text labels if fontconfig is unavailable. If you want labels, install fontconfig:
    - macOS: `brew install fontconfig`
    - Linux: `sudo apt install fontconfig`

