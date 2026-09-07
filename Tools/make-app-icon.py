#!/usr/bin/env python3
"""Builds HardwareSentry/Resources/AppIcon.icns from Icons/AppIcon-source.png.

    python3 Tools/make-app-icon.py

The source artwork is full-bleed on a near-black ground, which is not how a macOS icon
is shaped: shipped as-is it would sit in the Dock as a square, noticeably larger than
every icon beside it. So the plate is cropped out of it, masked to the superellipse
macOS actually uses (a squircle, not a plain rounded rectangle), and centred at 824 in a
1024 canvas — the proportions macOS draws app icons at, which is what makes it line up
with its neighbours.

Run this after replacing the source artwork; nothing runs it automatically.
"""
from PIL import Image, ImageDraw
import os, subprocess, shutil, tempfile

SRC = "Icons/AppIcon-source.png"
WORK = tempfile.mkdtemp(prefix="hs-appicon-")
ICONSET = os.path.join(WORK, "AppIcon.iconset")

# The artwork is full-bleed on a near-black ground; this is the plate inside it.
BBOX = (54, 45, 1200, 1208)
PLATE = 824          # macOS draws the icon plate at 824 inside a 1024 canvas
CANVAS = 1024
SS = 4               # supersample, for a clean mask edge

im = Image.open(SRC).convert("RGB")
cx, cy = (BBOX[0] + BBOX[2]) / 2, (BBOX[1] + BBOX[3]) / 2
side = round(((BBOX[2] - BBOX[0]) + (BBOX[3] - BBOX[1])) / 2)
half = side / 2
art = im.crop((round(cx - half), round(cy - half), round(cx + half), round(cy + half)))
art = art.resize((PLATE * SS, PLATE * SS), Image.LANCZOS).convert("RGBA")

# macOS's rounded-rect is a superellipse, not a plain rounded rectangle.
N = 5.0
r = PLATE * SS / 2
mask = Image.new("L", (PLATE * SS, PLATE * SS), 0)
px = mask.load()
for y in range(PLATE * SS):
    dy = abs((y + 0.5) - r) / r
    dyn = dy ** N
    if dyn >= 1.0:
        continue
    # solve |dx|^N = 1 - |dy|^N  ->  dx = (1 - dyn) ** (1/N)
    dx = (1.0 - dyn) ** (1.0 / N)
    x0 = int(round(r - dx * r)); x1 = int(round(r + dx * r))
    for x in range(max(0, x0), min(PLATE * SS, x1)):
        px[x, y] = 255

art.putalpha(mask)
plate = art.resize((PLATE, PLATE), Image.LANCZOS)

canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
off = (CANVAS - PLATE) // 2
canvas.alpha_composite(plate, (off, off))
canvas.save(os.path.join(WORK, "AppIcon-1024.png"))

shutil.rmtree(ICONSET, ignore_errors=True)
os.makedirs(ICONSET)
for size in (16, 32, 128, 256, 512):
    canvas.resize((size, size), Image.LANCZOS).save(f"{ICONSET}/icon_{size}x{size}.png")
    canvas.resize((size * 2, size * 2), Image.LANCZOS).save(f"{ICONSET}/icon_{size}x{size}@2x.png")
subprocess.run(["iconutil", "-c", "icns", ICONSET, "-o", os.path.join(WORK, "AppIcon.icns")], check=True)
dest = "HardwareSentry/Resources/AppIcon.icns"
shutil.copyfile(os.path.join(WORK, "AppIcon.icns"), dest)
print("wrote", dest, os.path.getsize(dest), "bytes")
