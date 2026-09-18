#!/usr/bin/env python
"""Analyze the yellow band at y 770-1060: horizontal strips to see pattern."""
import sys
from PIL import Image

path = sys.argv[1] if len(sys.argv) > 1 else r'C:/Users/sherl/AppData/Local/Temp/nexttransfer-walk/02_fresh.png'
img = Image.open(path).convert('RGB')

print('== horizontal strips (x from 200 to 900) ==')
for y in range(770, 1065, 12):
    colors = []
    last = None
    count = 0
    for x in range(200, 900):
        c = img.getpixel((x, y))
        if c != last:
            if last is not None:
                colors.append((count, last))
            last = c
            count = 1
        else:
            count += 1
    colors.append((count, last))
    desc = ' '.join(f'{n}x#{c[0]:02X}{c[1]:02X}{c[2]:02X}' for n, c in colors if n > 1)
    print(f'y={y}: {desc[:150]}')
