#!/usr/bin/env python3
"""Compare a ghostty screenshot against the ttty replay grid of the same
byte stream, per terminal row: does a row hold content in the physical
terminal but not in the model (or vice versa)? Any mismatch after best
alignment is a model-vs-physical desync.

The screenshot includes GTK client-side decorations (title band, possible
padding/shadows) above/below the cell grid, so we search over the grid's
top offset and cell height and score agreement with the ttty content
mask. x sampling skips only the outer 8px per side so short left-aligned
rows are seen and window borders are excluded.

Usage: ghostty_mask_diff.py <shot.png> <ttty_grid.txt> <grid rows>
"""
import sys
from PIL import Image

def ttty_mask(path):
    mask = []
    for line in open(path):
        line = line.rstrip("\n")
        if "|" not in line:
            continue
        seg = line.split("|", 1)[1]
        content = seg.rsplit("|", 1)[0]
        mask.append(1 if content.strip() else 0)
    return mask

def main():
    shot, grid, rows = sys.argv[1], sys.argv[2], int(sys.argv[3])
    want = ttty_mask(grid)[:rows]
    while len(want) < rows:
        want.append(0)
    img = Image.open(shot).convert("L")
    w, h = img.size
    px = img.load()
    x0, x1 = 8, w - 8
    dark = []
    for y in range(h):
        n = 0
        for x in range(x0, x1, 2):
            if px[x, y] < 205:
                n += 1
        dark.append(n)

    best = None
    for ch_i in range(24, 90):            # cell height in half-pixels
        ch = ch_i / 2.0
        grid_h = ch * rows
        if grid_h > h:
            continue
        for top in range(0, min(140, int(h - grid_h)) + 1):
            mask = []
            for r in range(rows):
                y0 = int(top + r * ch)
                y1 = int(top + (r + 1) * ch)
                n = max(dark[y0:max(y0 + 1, y1)])
                mask.append(1 if n > 3 else 0)
            agree = sum(1 for a, b in zip(mask, want) if a == b)
            if best is None or agree > best[0]:
                best = (agree, top, ch, mask)
    agree, top, ch, got = best
    diffs = [(r, want[r], got[r]) for r in range(rows) if want[r] != got[r]]
    print(f"alignment: top={top} cellh={ch} agree={agree}/{rows} "
          f"({'perfect' if not diffs else 'DIVERGENT'})")
    print("ttty: " + "".join(str(b) for b in want))
    print("shot: " + "".join(str(b) for b in got))
    for r, wv, gv in diffs:
        kind = ("row has content ONLY in ghostty (model thinks blank)"
                if gv else
                "row has content ONLY in ttty model (ghostty blank/scrolled)")
        print(f"  row {r}: {kind}")
    sys.exit(1 if diffs else 0)

main()
