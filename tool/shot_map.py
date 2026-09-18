#!/usr/bin/env python
"""Coarse ASCII map of the screenshot: prints a char per ~40px cell with hex color."""
import sys
from PIL import Image

path = sys.argv[1] if len(sys.argv) > 1 else r'C:/Users/sherl/AppData/Local/Temp/nexttransfer-walk/01_current.png'
img = Image.open(path).convert('RGB')
w, h = img.size
step = 36
rows = []
for y in range(0, h, step):
    line = []
    for x in range(0, w, step):
        r, g, b = img.getpixel((min(x, w - 1), min(y, h - 1)))
        line.append(f'#{r:02X}{g:02X}{b:02X}'[:6])
    rows.append(' '.join(line))
print(f'coarse map {w//step}x{h//step} (each cell {step}px)')
for i, row in enumerate(rows):
    print(f'{i*step:4d} {row}')
