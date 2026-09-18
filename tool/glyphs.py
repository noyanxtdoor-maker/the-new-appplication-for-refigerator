#!/usr/bin/env python
"""Segment yellow text into glyphs and render each at 2x for reading."""
import sys
from PIL import Image

path = sys.argv[1] if len(sys.argv) > 1 else r'C:/Users/sherl/AppData/Local/Temp/nexttransfer-walk/02_fresh.png'
y0, y1 = 774, 818  # line 1
x0, x1 = 240, 760
img = Image.open(path).convert('RGB')

# Build a binary mask of yellow glyph pixels
mask = [[0] * (x1 - x0) for _ in range(y1 - y0)]
for y in range(y0, y1):
    for x in range(x0, x1):
        r, g, b = img.getpixel((x, y))
        if r > 180 and g > 180 and b < 180:
            mask[y - y0][x - x0] = 1

# Find column runs
cols_with_ink = [any(mask[y][i] for y in range(y1 - y0)) for i in range(x1 - x0)]

# Segment into glyphs: runs of ink columns separated by >=3 blank columns
glyphs = []
in_glyph = False
start = 0
for i, has in enumerate(cols_with_ink):
    if has and not in_glyph:
        in_glyph = True
        start = i
    elif not has and in_glyph:
        if i - start >= 2:  # at least 2px wide glyph
            glyphs.append((x0 + start, x0 + i))
        in_glyph = False
if in_glyph:
    glyphs.append((x0 + start, x1))

print(f'== {len(glyphs)} glyphs found ==')
for gi, (gx0, gx1) in enumerate(glyphs):
    if gx1 - gx0 < 2:
        continue
    print(f'--- glyph {gi}: x {gx0}-{gx1} (w={gx1-gx0}) ---')
    for y in range(y0, y1, 2):
        line = ''
        for x in range(gx0, gx1):
            r, g, b = img.getpixel((x, y))
            if r > 180 and g > 180 and b < 180:
                line += '#'
            else:
                line += ' '
        print(f'  {y:4d}|{line.rstrip()}')
