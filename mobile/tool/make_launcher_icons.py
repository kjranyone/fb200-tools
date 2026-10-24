"""Generate Android adaptive launcher icon layers from the branding master.

Reads mobile/assets/branding/fb200-studio-icon.png (1024 x 1024, opaque) and
writes, for every mipmap density:

- ic_launcher_foreground.png: the knob, scaled so its outer ring spans 64 dp
  of the 108 dp adaptive canvas (inside the 66 dp safe zone), faded to
  transparent just outside the ring so it blends into the background layer.
- ic_launcher_monochrome.png: a flat silhouette for Android 13+ themed icons
  (signal arc, knob disc and pointer notch), on the same geometry.

The solid background color lives in values/ic_launcher_background.xml.

Requires Pillow. Run from anywhere: python mobile/tool/make_launcher_icons.py
"""

from __future__ import annotations

import math
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

MOBILE = Path(__file__).resolve().parents[1]
MASTER = MOBILE / "assets" / "branding" / "fb200-studio-icon.png"
RES = MOBILE / "android" / "app" / "src" / "main" / "res"

# Adaptive icon canvas size in px per density (108 dp).
DENSITIES = {"mdpi": 108, "hdpi": 162, "xhdpi": 216, "xxhdpi": 324, "xxxhdpi": 432}

# Master geometry, in master px (1024 canvas, centre 512, 512).
RING_RADIUS = 392  # outer edge of the machined ring
FADE = (412, 440)  # alpha ramps from opaque to clear between these radii
ARC_RADIUS = 320  # centre line of the orange arc
ARC_WIDTH = 26
ARC_SPAN = (167, 373)  # PIL degrees, clockwise from 3 o'clock, through the top
DISC_RADIUS = 232
NOTCH = (499, 280, 523, 374)  # pointer marker box

RING_DP = 64.0
CANVAS_DP = 108.0


def radial_alpha(size: int) -> Image.Image:
    """Opaque inside FADE[0], clear outside FADE[1], linear in between."""
    ss = 4
    big = size * ss
    mask = Image.new("L", (big, big), 0)
    draw = ImageDraw.Draw(mask)
    c = big / 2
    lo, hi = (r * big / 1024 for r in FADE)
    steps = 64
    for i in range(steps, -1, -1):
        r = lo + (hi - lo) * i / steps
        draw.ellipse((c - r, c - r, c + r, c + r), fill=round(255 * (1 - i / steps)))
    return mask.resize((size, size), Image.LANCZOS)


def monochrome_master() -> Image.Image:
    ss = 4
    big = 1024 * ss
    mask = Image.new("L", (big, big), 0)
    draw = ImageDraw.Draw(mask)
    c = big / 2

    w = ARC_WIDTH * ss
    mid = ARC_RADIUS * ss
    r = mid + w / 2
    draw.arc((c - r, c - r, c + r, c + r), ARC_SPAN[0], ARC_SPAN[1], fill=255, width=w)
    # Round caps on both arc ends.

    for deg in ARC_SPAN:
        a = math.radians(deg)
        x, y = c + mid * math.cos(a), c + mid * math.sin(a)
        draw.ellipse((x - w / 2, y - w / 2, x + w / 2, y + w / 2), fill=255)

    d = DISC_RADIUS * ss
    draw.ellipse((c - d, c - d, c + d, c + d), fill=255)
    x0, y0, x1, y1 = (v * ss for v in NOTCH)
    draw.rounded_rectangle((x0, y0, x1, y1), radius=(x1 - x0) / 2, fill=0)

    alpha = mask.resize((1024, 1024), Image.LANCZOS)
    out = Image.new("RGBA", (1024, 1024), (255, 255, 255, 0))
    out.putalpha(alpha)
    return out


def place(layer: Image.Image, canvas: int) -> Image.Image:
    """Scale a 1024 master layer so the ring spans RING_DP, centred on canvas."""
    scale = canvas / CANVAS_DP * RING_DP / (2 * RING_RADIUS)
    side = round(1024 * scale)
    scaled = layer.resize((side, side), Image.LANCZOS)
    out = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
    off = (canvas - side) // 2
    out.alpha_composite(scaled, (off, off))
    return out


def main() -> None:
    master = Image.open(MASTER).convert("RGBA")
    fg = master.copy()
    fg.putalpha(ImageChops.multiply(master.getchannel("A"), radial_alpha(1024)))
    mono = monochrome_master()

    for name, canvas in DENSITIES.items():
        folder = RES / f"mipmap-{name}"
        place(fg, canvas).save(folder / "ic_launcher_foreground.png", optimize=True)
        place(mono, canvas).save(folder / "ic_launcher_monochrome.png", optimize=True)

    # Background colour: median of the master's outer border.
    border = master.convert("RGB").crop((0, 0, 1024, 40)).filter(ImageFilter.MedianFilter(5))
    r, g, b = border.resize((1, 1), Image.BOX).getpixel((0, 0))
    print(f"background #{r:02x}{g:02x}{b:02x}")


if __name__ == "__main__":
    main()
