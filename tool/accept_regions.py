"""Find rendered event-block rectangles in a planner screenshot and report
their dominant color, bounding box, and pixel area. Used for on-device
visual acceptance of the PMG-parity planner."""
import sys
from PIL import Image

path = sys.argv[1]
img = Image.open(path).convert("RGB")
w, h = img.size
px = img.load()

BG = (13, 14, 16)  # #0D0E10 timeline background
NAV = (16, 17, 19)  # #101113 navigation bar
DATE_STRIP_BG = (16, 17, 19)


def is_background(rgb):
    r, g, b = rgb
    if abs(r - 13) < 10 and abs(g - 14) < 10 and abs(b - 16) < 10:
        return True
    if abs(r - 16) < 8 and abs(g - 17) < 8 and abs(b - 19) < 8:
        return True
    if r < 12 and g < 12 and b < 12:
        return True
    return False


def is_dark_text(rgb):
    r, g, b = rgb
    return r < 90 and g < 90 and b < 90


# Timeline area: below date strip (~y=330), above FAB/nav (~y=2100)
y0, y1 = 380, 2080
x0, x1 = 130, w - 30

visited = set()
regions = []

for y in range(y0, y1, 3):
    for x in range(x0, x1, 3):
        if (x, y) in visited:
            continue
        c = px[x, y]
        if is_background(c) or is_dark_text(c):
            continue
        # BFS flood-fill on the sampled grid
        stack = [(x, y)]
        cells = []
        while stack:
            cx, cy = stack.pop()
            if (cx, cy) in visited:
                continue
            visited.add((cx, cy))
            cc = px[cx, cy]
            if is_background(cc) or is_dark_text(cc):
                continue
            cells.append((cx, cy, cc))
            for dx in (-3, 0, 3):
                for dy in (-3, 0, 3):
                    nx, ny = cx + dx, cy + dy
                    if x0 <= nx < x1 and y0 <= ny < y1 and (nx, ny) not in visited:
                        stack.append((nx, ny))
        if len(cells) < 12:
            continue
        xs = [cx for cx, _, _ in cells]
        ys = [cy for _, cy, _ in cells]
        from collections import Counter
        dom = Counter(cc for _, _, cc in cells).most_common(1)[0][0]
        regions.append(
            (min(xs), min(ys), max(xs), max(ys), len(cells), dom)
        )

# Merge regions whose bounding boxes overlap (sampling splits blocks)
regions.sort(key=lambda r: (r[1], r[0]))
merged = []
for r in regions:
    placed = False
    for i, m in enumerate(merged):
        ox = max(0, min(r[2], m[2]) - max(r[0], m[0]))
        oy = max(0, min(r[3], m[3]) - max(r[1], m[1]))
        if ox > 20 and oy > 20:
            merged[i] = (
                min(r[0], m[0]),
                min(r[1], m[1]),
                max(r[2], m[2]),
                max(r[3], m[3]),
                m[4] + r[4],
                m[5],
            )
            placed = True
            break
    if not placed:
        merged.append(r)

print(f"rendered event blocks: {len(merged)}")
for m in sorted(merged, key=lambda r: r[1]):
    xmin, ymin, xmax, ymax, area, dom = m
    print(
        "  x=%4d-%4d y=%4d-%4d h=%4dpx area=%5d  #%02X%02X%02X"
        % (xmin, xmax, ymin, ymax, ymax - ymin, area, dom[0], dom[1], dom[2])
    )
