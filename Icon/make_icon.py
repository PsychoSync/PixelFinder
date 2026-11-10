"""Turns icon_source.png into a true pixel-grid AppIcon.icns.

The source art is cut out of its white background, snapped onto its detected native
pixel lattice (one colour per art pixel), then scaled up with nearest-neighbour so
every art pixel is a perfectly square block at each icon size.
Requires Pillow + numpy.
"""
import os
import shutil
import subprocess
import sys
from collections import deque

import numpy as np
from PIL import Image

TARGET = 824       # Apple icon grid: artwork area inside the 1024 canvas
SUBDIV = 2         # the generated art mixes full and half-size pixels; sample at half period
HERE = os.path.dirname(os.path.abspath(__file__))


def background_mask(rgb):
    """Near-white pixels connected to the image border."""
    h, w, _ = rgb.shape
    whiteish = (rgb.min(axis=2) > 225)
    bg = np.zeros((h, w), bool)
    q = deque()
    for x in range(w):
        q.extend([(0, x), (h - 1, x)])
    for y in range(h):
        q.extend([(y, 0), (y, w - 1)])
    while q:
        y, x = q.popleft()
        if 0 <= y < h and 0 <= x < w and not bg[y, x] and whiteish[y, x]:
            bg[y, x] = True
            q.extend([(y + 1, x), (y - 1, x), (y, x + 1), (y, x - 1)])
    return bg


def lattice(gray, axis):
    """Native pixel period and first edge position along one axis, from edge energy."""
    g = np.abs(np.diff(gray, axis=axis)).sum(axis=1 - axis)
    idx = np.arange(len(g))
    best = None
    for period in np.arange(5.0, 24.0, 0.01):
        s = (g * np.exp(2j * np.pi * idx / period)).sum()
        if best is None or abs(s) > best[0]:
            best = (abs(s), period, np.angle(s))
    _, period, phase = best
    edge = (phase / (2 * np.pi) * period) % period + 0.5   # diff index i sits between pixels i and i+1
    return period, edge


def snap(rgb, fg):
    gray = rgb.mean(axis=2)
    py, ey = lattice(gray, 0)
    px, ex = lattice(gray, 1)
    py, px = py / SUBDIV, px / SUBDIV
    cy, cx = (ey + py / 2) % py, (ex + px / 2) % px
    ys = np.arange(cy, rgb.shape[0], py)
    xs = np.arange(cx, rgb.shape[1], px)
    r = max(1, int(min(px, py) * 0.25))
    out = np.zeros((len(ys), len(xs), 4), np.uint8)
    for gy, y in enumerate(ys):
        for gx, x in enumerate(xs):
            y, x = int(round(y)), int(round(x))
            m = fg[max(0, y - r):y + r + 1, max(0, x - r):x + r + 1]
            if m.size == 0 or m.mean() < 0.5:
                continue
            p = rgb[max(0, y - r):y + r + 1, max(0, x - r):x + r + 1][m]
            out[gy, gx, :3] = np.median(p, axis=0).astype(np.uint8)
            out[gy, gx, 3] = 255
    art = Image.fromarray(out, "RGBA")
    art = art.crop(art.getbbox())
    print(f"native pixel {px:.2f}x{py:.2f}px -> art grid {art.width}x{art.height}")
    return art


def main():
    src = np.array(Image.open(os.path.join(HERE, "icon_source.png")).convert("RGB")).astype(np.int16)
    fg = ~background_mask(src)
    art = snap(src, fg)
    art.save(os.path.join(HERE, "icon_pixels.png"))

    # 1024 master: art at the largest integer scale that fits the Apple icon grid, centred.
    cell = max(1, TARGET // max(art.width, art.height))
    w, h = art.width * cell, art.height * cell
    master = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
    master.alpha_composite(art.resize((w, h), Image.NEAREST), ((1024 - w) // 2, (1024 - h) // 2))
    master.save(os.path.join(HERE, "AppIcon_1024.png"))

    iconset = os.path.join(HERE, "AppIcon.iconset")
    os.makedirs(iconset, exist_ok=True)
    for base in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            px = base * scale
            # Large sizes keep hard pixel blocks; tiny sizes are box-filtered for legibility.
            img = master.resize((px, px), Image.NEAREST if px >= 256 else Image.BOX)
            name = f"icon_{base}x{base}{'@2x' if scale == 2 else ''}.png"
            img.save(os.path.join(iconset, name))
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", os.path.join(HERE, "AppIcon.icns")], check=True)
    shutil.rmtree(iconset)
    print("wrote", os.path.join(HERE, "AppIcon.icns"))


if __name__ == "__main__":
    main()
