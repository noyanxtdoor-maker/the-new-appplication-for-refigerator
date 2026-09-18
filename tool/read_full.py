#!/usr/bin/env python
"""Full-res ASCII render of a region; yellow glyphs -> #, red -> ., else space."""
import sys
from PIL import Image

path = sys.argv[1] if len(sys.argv) > 1 else r'C:/Users/sherl/AppData/Local/Temp/nexttransfer-walk/02_fresh.png'
x0, x1 = 240, 830
y0, y1 = 774, 1060
img = Image.open(path).convert('RGB')

for y in range(y0, y1, 2):
    line = ''
    for x in range(x0, x1):
        r, g, b = img.getpixel((x, y))
        if r > 190 and g > 190 and b < 170:
            line += '#'
        elif r > 100 and g < 70 and b < 70:
            line += '.'
        else:
            line += ' '
    print(f'{y:4d}|{line.rstrip()}')
