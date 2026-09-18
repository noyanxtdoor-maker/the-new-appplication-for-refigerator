#!/usr/bin/env python
"""Render each text line's glyphs as ASCII for manual reading."""
import sys
from PIL import Image

path = sys.argv[1] if len(sys.argv) > 1 else r'C:/Users/sherl/AppData/Local/Temp/nexttransfer-walk/02_fresh.png'
lines = [
    (776, 818, 236, 780),
    (824, 858, 236, 780),
    (872, 914, 236, 780),
    (920, 962, 236, 780),
    (966, 1002, 236, 780),
    (1014, 1058, 236, 780),
]
img = Image.open(path).convert('RGB')

for li, (y0, y1, x0, x1) in enumerate(lines):
    print(f'\n========== LINE {li + 1} (y {y0}-{y1}) ==========')
    mask = [[0] * (x1 - x0) for _ in range(y1 - y0)]
    for y in range(y0, y1):
        for x in range(x0, x1):
            r, g, b = img.getpixel((x, y))
            if r > 180 and g > 180 and b < 180:
                mask[y - y0][x - x0] = 1
    cols_with_ink = [any(mask[y][i] for y in range(y1 - y0)) for i in range(x1 - x0)]
    glyphs = []
    in_glyph = False
    start = 0
    for i, has in enumerate(cols_with_ink):
        if has and not in_glyph:
            in_glyph = True
            start = i
        elif not has and in_glyph:
            if i - start >= 2:
                glyphs.append((x0 + start, x0 + i))
            in_glyph = False
    if in_glyph:
        glyphs.append((x0 + start, x1))

    for gi, (gx0, gx1) in enumerate(glyphs):
        if gx1 - gx0 < 2:
            continue
        rows = []
        for y in range(y0, y1, 2):
            line = ''
            for x in range(gx0, gx1):
                r, g, b = img.getpixel((x, y))
                line += '#' if (r > 180 and g > 180 and b < 180) else ' '
            rows.append(line.rstrip())
        print(f'[g{gi}]', ' | '.join(rows))
