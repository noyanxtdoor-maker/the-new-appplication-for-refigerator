#!/usr/bin/env python
"""ASCII-render a screenshot region to read text."""
import sys
from PIL import Image

path = sys.argv[1] if len(sys.argv) > 1 else r'C:/Users/sherl/AppData/Local/Temp/nexttransfer-walk/02_fresh.png'
x0, x1 = 220, 850
y0, y1 = 770, 1070
img = Image.open(path).convert('RGB')

# Render every 2px horizontally as a char
for y in range(y0, y1, 2):
    line = ''
    for x in range(x0, x1, 2):
        r, g, b = img.getpixel((x, y))
        # yellow text pixels
        if r > 200 and g > 200 and b < 160:
            line += '#'
        elif r > 100 and g < 80 and b < 80:
            line += '.'
        else:
            line += ' '
    print(f'{y:4d} {line}')
