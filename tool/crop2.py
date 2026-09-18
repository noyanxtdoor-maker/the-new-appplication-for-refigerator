#!/usr/bin/env python
"""Crop region, isolate bright (yellow) glyphs, upscale, save."""
import sys
from PIL import Image

path = sys.argv[1]
out = sys.argv[2]
box = tuple(int(v) for v in sys.argv[3].split(','))
img = Image.open(path).convert('RGB')
crop = img.crop(box)
px = crop.load()
for y in range(crop.height):
    for x in range(crop.width):
        r, g, b = px[x, y]
        if r > 150 and g > 150 and b < 180:
            px[x, y] = (255, 255, 255)
        else:
            px[x, y] = (0, 0, 0)
crop = crop.resize((crop.width * 3, crop.height * 3), Image.LANCZOS)
crop.save(out)
print(f'saved {out} {crop.size}')
