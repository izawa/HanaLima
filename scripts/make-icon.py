#!/usr/bin/env python3
"""Generates the HanaLima app icon.

Hana Lima is Hawaiian for "handmade" (hana: work, lima: hand); lima also means five, and hana
sounds like 花 (flower). The icon is a plumeria — the Hawaiian lei flower, five pointed petals
overlapping like a pinwheel — whose petals are VMs (vent slots and a status LED), around a glowing
network core with a terminal prompt, on a dotted virtual-network orbit.

Usage:
  scripts/make-icon.py [--theme light|white|dark] [--render] [--out DIR]

Writes AppIcon.svg (1024x1024 on Apple's macOS icon grid: an 824x824 squircle centred in the
canvas) and, with --render, AppIcon-1024.png and AppIcon.icns, into Resources/AppIcon by default.
Rendering uses Quick Look (WebKit), sips and iconutil, all part of macOS.
"""
import argparse, math, os, subprocess, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
C = 512  # centre

THEMES = {
    # Pale blush to mint: lets the pink petals and lime core carry the colour.
    "light": dict(bg=("#fff4f8", "#fde8f1", "#e9f7e4"), grid="#c2185b", grid_opacity=0.07,
                  bloom="#ff7ab2", bloom_opacity=0.30, orbit="#5aa61a", orbit_opacity=0.55,
                  shadow=0.22, outline="#c2185b", outline_opacity=0.28, rim="#ffffff", rim_opacity=0.9),
    "white": dict(bg=("#ffffff", "#fbfbfd", "#f1f2f6"), grid="#3a3f58", grid_opacity=0.05,
                  bloom="#ff7ab2", bloom_opacity=0.18, orbit="#5aa61a", orbit_opacity=0.5,
                  shadow=0.20, outline="#c2185b", outline_opacity=0.28, rim="#ffffff", rim_opacity=0.9),
    "dark": dict(bg=("#2a1340", "#120d22", "#05070d"), grid="#8f7cff", grid_opacity=0.13,
                 bloom="#ff4f9a", bloom_opacity=0.55, orbit="#c3f25e", orbit_opacity=0.5,
                 shadow=0.45, outline="#9e0f52", outline_opacity=0.35, rim="#ffffff", rim_opacity=0.38),
}


def squircle(cx, cy, half, n=5.0, steps=720):
    """Superellipse close to Apple's continuous-corner icon shape."""
    pts = []
    for i in range(steps):
        t = 2 * math.pi * i / steps
        c, s = math.cos(t), math.sin(t)
        x = cx + half * math.copysign(abs(c) ** (2 / n), c)
        y = cy + half * math.copysign(abs(s) ** (2 / n), s)
        pts.append(f"{x:.2f},{y:.2f}")
    return "M" + " L".join(pts) + " Z"


def petal(angle, t):
    """One plumeria petal, pointing up, then rotated around the centre.

    Narrow at the base, widest two thirds out, and ending in a soft point (not a round lobe, which
    reads as a plum blossom); the right side bulges so each petal overlaps the next (pinwheel).
    """
    tip = (C + 46, C - 404)
    d = (f"M{C+22},{C-46} "
         f"C{C-50},{C-96} {C-126},{C-200} {C-106},{C-286} "
         f"C{C-92},{C-344} {C-14},{C-376} {tip[0]},{tip[1]} "
         f"C{C+104},{C-384} {C+176},{C-306} {C+162},{C-226} "
         f"C{C+148},{C-150} {C+104},{C-92} {C+22},{C-46} Z")
    slots = "".join(
        f'<rect x="{C-56}" y="{C-r}" width="62" height="9" rx="4.5" fill="#fff" fill-opacity="0.6" '
        f'transform="rotate(-12 {C-25} {C-r})"/>' for r in (262, 238))
    return f"""
  <g transform="rotate({angle} {C} {C})">
    <path d="{d}" fill="url(#petal)" stroke="{t['outline']}" stroke-opacity="{t['outline_opacity']}"
          stroke-width="3" stroke-linejoin="round" filter="url(#drop)"/>
    <path d="{d}" fill="url(#sheen)"/>
    {slots}
    <circle cx="{C-14}" cy="{C-300}" r="10" fill="#c8f55a" stroke="#4f8f12" stroke-opacity="0.35" stroke-width="2"/>
    <circle cx="{C-14}" cy="{C-300}" r="20" fill="#d4ff7a" fill-opacity="0.35" filter="url(#soft)"/>
  </g>"""


