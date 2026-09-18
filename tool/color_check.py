import sys
from PIL import Image
from collections import Counter

path = sys.argv[1]
img = Image.open(path).convert("RGB")
w, h = img.size
print(f"size: {w}x{h}")

y0 = int(h * 0.25)
y1 = int(h * 0.97)
x0 = int(w * 0.03)
x1 = int(w * 0.97)
c = Counter()
for y in range(y0, y1, 8):
    for x in range(x0, x1, 8):
        c[img.getpixel((x, y))] += 1
print("top colors (timeline):")
for k, v in c.most_common(8):
    print("  #%02X%02X%02X" % k, v)
red = sum(v for k, v in c.items() if k[0] > 120 and k[1] < 60 and k[2] < 60)
print("RED-ERROR-PIXELS:", red)
