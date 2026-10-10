#!/usr/bin/env python3
"""Generates the HanaLima app icon.

Writes Resources/AppIcon/AppIcon.svg (the master, 1024x1024 on Apple's macOS icon grid:
an 824x824 squircle centred in the canvas) and, with --render, AppIcon.icns plus a 1024 PNG.

Concept: five petals = VMs (rack-server pills with a status LED), the glowing core = the network
that joins them (with a terminal prompt), the dashed orbit = a virtual network.
"""
import math, os, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "Resources", "AppIcon")
C = 512  # centre

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

def petal(angle):
    """One plumeria petal (a paddle, skewed for the pinwheel overlap), pointing up, then rotated.

    Each petal is also a VM: two vent slots and a status LED near the tip.
    """
    d = (f"M{C+22},{C-46} "
         f"C{C-58},{C-98} {C-150},{C-214} {C-120},{C-298} "
         f"C{C-90},{C-374} {C+80},{C-398} {C+168},{C-310} "
         f"C{C+236},{C-238} {C+150},{C-110} {C+22},{C-46} Z")
    slots = "".join(
        f'<rect x="{C-58}" y="{C-r}" width="64" height="9" rx="4.5" fill="#fff" fill-opacity="0.55" '
        f'transform="rotate(-8 {C-26} {C-r})"/>' for r in (262, 238))
    return f"""
  <g transform="rotate({angle} {C} {C})">
    <path d="{d}" fill="url(#petal)" stroke="#9e0f52" stroke-opacity="0.35" stroke-width="3" filter="url(#drop)"/>
    <path d="{d}" fill="url(#sheen)" clip-path="none" opacity="0.9"/>
    {slots}
    <circle cx="{C-18}" cy="{C-296}" r="10" fill="#d4ff7a"/>
    <circle cx="{C-18}" cy="{C-296}" r="20" fill="#d4ff7a" fill-opacity="0.35" filter="url(#soft)"/>
  </g>"""