def svg(theme):
    t = THEMES[theme]
    body = squircle(C, C, 412)
    # -12 degrees: the pinwheel twist leans the top petal right; this brings it back upright.
    petals = "".join(petal(a - 12, t) for a in (0, 72, 144, 216, 288))
    grid = "".join(f'<path d="M{v} 0V1024M0 {v}H1024" />' for v in range(100, 925, 48))
    bg0, bg1, bg2 = t["bg"]
    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
  <defs>
    <clipPath id="body"><path d="{body}"/></clipPath>
    <linearGradient id="bg" x1="0.15" y1="0" x2="0.85" y2="1">
      <stop offset="0" stop-color="{bg0}"/>
      <stop offset="0.55" stop-color="{bg1}"/>
      <stop offset="1" stop-color="{bg2}"/>
    </linearGradient>
    <radialGradient id="bloom" cx="0.5" cy="0.5" r="0.5">
      <stop offset="0" stop-color="{t['bloom']}" stop-opacity="{t['bloom_opacity']}"/>
      <stop offset="0.6" stop-color="{t['bloom']}" stop-opacity="{t['bloom_opacity'] * 0.25:.3f}"/>
      <stop offset="1" stop-color="{t['bloom']}" stop-opacity="0"/>
    </radialGradient>
    <radialGradient id="gridFade" cx="0.5" cy="0.42" r="0.6">
      <stop offset="0" stop-color="#fff" stop-opacity="1"/>
      <stop offset="1" stop-color="#fff" stop-opacity="0"/>
    </radialGradient>
    <mask id="gridMask"><rect width="1024" height="1024" fill="url(#gridFade)"/></mask>
    <radialGradient id="petal" gradientUnits="userSpaceOnUse" cx="512" cy="512" r="400">
      <stop offset="0" stop-color="#e4ff6e"/>
      <stop offset="0.22" stop-color="#fff6c8"/>
      <stop offset="0.40" stop-color="#ffdcea"/>
      <stop offset="0.68" stop-color="#ff6aa9"/>
      <stop offset="1" stop-color="#e01a72"/>
    </radialGradient>
    <linearGradient id="sheen" gradientUnits="userSpaceOnUse" x1="390" y1="130" x2="520" y2="330">
      <stop offset="0" stop-color="#fff" stop-opacity="0.35"/>
      <stop offset="1" stop-color="#fff" stop-opacity="0"/>
    </linearGradient>
    <radialGradient id="core" cx="0.42" cy="0.38" r="0.7">
      <stop offset="0" stop-color="#f2ffc9"/>
      <stop offset="0.45" stop-color="#c3f25e"/>
      <stop offset="1" stop-color="#6fbf1f"/>
    </radialGradient>
    <linearGradient id="rim" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="{t['rim']}" stop-opacity="{t['rim_opacity']}"/>
      <stop offset="0.25" stop-color="{t['rim']}" stop-opacity="{t['rim_opacity'] * 0.15:.3f}"/>
      <stop offset="1" stop-color="{t['rim']}" stop-opacity="0"/>
    </linearGradient>
    <filter id="soft" x="-1" y="-1" width="3" height="3"><feGaussianBlur stdDeviation="8"/></filter>
    <filter id="glow" x="-1" y="-1" width="3" height="3"><feGaussianBlur stdDeviation="26"/></filter>
    <filter id="drop" x="-0.4" y="-0.4" width="1.8" height="1.8">
      <feGaussianBlur in="SourceAlpha" stdDeviation="12"/>
      <feOffset dx="-6" dy="8"/>
      <feComponentTransfer><feFuncA type="linear" slope="{t['shadow']}"/></feComponentTransfer>
      <feMerge><feMergeNode/><feMergeNode in="SourceGraphic"/></feMerge>
    </filter>
  </defs>

  <g clip-path="url(#body)">
    <rect width="1024" height="1024" fill="url(#bg)"/>
    <g stroke="{t['grid']}" stroke-opacity="{t['grid_opacity']}" stroke-width="2" mask="url(#gridMask)">{grid}</g>
    <circle cx="{C}" cy="{C}" r="390" fill="url(#bloom)"/>
    <circle cx="{C}" cy="{C}" r="364" fill="none" stroke="{t['orbit']}" stroke-opacity="{t['orbit_opacity']}"
            stroke-width="5" stroke-dasharray="2 22" stroke-linecap="round"/>
    <g transform="translate({C} {C}) scale(0.88) translate({-C} {-C})">{petals}
    </g>
    <circle cx="{C}" cy="{C}" r="104" fill="#e4ff6e" fill-opacity="0.55" filter="url(#glow)"/>
    <circle cx="{C}" cy="{C}" r="80" fill="#0b0d12"/>
    <circle cx="{C}" cy="{C}" r="67" fill="url(#core)"/>
    <path d="M{C-36} {C-20} L{C-12} {C} L{C-36} {C+20}" fill="none" stroke="#0b0d12" stroke-width="13"
          stroke-linecap="round" stroke-linejoin="round"/>
    <rect x="{C+2}" y="{C+14}" width="34" height="13" rx="6.5" fill="#0b0d12"/>
    <path d="{body}" fill="none" stroke="url(#rim)" stroke-width="6"/>
  </g>
