#!/usr/bin/env python3
# Draws the DMG artwork into Resources/DMG (needs Pillow). Run it only after changing
# the settings below or the app icon, and commit the results; scripts/release.sh only
# uses them.
#   VolumeIcon.icns   the icon of the mounted disk: a drive with the app's emblem on its face
#   background.tiff   the opened window's background (540x380 points, 1x and 2x in one TIFF)
# The window layout in scripts/make_dmg.sh puts the icons' centres at (140, 180) and (400, 180).
import os
import subprocess
import sys
import tempfile

import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "Resources", "DMG")

# ---- per app ----------------------------------------------------------------
CONFIG = {
    "app_icon": "Resources/AppIcon/AppIcon-1024.png",
    "emblem_radius": 400,                    # the disc cut from the 1024px icon
    "emblem_ring": (255, 255, 255, 255),
    "body_top": (255, 236, 243, 255),        # a pink drive, like the icon's background
    "body_bottom": (232, 170, 196, 255),
    "rim": (255, 255, 255, 200),
    "arrow_start": (240, 160, 196, 255),     # petal pink to the green of the centre
    "arrow_end": (118, 186, 58, 255),
    "font": "/System/Library/Fonts/ヒラギノ角ゴシック W3.ttc",
    "caption": ["Drag HanaLima to Applications to install", "HanaLima を Applications へドラッグしてインストールします"],
}

# ---- drawing ----------------------------------------------------------------
K = 2  # draw at twice the size, then scale down (antialiasing)


def gradient(w, h, top, bottom):
    t = np.linspace(0, 1, h)[:, None, None]
    a = np.array(top, float)[None, None, :] * (1 - t) + np.array(bottom, float)[None, None, :] * t
    return Image.fromarray(np.repeat(a, w, axis=1).astype(np.uint8), "RGBA")


def emblem(icon_path, radius, ring):
    """A disc cut from the middle of the app icon, with a ring around it."""
    icon = Image.open(icon_path).convert("RGBA").resize((1024, 1024), Image.LANCZOS)
    disc = icon.crop((512 - radius, 512 - radius, 512 + radius, 512 + radius)).resize((800, 800), Image.LANCZOS)
    mask = Image.new("L", (800, 800), 0)
    ImageDraw.Draw(mask).ellipse((0, 0, 799, 799), fill=255)
    disc.putalpha(ImageChops.multiply(disc.split()[3], mask))
    ImageDraw.Draw(disc).ellipse((6, 6, 793, 793), outline=ring, width=14)
    return disc


def volume_icon(c):
    size = 1024 * K
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    x0, y0, w, h = 62 * K, 262 * K, 900 * K, 520 * K
    mask = Image.new("L", (w, h), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, w - 1, h - 1), 110 * K, fill=255)
    body = gradient(w, h, c["body_top"], c["body_bottom"])
    body.putalpha(mask)
    ImageDraw.Draw(body).rounded_rectangle((4 * K, 4 * K, w - 5 * K, h - 5 * K), 106 * K, outline=c["rim"], width=6 * K)
    img.alpha_composite(body, (x0, y0))
    d = 400 * K
    face = emblem(os.path.join(ROOT, c["app_icon"]), c["emblem_radius"], c["emblem_ring"]).resize((d, d), Image.LANCZOS)
    img.alpha_composite(face, ((size - d) // 2, 522 * K - d // 2))
    ImageDraw.Draw(img).ellipse((865 * K, 703 * K, 891 * K, 729 * K), fill=(79, 220, 120, 255))  # the activity light
    shadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    shadow.putalpha(img.split()[3].point(lambda v: v * 97 // 255))
    shadow = shadow.filter(ImageFilter.GaussianBlur(22 * K))
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.alpha_composite(shadow, (0, 18 * K))
    out.alpha_composite(img)
    return out.resize((1024, 1024), Image.LANCZOS)


def bezier(p0, p1, p2, p3, n=200):
    t = np.linspace(0, 1, n)[:, None]
    return (1 - t) ** 3 * p0 + 3 * (1 - t) ** 2 * t * p1 + 3 * (1 - t) * t ** 2 * p2 + t ** 3 * p3


def background(c, scale):
    w, h = 540 * scale, 380 * scale
    img = gradient(w, h, (247, 247, 249, 255), (228, 229, 234, 255))
    draw = ImageDraw.Draw(img)
    # The arrow from the app to Applications, coloured from the start to the end colour.
    pts = bezier(*(np.array(p, float) * scale for p in [(218, 182), (246, 152), (286, 150), (308, 167)]))
    start, end = np.array(c["arrow_start"], float), np.array(c["arrow_end"], float)
    r = 4 * scale
    for i, (x, y) in enumerate(pts):
        col = tuple(int(v) for v in start + (end - start) * i / (len(pts) - 1))
        draw.ellipse((x - r, y - r, x + r, y + r), fill=col)
    # The head points along the curve's end.
    tip = pts[-1] + (pts[-1] - pts[-8]) / np.linalg.norm(pts[-1] - pts[-8]) * 16 * scale
    u = (tip - pts[-1]) / np.linalg.norm(tip - pts[-1])
    n = np.array([-u[1], u[0]])
    base = tip - u * 26 * scale
    head = [tuple(tip), tuple(base + n * 14 * scale), tuple(base - n * 14 * scale)]
    draw.polygon(head, fill=tuple(int(v) for v in end))
    font = ImageFont.truetype(c["font"], 13 * scale, index=c.get("font_index", 0))
    for i, line in enumerate(c["caption"]):
        draw.text((w / 2, (334 + 18 * i - 9 * (len(c["caption"]) - 1)) * scale), line, fill=(110, 110, 115, 255),
                  font=font, anchor="mm")
    return img


def main():
    os.makedirs(OUT, exist_ok=True)
    with tempfile.TemporaryDirectory() as work:
        png = os.path.join(work, "volume.png")
        volume_icon(CONFIG).save(png)
        iconset = os.path.join(work, "VolumeIcon.iconset")
        os.mkdir(iconset)
        icon = Image.open(png)
        for s in (16, 32, 128, 256, 512):
            icon.resize((s, s), Image.LANCZOS).save(os.path.join(iconset, f"icon_{s}x{s}.png"))
            icon.resize((s * 2, s * 2), Image.LANCZOS).save(os.path.join(iconset, f"icon_{s}x{s}@2x.png"))
        subprocess.run(["iconutil", "-c", "icns", iconset, "-o", os.path.join(OUT, "VolumeIcon.icns")], check=True)
        one, two = os.path.join(work, "bg.png"), os.path.join(work, "bg@2x.png")
        # Drawn 4 times larger and scaled down, since ImageDraw does not antialias
        background(CONFIG, 4).resize((540, 380), Image.LANCZOS).save(one, dpi=(72, 72))
        background(CONFIG, 8).resize((1080, 760), Image.LANCZOS).save(two, dpi=(144, 144))  # 144 dpi: used on Retina
        subprocess.run(["tiffutil", "-cathidpicheck", one, two, "-out", os.path.join(OUT, "background.tiff")],
                       check=True, stdout=subprocess.DEVNULL)
    print(f"Wrote {OUT}/VolumeIcon.icns and background.tiff")


if __name__ == "__main__":
    sys.exit(main())
