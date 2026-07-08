#!/usr/bin/env python3
"""
combine_elasto.py

Combine v1, v3, and v4 segmentation videos side-by-side into one output video.

Finds video triplets matching the pattern:
    VS_{patient}_{clip}.dat_BmodeSeg_{v1,v3,v4}.mp4
crops each, stacks them horizontally, adds version labels, and encodes the result with FFmpeg.

Works on Windows, macOS, and Linux. Requires Python 3.8+ and FFmpeg on PATH.

Usage:
    python combine_elasto.py --patient 55
    python combine_elasto.py --patient 55 --clips 31
    python combine_elasto.py --patient 79 --input-dir ./videos --output-dir ./out
"""

from __future__ import annotations

import argparse
import platform
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

# --- Configuration ---

# Crop margins: pixels to remove from each edge of every input video.
CROP = {"top": 50, "bottom": 76, "left": 110, "right": 110}

# Label style for the v1/v3/v4 text overlays.
LABEL = {"font_size": 24, "color": "white", "border_width": 2, "x_offset": 10, "y_offset": 10}

# Versions to combine, left to right.
VERSIONS = ("v1", "v3", "v4")

# Encoding quality: 0 = lossless, 51 = worst, 18 = visually lossless.
CRF = 18

# Preset trades encode speed for compression efficiency.
PRESET = "medium"

# Candidate font files per platform, tried in order. The first one that exists
# is passed explicitly to drawtext, which avoids relying on fontconfig (often
# broken on winget/Homebrew FFmpeg builds). Add your own path at the top of the
# relevant list if none of these exist on your machine.
FONT_CANDIDATES = {
    "Windows": [
        r"C:\Windows\Fonts\arial.ttf",
        r"C:\Windows\Fonts\segoeui.ttf",
        r"C:\Windows\Fonts\calibri.ttf",
    ],
    "Darwin": [
        "/System/Library/Fonts/Helvetica.ttc",
        "/System/Library/Fonts/Supplemental/Arial.ttf",
        "/Library/Fonts/Arial.ttf",
    ],
    "Linux": [
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
        "/usr/share/fonts/TTF/DejaVuSans.ttf",
    ],
}


# --- Console output helpers ---

class C:
    """ANSI color codes (disabled automatically if output isn't a TTY)."""
    _on = sys.stdout.isatty()
    GREEN = "\033[32m" if _on else ""
    YELLOW = "\033[33m" if _on else ""
    RED = "\033[31m" if _on else ""
    CYAN = "\033[36m" if _on else ""
    RESET = "\033[0m" if _on else ""


def info(msg: str) -> None:
    print(f"  {msg}")


def ok(msg: str) -> None:
    print(f"  {C.GREEN}OK{C.RESET}    {msg}")


def warn(msg: str) -> None:
    print(f"  {C.YELLOW}WARN{C.RESET}  {msg}")


def error(msg: str) -> None:
    print(f"  {C.RED}ERROR{C.RESET} {msg}")


def human_size(num_bytes: int) -> str:
    for unit, threshold in (("MB", 1 << 20), ("KB", 1 << 10)):
        if num_bytes >= threshold:
            return f"{num_bytes / threshold:.1f} {unit}"
    return f"{num_bytes} B"


# --- FFmpeg filter construction ---

def crop_filter() -> str:
    w = f"iw-{CROP['left']}-{CROP['right']}"
    h = f"ih-{CROP['top']}-{CROP['bottom']}"
    return f"crop={w}:{h}:{CROP['left']}:{CROP['top']}"


def find_font() -> str | None:
    """Return the first existing font file for this platform, or None."""
    for path in FONT_CANDIDATES.get(platform.system(), []):
        if Path(path).is_file():
            return path
    return None


def escape_fontfile(path: str) -> str:
    """
    Escape a font path for use inside an FFmpeg filtergraph.

    FFmpeg's filter parser treats ':' and '\\' specially, so on Windows a path
    like 'C:\\Windows\\Fonts\\arial.ttf' must become 'C\\:/Windows/Fonts/arial.ttf'.
    """
    p = path.replace("\\", "/")  # backslashes -> forward slashes
    p = p.replace(":", r"\:")  # escape the drive-letter colon
    return p


def label_filter(versions: tuple[str, ...], font: str | None) -> str:
    """Chained drawtext filters, one label per panel.

    If `font` is given, it's passed explicitly via fontfile; otherwise drawtext
    falls back to fontconfig's default font.
    """
    n = len(versions)
    parts = []
    fontfile = f"fontfile='{escape_fontfile(font)}':" if font else ""
    for i, version in enumerate(versions):
        x = str(LABEL["x_offset"]) if i == 0 else f"{i}*w/{n}+{LABEL['x_offset']}"
        parts.append(
            f"drawtext={fontfile}text='{version}'"
            f":fontsize={LABEL['font_size']}"
            f":fontcolor={LABEL['color']}"
            f":borderw={LABEL['border_width']}"
            f":x={x}:y={LABEL['y_offset']}"
        )
    return ",".join(parts)