</svg>
'''


def render(master, out):
    """AppIcon-1024.png and AppIcon.icns from the SVG master."""
    with tempfile.TemporaryDirectory() as tmp:
        subprocess.run(["qlmanage", "-t", "-s", "1024", "-o", tmp, master],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        png = os.path.join(tmp, os.path.basename(master) + ".png")
        # Quick Look paints a white background, so cut the outside away with a mask rendered the
        # same way (white squircle on black), keeping the anti-aliased edge.
        mask_svg = os.path.join(tmp, "mask.svg")
        with open(mask_svg, "w") as f:
            f.write('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">'
                    f'<rect width="1024" height="1024" fill="#000"/><path d="{squircle(C, C, 412)}" fill="#fff"/></svg>')
        subprocess.run(["qlmanage", "-t", "-s", "1024", "-o", tmp, mask_svg],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        big = os.path.join(out, "AppIcon-1024.png")
        subprocess.run(["magick", png, "(", os.path.join(tmp, "mask.svg.png"), "-colorspace", "gray", ")",
                        "-alpha", "off", "-compose", "CopyOpacity", "-composite", big], check=True)
        iconset = os.path.join(tmp, "AppIcon.iconset")
        os.makedirs(iconset)
        for size in (16, 32, 128, 256, 512):
            for scale in (1, 2):
                px = size * scale
                name = f"icon_{size}x{size}{'@2x' if scale == 2 else ''}.png"
                subprocess.run(["sips", "-z", str(px), str(px), big, "--out", os.path.join(iconset, name)],
                               check=True, stdout=subprocess.DEVNULL)
        subprocess.run(["iconutil", "-c", "icns", iconset, "-o", os.path.join(out, "AppIcon.icns")], check=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--theme", choices=sorted(THEMES), default="light")
    ap.add_argument("--render", action="store_true")
    ap.add_argument("--out", default=os.path.join(HERE, "..", "Resources", "AppIcon"))
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)
    master = os.path.join(args.out, "AppIcon.svg")
    with open(master, "w") as f:
        f.write(svg(args.theme))
    if args.render:
        render(master, args.out)
    print(f"{args.theme}: wrote {os.path.relpath(args.out)}")


if __name__ == "__main__":
    main()
