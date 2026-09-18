import sys
from PIL import Image

src = sys.argv[1]
dst = sys.argv[2]
x0, y0, x1, y1 = (int(v) for v in sys.argv[3].split(","))
img = Image.open(src).convert("RGB")
crop = img.crop((x0, y0, x1, y1))
crop = crop.resize((crop.width * 3, crop.height * 3), Image.LANCZOS)
crop.save(dst)
print(f"cropped {x0},{y0}-{x1},{y1} -> {dst} ({crop.width}x{crop.height})")
