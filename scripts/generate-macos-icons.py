#!/usr/bin/env python3
"""Generate the macOS AppIcon assets from the repository root icon.

macOS icons are not full-bleed like iOS ones: the artwork sits in a rounded
square of 824/1024 of the canvas with a transparent margin (Apple's macOS
icon grid), so the Dock shows Colitu at the same size as other apps.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

try:
    from PIL import Image, ImageDraw
except ImportError as exc:
    raise SystemExit(
        "Pillow is required. Install it with: python3 -m pip install Pillow"
    ) from exc


ROOT = Path(__file__).resolve().parents[1]
SOURCE_CANDIDATES = [
    ROOT / "icon.png",
    ROOT / "colitu-icon.png",
    ROOT / "assets" / "brand" / "mark.png",
]
SOURCE = next((path for path in SOURCE_CANDIDATES if path.exists()), SOURCE_CANDIDATES[0])
OUTPUT_DIR = ROOT / "macos" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"

# (point size, scale)
ICONS = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]

CANVAS = 1024
BODY = 824
RADIUS = 185


def master(source: Image.Image) -> Image.Image:
    width, height = source.size
    side = min(width, height)
    left = (width - side) // 2
    top = (height - side) // 2
    body = source.crop((left, top, left + side, top + side)).resize((BODY, BODY), Image.LANCZOS)
    mask = Image.new("L", (BODY * 4, BODY * 4), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, BODY * 4 - 1, BODY * 4 - 1), radius=RADIUS * 4, fill=255)
    body.putalpha(mask.resize((BODY, BODY), Image.LANCZOS))
    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    offset = (CANVAS - BODY) // 2
    canvas.alpha_composite(body, (offset, offset))
    return canvas


def main() -> int:
    if not SOURCE.exists():
        print(f"Source icon not found; keeping the committed macOS AppIcon set.", file=sys.stderr)
        return 0

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    for stale_png in OUTPUT_DIR.glob("*.png"):
        stale_png.unlink()

    icon = master(Image.open(SOURCE).convert("RGBA"))
    images = []
    for points, scale in ICONS:
        pixels = points * scale
        name = f"AppIcon-{points}x{points}@{scale}x.png"
        icon.resize((pixels, pixels), Image.LANCZOS).save(OUTPUT_DIR / name, optimize=True)
        images.append({
            "filename": name,
            "idiom": "mac",
            "scale": f"{scale}x",
            "size": f"{points}x{points}",
        })

    contents = {"images": images, "info": {"author": "xcode", "version": 1}}
    (OUTPUT_DIR / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n", encoding="utf-8")
    print(f"Generated {len(images)} macOS icons in {OUTPUT_DIR}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
