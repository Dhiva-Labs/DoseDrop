#!/usr/bin/env python3
"""Generates the DoseDrop tray icon: a 64x64 teal droplet on transparency.

The tray icon is a committed binary asset (assets/icon/tray.png); this script is
how it is produced, so it can be regenerated or resized without hand-editing a
PNG.

    python3 tools/generate_tray_icon.py [--size 64] [--out assets/icon/tray.png]

Requires Pillow.
"""

from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image

# DD.teal from lib/theme/app_theme.dart — the droplet must match the brand.
TEAL = (13, 148, 136, 255)
TRANSPARENT = (0, 0, 0, 0)

# Supersampling factor: draw big, downscale for antialiasing.
SCALE = 8


def droplet_mask(size: int) -> Image.Image:
    """Builds an L-mode mask of a teardrop that fills `size` x `size`."""
    n = size * SCALE
    margin = n * 0.06
    apex_y = margin
    bulb_r = (n - 2 * margin) * 0.34
    cx = n / 2
    bulb_cy = n - margin - bulb_r

    mask = Image.new("L", (n, n), 0)
    pixels = mask.load()
    span = bulb_cy - apex_y

    for y in range(n):
        # Bulb: a circle at the bottom.
        dy = y - bulb_cy
        if abs(dy) <= bulb_r:
            half = (bulb_r * bulb_r - dy * dy) ** 0.5
        else:
            half = -1.0
        # Taper: a power curve from the apex down to the bulb's centre line.
        if apex_y <= y <= bulb_cy:
            t = (y - apex_y) / span
            taper = bulb_r * (t ** 1.5)
            half = max(half, taper)
        if half <= 0:
            continue
        x0 = max(0, int(cx - half))
        x1 = min(n - 1, int(cx + half))
        for x in range(x0, x1 + 1):
            pixels[x, y] = 255

    return mask.resize((size, size), Image.LANCZOS)


def build(size: int) -> Image.Image:
    icon = Image.new("RGBA", (size, size), TRANSPARENT)
    solid = Image.new("RGBA", (size, size), TEAL)
    icon.paste(solid, (0, 0), droplet_mask(size))
    return icon


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--size", type=int, default=64)
    parser.add_argument(
        "--out",
        type=Path,
        default=Path(__file__).resolve().parents[1] / "assets/icon/tray.png",
    )
    args = parser.parse_args()

    args.out.parent.mkdir(parents=True, exist_ok=True)
    build(args.size).save(args.out, "PNG", optimize=True)
    print(f"wrote {args.out} ({args.size}x{args.size})")


if __name__ == "__main__":
    main()
