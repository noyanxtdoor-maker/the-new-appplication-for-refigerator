#!/usr/bin/env python
"""Detailed color analysis of event card regions in a planner screenshot."""
import sys
from PIL import Image

path = sys.argv[1] if len(sys.argv) > 1 else r'C:/Users/sherl/AppData/Local/Temp/nexttransfer-walk/05_planner.png'
img = Image.open(path).convert('RGB')

# Timeline region x=36..1042, y=440..2060
# Sample grid to find distinct card surfaces
from collections import Counter
counts = Counter()
for y in range(470, 2040, 6):
    for x in range(60, 1030, 6):
        c = img.getpixel((x, y))
        counts[c] += 1

print('== distinct colors in timeline (grid 6px) ==')
for c, n in counts.most_common(20):
    if n < 20:
        break
    print(f'  #{c[0]:02X}{c[1]:02X}{c[2]:02X}  {n}')
