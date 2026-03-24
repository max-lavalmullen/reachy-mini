#!/usr/bin/env python3
"""
Generate ReachyControl.icns from the official reachy-mini-awake.svg
bundled with the reachy_mini Python package.
"""
import os, glob, subprocess
from svglib.svglib import svg2rlg
from reportlab.graphics import renderPM
from PIL import Image

OUT_ICNS = "resources/ReachyControl.icns"
ICONSET  = "/tmp/ReachyAwake.iconset"


def find_svg():
    patterns = [
        "python/.venv/lib/python*/site-packages/reachy_mini/daemon/app/dashboard/static/assets/reachy-mini-awake.svg",
        "ReachyControl.app/Contents/Resources/venv/lib/python*/site-packages/reachy_mini/daemon/app/dashboard/static/assets/reachy-mini-awake.svg",
    ]
    for pat in patterns:
        hits = glob.glob(pat)
        if hits:
            return hits[0]
    raise FileNotFoundError("reachy-mini-awake.svg not found — is the venv set up?")


def main():
    svg_path = find_svg()
    print(f"SVG: {svg_path}")
    os.makedirs(ICONSET, exist_ok=True)
    os.makedirs("resources", exist_ok=True)

    # Render SVG at high resolution
    drawing = svg2rlg(svg_path)
    scale = 1024 / drawing.width
    drawing.width  = 1024
    drawing.height = int(drawing.height * scale)
    drawing.transform = (scale, 0, 0, scale, 0, 0)

    tmp_png = f"{ICONSET}/raw_1024.png"
    renderPM.drawToFile(drawing, tmp_png, fmt="PNG", dpi=144)

    # Pad to square using the SVG background colour (#3DDE99)
    base = Image.open(tmp_png).convert("RGBA")
    w, h = base.size
    sq = max(w, h)
    padded = Image.new("RGBA", (sq, sq), (61, 222, 153, 255))
    padded.paste(base, ((sq - w) // 2, (sq - h) // 2), base)
    padded = padded.resize((1024, 1024), Image.LANCZOS)

    # Generate all required iconset sizes
    sizes = [16, 32, 64, 128, 256, 512, 1024]
    for sz in sizes:
        img = padded.resize((sz, sz), Image.LANCZOS)
        img.save(f"{ICONSET}/icon_{sz}x{sz}.png")
        if sz <= 512:
            img2 = padded.resize((sz * 2, sz * 2), Image.LANCZOS)
            img2.save(f"{ICONSET}/icon_{sz}x{sz}@2x.png")
    print(f"Sizes generated, converting to ICNS → {OUT_ICNS}")
    subprocess.run(["iconutil", "-c", "icns", ICONSET, "-o", OUT_ICNS], check=True)
    print("Done ✓")


if __name__ == "__main__":
    main()
