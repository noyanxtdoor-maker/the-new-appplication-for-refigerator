#!/usr/bin/env python
"""Print color runs down a vertical strip to see block boundaries."""
import sys
from PIL import Image

path = sys.argv[1] if len(sys.argv) > 1 else r'C:/Users/sherl/AppData/Local/Temp/nexttransfer-walk/02_fresh.png'
x = int(sys.argv[2]) if len(sys.argv) > 2 else 540
img = Image.open(path).convert('RGB')
w, h = img.size
print(f'vertical strip at x={x}, from y=440 to y=2100')
last = None
run = 0
start = 0
for y in range(440, 2100, 2):
    c = img.getpixel((x, y))
    if c != last:
        if last is not None:
            print(f'  y={start:4d}-{y-2:4d}  #{last[0]:02X}{last[1]:02X}{last[2]:02X}')
        last = c
        start = y
print(f'  y={start:4d}-{2098:4d}  #{last[0]:02X}{last[1]:02X}{last[2]:02X}')
