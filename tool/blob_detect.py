#!/usr/bin/env python
"""Detect colored blobs in the timeline region and report their boxes."""
import sys
from PIL import Image

path = sys.argv[1] if len(sys.argv) > 1 else r'C:/Users/sherl/AppData/Local/Temp/nexttransfer-walk/02_fresh.png'
img = Image.open(path).convert('RGB')
w, h = img.size

# Timeline body region (below date strip, above bottom nav)
y0, y1 = 440, 2070
x0, x1 = 36, 1044

# Classify: background is ~#0D0E10; find everything else
from collections import defaultdict
blobs = defaultdict(list)  # color -> list of (x, y)
for y in range(y0, y1, 2):
    for x in range(x0, x1, 2):
        c = img.getpixel((x, y))
        if c == (13, 14, 16) or c == (0, 0, 0):
            continue
        blobs[c].append((x, y))

print('== non-background colors (count) ==')
for color, pts in sorted(blobs.items(), key=lambda kv: -len(kv[1]))[:15]:
    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]
    print(f'  #{color[0]:02X}{color[1]:02X}{color[2]:02X}  n={len(pts):5d}  x[{min(xs)},{max(xs)}] y[{min(ys)},{max(ys)}]')
