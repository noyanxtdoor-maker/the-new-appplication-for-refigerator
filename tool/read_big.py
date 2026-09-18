#!/usr/bin/env python
"""Render the yellow text at 2x horizontal scale, per text line, to read it."""
import sys
from PIL import Image

path = sys.argv[1] if len(sys.argv) > 1 else r'C:/Users/sherl/AppData/Local/Temp/nexttransfer-walk/02_fresh.png'
img = Image.open(path).convert('RGB')

def render_line(y0, y1, x0, x1, label):
    print(f'===== {label} (y {y0}-{y1}) =====')
    # sample every other pixel vertically for a squarer aspect
    for y in range(y0, y1, 2):
        line = ''
        for x in range(x0, x1):
            r, g, b = img.getpixel((x, y))
            if r > 180 and g > 180 and b < 180:
                line += '#'
            elif r > 90 and g < 70 and b < 70:
                line += '.'
            else:
                line += ' '
        print(f'{y:4d}|{line.rstrip()}')

# Text lines identified: ~776-818, 824-856, 872-914, 920-962, 968-1000, 1016-1058
render_line(776, 818, 244, 700, 'LINE 1')
