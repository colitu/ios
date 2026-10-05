#!/usr/bin/env python3
"""Generate iOS AppIcon assets from the repository root icon.png."""

from __future__ import annotations

import json
import sys
from pathlib import Path

try:
    from PIL import Image
except ImportError as exc:
    raise SystemExit(
        "Pillow is required. Install it with: python3 -m pip install Pillow"
    ) from exc


ROOT = Path(__file__).resolve().parents[1]
# First one that exists wins: an explicit icon.png override, the product icon
# shared with the Windows app, then the brand mark.
SOURCE_CANDIDATES = [
    ROOT / "icon.png",
    ROOT / "colitu-icon.png",
    ROOT / "assets" / "brand" / "mark.png",
]
SOURCE = next((path for path in SOURCE_CANDIDATES if path.exists()), SOURCE_CANDIDATES[0])
OUTPUT_DIR = ROOT / "ios" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"

ICONS = [
    ("iphone", "20x20", "2x", 40),
    ("iphone", "20x20", "3x", 60),
    ("iphone", "29x29", "2x", 58),
    ("iphone", "29x29", "3x", 87),
    ("iphone", "40x40", "2x", 80),
    ("iphone", "40x40", "3x", 120),
    ("iphone", "60x60", "2x", 120),
    ("iphone", "60x60", "3x", 180),
    ("ipad", "20x20", "1x", 20),
    ("ipad", "20x20", "2x", 40),
    ("ipad", "29x29", "1x", 29),
    ("ipad", "29x29", "2x", 58),
    ("ipad", "40x40", "1x", 40),
    ("ipad", "40x40", "2x", 80),
    ("ipad", "76x76", "1x", 76),
    ("ipad", "76x76", "2x", 152),
    ("ipad", "83.5x83.5", "2x", 167),
    ("ios-marketing", "1024x1024", "1x", 1024),
]


def filename(idiom: str, size: str, scale: str, pixels: int) -> str:
    safe_size = size.replace(".", "_")
    return f"AppIcon-{idiom}-{safe_size}@{scale}-{pixels}.png"


def main() -> int:
    if not SOURCE.exists():
        # The generated icon set is committed; a missing source must not fail CI.
        print(
            f"Source icon not found ({', '.join(str(p) for p in SOURCE_CANDIDATES)}); "
            "keeping the committed AppIcon set.",
            file=sys.stderr,
        )
        return 0

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    for stale_png in OUTPUT_DIR.glob("*.png"):
        stale_png.unlink()

    source = Image.open(SOURCE).convert("RGBA")
    width, height = source.size
    side = min(width, height)
    left = (width - side) // 2
    top = (height - side) // 2
    source = source.crop((left, top, left + side, top + side))

    images = []
    for idiom, point_size, scale, pixels in ICONS:
        name = filename(idiom, point_size, scale, pixels)
        target = OUTPUT_DIR / name
        resized = source.resize((pixels, pixels), Image.Resampling.LANCZOS)
        background = Image.new("RGB", resized.size, (255, 255, 255))
        background.paste(resized, mask=resized.getchannel("A"))
        background.save(target, "PNG", optimize=True)
        images.append(
            {
                "idiom": idiom,
                "size": point_size,
                "scale": scale,
                "filename": name,
            }
        )

    contents = {"images": images, "info": {"author": "xcode", "version": 1}}
    (OUTPUT_DIR / "Contents.json").write_text(
        json.dumps(contents, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )

    print(f"Generated {len(images)} iOS app icons in {OUTPUT_DIR}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
