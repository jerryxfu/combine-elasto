# combine-elasto

https://github.com/jerryxfu/combine-elasto

Combine 3 video versions (`v1`, `v3`, `v4`) side-by-side into one output video using FFmpeg.

Script: `combine_elasto.py`

## Requirements

- Python 3.8+
    - `winget install Python.Python.3.14` (Windows)
- FFmpeg installed and available in `PATH`
- Fontconfig (optional: for video labels, auto-skips if unavailable)
- Input videos named like:

  `VS_{patient}_{clip}.dat_BmodeSeg_v1.mp4`
  `VS_{patient}_{clip}.dat_BmodeSeg_v3.mp4`
  `VS_{patient}_{clip}.dat_BmodeSeg_v4.mp4`

  Example:

  `VS_55_031.dat_BmodeSeg_v1.mp4`
  `VS_55_031.dat_BmodeSeg_v3.mp4`
  `VS_55_031.dat_BmodeSeg_v4.mp4`

## 1) Install FFmpeg

**macOS (Homebrew)**

```bash
brew install ffmpeg
```

**Windows (winget)**

```powershell
winget install ffmpeg
```

**Ubuntu/Debian**

```bash
sudo apt update
sudo apt install -y ffmpeg
```

## 2) Run the script

From the project folder:

```bash
python combine_elasto.py --patient 55
```

Optional arguments:

- `-i`, `--input-dir`: folder with input videos (default: current folder)
- `-o`, `--output-dir`: output folder (default: `./combined`)
- `-c`, `--clips`: clips to process, MATLAB-style (see below); omit to process all
- `-h`, `--help`: show help

### Selecting clips

The `--clips` argument uses MATLAB-style ranges: space-separated tokens, each a single number or a `START:END` range (inclusive). Wrap the whole thing in
quotes:

```bash
python combine_elasto.py --patient 55 --clips "2 3:6 9:14 15"
```

That processes clips 2, 3, 4, 5, 6, 9 through 14, and 15. Leading zeros are optional (`5` matches `005`).

Examples:

```bash
python combine_elasto.py --patient 55
python combine_elasto.py --patient 55 --clips 31
python combine_elasto.py --patient 55 --clips "2 3:6 9:14 15"
python combine_elasto.py --patient 55 --input-dir ./videos --output-dir ./combined
python combine_elasto.py --help
```

## Configuration

Crop margins, label style, version list, and encoding quality (CRF) are constants
at the top of `combine_elasto.py`. Edit them there if you need to adjust:

```python
CROP = {"top": 50, "bottom": 76, "left": 110, "right": 110}
VERSIONS = ("v1", "v3", "v4")
CRF = 18
```

## Output

Combined videos are written to the output folder as:

`VS_{patient}_{clip}_combined.mp4`

**Note on labels:** The script adds text labels (v1, v3, v4) to each panel if
fontconfig is available. If not, it automatically retries without labels.

## Troubleshooting

- **`ffmpeg not found`** - Install FFmpeg and ensure it's on your `PATH`.
- **`No matching files found`** - Check patient ID and file naming pattern.
- **Clip skipped / missing files** - For each clip, all 3 files (`v1`, `v3`, `v4`) must exist.
- **Videos created without labels** - Install fontconfig for labels:
    - macOS: `brew install fontconfig`
    - Linux: `sudo apt install fontconfig`