def build_filtergraph(label_mode: str, font: str | None = None) -> str:
    """Crop each input, stack horizontally, then optionally draw labels.

    label_mode:
        "font"       - draw labels with an explicit font file (most reliable)
        "fontconfig" - draw labels letting fontconfig pick the font
        "none"       - no labels
    """
    crop = crop_filter()
    n = len(VERSIONS)

    crop_stages = []
    stack_inputs = []
    for i in range(n):
        tag = chr(ord("a") + i)
        crop_stages.append(f"[{i}:v]{crop}[{tag}]")
        stack_inputs.append(f"[{tag}]")

    graph = ";".join(crop_stages)
    graph += f";{''.join(stack_inputs)}hstack=inputs={n}"

    if label_mode == "font":
        graph += f"[h];[h]{label_filter(VERSIONS, font)}[out]"
    elif label_mode == "fontconfig":
        graph += f"[h];[h]{label_filter(VERSIONS, None)}[out]"
    else:  # "none"
        graph += "[out]"

    return graph


def run_ffmpeg(inputs: list[Path], filtergraph: str, output: Path) -> bool:
    """Run FFmpeg. Returns True if it exits cleanly."""
    cmd = ["ffmpeg", "-y", "-hide_banner", "-loglevel", "error"]
    for f in inputs:
        cmd += ["-i", str(f)]
    cmd += [
        "-filter_complex", filtergraph,
        "-map", "[out]",
        "-c:v", "libx264",
        "-crf", str(CRF),
        "-preset", PRESET,
        "-pix_fmt", "yuv420p",
        "-an",
        str(output),
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0 and result.stderr.strip():
        # Keep the last line of FFmpeg's error around for context.
        run_ffmpeg.last_error = result.stderr.strip().splitlines()[-1]
    return result.returncode == 0


run_ffmpeg.last_error = ""


def output_valid(path: Path) -> bool:
    return path.exists() and path.stat().st_size > 0


# --- Clip selection parsing ---

def parse_clip_spec(spec: str) -> list[int]:
    """
    Parse a MATLAB-style clip selection into a sorted list of unique clip numbers.

    Accepts space-separated tokens, each either a single number or a START:END
    range (inclusive). Example: "2 3:6 9:14 15" -> [2, 3, 4, 5, 6, 9, ..., 14, 15].

    Raises ValueError on malformed input.
    """
    clips: set[int] = set()

    for token in spec.split():
        if ":" in token:
            lo_str, _, hi_str = token.partition(":")
            try:
                lo, hi = int(lo_str), int(hi_str)
            except ValueError:
                raise ValueError(f"invalid range '{token}' (expected START:END)")
            if lo > hi:
                raise ValueError(f"invalid range '{token}' (start {lo} > end {hi})")
            clips.update(range(lo, hi + 1))
        else:
            try:
                clips.add(int(token))
            except ValueError:
                raise ValueError(f"invalid clip '{token}' (expected a number)")

    return sorted(clips)


# --- Job model ---

@dataclass
class Clip:
    number: str  # zero-padded, e.g. "031"
    inputs: list[Path]  # v1, v3, v4 paths
    output: Path


def discover_clips(
    input_dir: Path, patient: int, requested: list[int] | None
) -> list[Clip]:
    """
    Find clips for a patient that have a v1 file, in sorted order.

    If `requested` is given, only those clip numbers are returned, and any
    requested clip with no v1 file is reported (since the user asked for it
    explicitly). If `requested` is None, every clip found is returned.
    """
    pattern = re.compile(rf"VS_{patient}_(.+?)\.dat_BmodeSeg_v1$")
    found: dict[int, str] = {}  # int clip number -> zero-padded string

    for v1 in input_dir.glob(f"VS_{patient}_*.dat_BmodeSeg_v1.mp4"):
        m = pattern.match(v1.stem)
        if m:
            clip_num = m.group(1).zfill(3)
            found[int(clip_num)] = clip_num

    if requested is not None:
        # warn about missing clips
        for n in requested:
            if n not in found:
                warn(f"Clip {str(n).zfill(3)} -- no v1 file found, skipping")
        selected = [found[n] for n in requested if n in found]
    else:
        selected = [found[n] for n in sorted(found)]

    clips: list[Clip] = []
    for clip_num in selected:
        inputs = [
            input_dir / f"VS_{patient}_{clip_num}.dat_BmodeSeg_{v}.mp4"
            for v in VERSIONS
        ]
        output = OUTPUT_DIR / f"VS_{patient}_{clip_num}_combined.mp4"
        clips.append(Clip(clip_num, inputs, output))

    return clips


def process_clip(clip: Clip) -> str:
    """Combine one clip. Returns 'ok', 'skipped', or 'failed'."""
    missing = [p for p in clip.inputs if not p.exists()]
    if missing:
        warn(f"Clip {clip.number} -- missing versions:")
        for p in missing:
            warn(f"  {p.name}")
        return "skipped"

    info(f"Clip {clip.number} ...")

    # Try labels in order of reliability: explicit font file, then fontconfig, then no labels at all
    if FONT_FILE:
        attempts.append(("font", build_filtergraph("font", FONT_FILE)))
    attempts.append(("fontconfig", build_filtergraph("fontconfig")))
    attempts.append(("none", build_filtergraph("none")))

    label_status = ""
    for mode, graph in attempts:
        run_ffmpeg(clip.inputs, graph, clip.output)
        if output_valid(clip.output):
            label_status = "" if mode != "none" else " (no labels)"
            break
        if mode != "none":
            warn(f"Labels via {mode} failed, retrying ...")

    if output_valid(clip.output):
        size = human_size(clip.output.stat().st_size)
        ok(f"{clip.output.name} ({size}){label_status}")
        return "ok"

    error(f"Failed for clip {clip.number}: {run_ffmpeg.last_error}")
    if clip.output.exists():
        clip.output.unlink()
    return "failed"


# --- Entry point ---

OUTPUT_DIR = Path("./combined")  # set in main()
FONT_FILE: str | None = None  # set in main()


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Combine v1/v3/v4 segmentation videos side-by-side.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "examples:\n"
            "  python combine_elasto.py --patient 55\n"
            '  python combine_elasto.py --patient 55 --clips 31\n'
            '  python combine_elasto.py --patient 55 --clips "2 3:6 9:14 15"\n'
            "  python combine_elasto.py --patient 79 --input-dir ./videos\n"
        ),
    )
    p.add_argument("-p", "--patient", type=int, required=True, help="patient number")
    p.add_argument("-i", "--input-dir", type=Path, default=Path("."), help="folder with input videos")
    p.add_argument("-o", "--output-dir", type=Path, default=Path("./combined"), help="output folder")
    p.add_argument(
        "-c", "--clips", type=str, default=None, metavar="SPEC",
        help='clips to process, MATLAB-style (e.g. "2 3:6 9:14 15"); omit for all',
    )
    return p.parse_args()


