#!/usr/bin/env python
"""Locate pixels of a target hue (pink accent) in a screenshot and print blob boxes.

Usage: python tool/find_blob.py <png> [min_r] [min_g] [min_b] [max_b]
Default: pink accent (r high, g mid-low, b low) on dark background.
"""
import sys
from PIL import Image

path = sys.argv[1] if len(sys.argv) > 1 else '/tmp/nt.png'
min_r = int(sys.argv[2]) if len(sys.argv) > 2 else 170
min_g = int(sys.argv[3]) if len(sys.argv) > 3 else 60
min_b = int(sys.argv[4]) if len(sys.argv) > 4 else 60
max_b = int(sys.argv[5]) if len(sys.argv) > 5 else 130

img = Image.open(path).convert('RGB')
w, h = img.size
px = img.load()

cols = {}
for x in range(w):
    for y in range(h):
        r, g, b = px[x, y]
        if r >= min_r and g >= min_g and b <= max_b:
            cols.setdefault(x, [y, y])
            cols[x][0] = min(cols[x][0], y)
            cols[x][1] = max(cols[x][1], y)

if not cols:
    print('NO MATCH')
    sys.exit(0)

# Cluster contiguous x-runs into blobs.
xs = sorted(cols)
blobs = []
cur = [xs[0]]
for x in xs[1:]:
    if x - cur[-1] <= 12:
        cur.append(x)
    else:
        blobs.append(cur)
        cur = [x]
blobs.append(cur)

for b in blobs:
    x0, x1 = b[0], b[-1]
    y0 = min(cols[x][0] for x in b)
    y1 = max(cols[x][1] for x in b)
    if (x1 - x0) * (y1 - y0) < 400:  # ignore tiny specks
        continue
    print(f'blob x={x0}-{x1} y={y0}-{y1} w={x1-x0+1} h={y1-y0+1} cx={(x0+x1)//2} cy={(y0+y1)//2}')