def svg():
    body = squircle(C, C, 412)
    # -12 degrees: the pinwheel twist leans the top petal right; this brings it back upright.
    petals = "".join(petal(a - 12) for a in (0, 72, 144, 216, 288))
    grid = "".join(f'<path d="M{v} 0V1024M0 {v}H1024" />' for v in range(100, 925, 48))
    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
  <defs>
    <clipPath id="body"><path d="{body}"/></clipPath>
    <linearGradient id="bg" x1="0.15" y1="0" x2="0.85" y2="1">
      <stop offset="0" stop-color="#2a1340"/>
      <stop offset="0.55" stop-color="#120d22"/>
      <stop offset="1" stop-color="#05070d"/>
    </linearGradient>
    <radialGradient id="bloom" cx="0.5" cy="0.5" r="0.5">
      <stop offset="0" stop-color="#ff4f9a" stop-opacity="0.55"/>
      <stop offset="0.6" stop-color="#ff4f9a" stop-opacity="0.12"/>
      <stop offset="1" stop-color="#ff4f9a" stop-opacity="0"/>
    </radialGradient>
    <radialGradient id="gridFade" cx="0.5" cy="0.42" r="0.6">
      <stop offset="0" stop-color="#fff" stop-opacity="1"/>
      <stop offset="1" stop-color="#fff" stop-opacity="0"/>
    </radialGradient>
    <mask id="gridMask"><rect width="1024" height="1024" fill="url(#gridFade)"/></mask>
    <radialGradient id="petal" gradientUnits="userSpaceOnUse" cx="512" cy="512" r="380">
      <stop offset="0" stop-color="#e4ff6e"/>
      <stop offset="0.24" stop-color="#fff6c8"/>
      <stop offset="0.42" stop-color="#ffd9e9"/>
      <stop offset="0.68" stop-color="#ff6aa9"/>
      <stop offset="1" stop-color="#e01a72"/>
    </radialGradient>
    <linearGradient id="sheen" gradientUnits="userSpaceOnUse" x1="390" y1="140" x2="520" y2="330">
      <stop offset="0" stop-color="#fff" stop-opacity="0.35"/>
      <stop offset="1" stop-color="#fff" stop-opacity="0"/>
    </linearGradient>
    <radialGradient id="core" cx="0.42" cy="0.38" r="0.7">
      <stop offset="0" stop-color="#f2ffc9"/>
      <stop offset="0.45" stop-color="#c3f25e"/>
      <stop offset="1" stop-color="#6fbf1f"/>
    </radialGradient>
    <linearGradient id="rim" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#fff" stop-opacity="0.38"/>
      <stop offset="0.25" stop-color="#fff" stop-opacity="0.06"/>
      <stop offset="1" stop-color="#fff" stop-opacity="0"/>
    </linearGradient>
    <filter id="soft" x="-1" y="-1" width="3" height="3"><feGaussianBlur stdDeviation="8"/></filter>
    <filter id="glow" x="-1" y="-1" width="3" height="3"><feGaussianBlur stdDeviation="26"/></filter>
    <filter id="drop" x="-0.4" y="-0.4" width="1.8" height="1.8">
      <feGaussianBlur in="SourceAlpha" stdDeviation="12"/>
      <feOffset dx="-6" dy="8"/>
      <feComponentTransfer><feFuncA type="linear" slope="0.45"/></feComponentTransfer>
      <feMerge><feMergeNode/><feMergeNode in="SourceGraphic"/></feMerge>
    </filter>
  </defs>

  <g clip-path="url(#body)">
    <rect width="1024" height="1024" fill="url(#bg)"/>
    <g stroke="#8f7cff" stroke-opacity="0.13" stroke-width="2" mask="url(#gridMask)">{grid}</g>
    <circle cx="{C}" cy="{C}" r="380" fill="url(#bloom)"/>
    <circle cx="{C}" cy="{C}" r="372" fill="none" stroke="#c3f25e" stroke-opacity="0.5"
            stroke-width="5" stroke-dasharray="2 22" stroke-linecap="round"/>
    <g>{petals}
    </g>
    <circle cx="{C}" cy="{C}" r="104" fill="#e4ff6e" fill-opacity="0.55" filter="url(#glow)"/>
    <circle cx="{C}" cy="{C}" r="80" fill="#0b0d12"/>
    <circle cx="{C}" cy="{C}" r="67" fill="url(#core)"/>
    <path d="M{C-36} {C-20} L{C-12} {C} L{C-36} {C+20}" fill="none" stroke="#0b0d12" stroke-width="13"
          stroke-linecap="round" stroke-linejoin="round"/>
    <rect x="{C+2}" y="{C+14}" width="34" height="13" rx="6.5" fill="#0b0d12"/>
  </g>
  <path d="{body}" fill="none" stroke="url(#rim)" stroke-width="6" clip-path="url(#body)"/>
</svg>
'''

def main():
    os.makedirs(OUT, exist_ok=True)
    master = os.path.join(OUT, "AppIcon.svg")
    with open(master, "w") as f:
        f.write(svg())
    print("wrote", os.path.relpath(master))
    if "--render" not in sys.argv:
        return
    with tempfile.TemporaryDirectory() as tmp:
        # Quick Look renders SVG with WebKit (filters, gradients, clip paths) and ships with macOS.
        subprocess.run(["qlmanage", "-t", "-s", "1024", "-o", tmp, master],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        png = os.path.join(tmp, "AppIcon.svg.png")
        # Quick Look paints a white background, so cut the outside away with a mask rendered the
        # same way (white squircle on black), keeping the anti-aliased edge.
        mask_svg = os.path.join(tmp, "mask.svg")
        with open(mask_svg, "w") as f:
            f.write('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">'
                    f'<rect width="1024" height="1024" fill="#000"/><path d="{squircle(C, C, 412)}" fill="#fff"/></svg>')
        subprocess.run(["qlmanage", "-t", "-s", "1024", "-o", tmp, mask_svg],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        big = os.path.join(OUT, "AppIcon-1024.png")
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
        subprocess.run(["iconutil", "-c", "icns", iconset, "-o", os.path.join(OUT, "AppIcon.icns")], check=True)
    print("wrote AppIcon.icns and AppIcon-1024.png")

if __name__ == "__main__":
    main()