def main() -> int:
    global OUTPUT_DIR, FONT_FILE
    args = parse_args()

    if shutil.which("ffmpeg") is None:
        error("ffmpeg not found in PATH.")
        print("\n  Install with:")
        print("    Windows:  winget install ffmpeg")
        print("    macOS:    brew install ffmpeg")
        print("    Linux:    sudo apt install ffmpeg")
        return 1

    FONT_FILE = find_font()

    input_dir = args.input_dir.resolve()
    if not input_dir.is_dir():
        error(f"Input directory not found: {input_dir}")
        return 1

    OUTPUT_DIR = args.output_dir.resolve()
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    # Parse the clip selection (None = all clips found).
    requested: list[int] | None = None
    if args.clips is not None:
        try:
            requested = parse_clip_spec(args.clips)
        except ValueError as e:
            error(f"Bad --clips value: {e}")
            return 1
        if not requested:
            error("--clips was given but resolved to no clips")
            return 1

    print()
    print(f"  {C.CYAN}Video Combiner{C.RESET}")
    print(f"  Patient:    {args.patient}")
    print(f"  Versions:   {', '.join(VERSIONS)}")
    print(f"  Input:      {input_dir}")
    print(f"  Output:     {OUTPUT_DIR}")
    font_label = FONT_FILE if FONT_FILE else "none found (will try fontconfig)"
    print(f"  Font:       {font_label}")
    if requested is not None:
        preview = ", ".join(str(n).zfill(3) for n in requested)
        print(f"  Clips:      {preview}")
    print()

    clips = discover_clips(input_dir, args.patient, requested)
    if not clips:
        error(f"No v1 files found for patient {args.patient} in {input_dir}")
        info(f"Expected: VS_{args.patient}_001.dat_BmodeSeg_v1.mp4")
        return 1

    counts = {"ok": 0, "skipped": 0, "failed": 0}
    for clip in clips:
        counts[process_clip(clip)] += 1

    total = sum(counts.values())
    color = C.YELLOW if counts["failed"] else C.GREEN
    print()
    print(
        f"  {color}Done: {counts['ok']} combined, "
        f"{counts['failed']} failed, {counts['skipped']} skipped "
        f"({total} total){C.RESET}"
    )
    print()

    return 1 if counts["failed"] else 0


if __name__ == "__main__":
    sys.exit(main())
