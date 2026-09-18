#!/usr/bin/env python
"""Find distinct color regions (event blocks) in the timeline area of a screenshot."""
import sys
from collections import Counter
from PIL import Image

path = sys.argv[1] if len(sys.argv) > 1 else r'C:/Users/sherl/AppData/Local/Temp/nexttransfer-walk/01_current.png'
img = Image.open(path).convert('RGB')
w, h = img.size
print(f'image {w}x{h}')

# Timeline region: below date strip (~435) above bottom nav (~1848)
# Downsample: sample every 8 px
region = []
for y in range(440, 1840, 8):
    for x in range(60, 1040, 8):
        region.append(img.getpixel((x, y)))

cnt = Counter(region)
print('== top distinct colors in timeline region ==')
for color, n in cnt.most_common(25):
    print(f'  #{color[0]:02X}{color[1]:02X}{color[2]:02X}  {n:5d}  ({n*100//len(region)}%)')
