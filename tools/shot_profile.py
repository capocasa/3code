#!/usr/bin/env python3
"""Analyze xterm screenshots by per-terminal-row pixel darkness.

Expected settled layout per turn (bottom of each item block):
  A = answer row (bright)   R = receipt row (grey, medium)
  B = blank row (zero)      E = echo row (medium-bright)
and optionally J = the blank row below an echo (must be zero).
Deviations (missing B between R and E, missing R, stray content in B/J)
are the line-eating / stranded-chrome bug classes.
"""
import sys, glob, os, re
from PIL import Image

def profile(path, rows=30, thresh=170):
    img = Image.open(path).convert("L")
    w, h = img.size
    px = img.load()
    rowh = h / rows
    out = []
    for r in range(rows):
        y0, y1 = int(r * rowh), int((r + 1) * rowh)
        dark = sum(1 for y in range(y0, y1) for x in range(0, w, 2)
                   if px[x, y] < thresh)
        out.append(dark)
    return out

def classify(d):
    if d == 0: return "B"          # blank
    if d < 40: return "j"          # stray junk (should be blank)
    if d < 160: return "m"         # medium: receipt or echo
    return "A"                     # bright: answer/banner

def analyze(path):
    p = profile(path)
    sig = "".join(classify(d) for d in p)
    # find echo rows: 'm' preceded by B preceded by m (receipt) preceded by A
    problems = []
    rows = list(sig)
    for i in range(len(rows)):
        if rows[i] == "m":
            # candidate echo: check the rows above
            ctx = sig[max(0, i - 4):i]
            if "AmB" in ctx or ctx.endswith("mB"):
                pass  # receipt+blank above: ok
            elif "AB" in ctx:
                problems.append(f"row {i}: echo with NO receipt above "
                                f"(answer/blank only): {sig[max(0,i-5):i+2]}")
            elif "Am" in ctx and not "AmB" in ctx:
                problems.append(f"row {i}: echo DIRECTLY under receipt "
                                f"(blank eaten): {sig[max(0,i-5):i+2]}")
            elif "AA" in ctx:
                problems.append(f"row {i}: echo DIRECTLY under answer: "
                                f"{sig[max(0,i-5):i+2]}")
    for i, c in enumerate(rows):
        if c == "j":
            problems.append(f"row {i}: stray content on a should-be-blank "
                            f"row (dark={p[i]}): {sig[max(0,i-2):i+2]}")
    return sig, problems

bad = 0
for path in sorted(glob.glob(sys.argv[1])):
    sig, problems = analyze(path)
    print(f"{os.path.basename(path)}: {sig}")
    for pr in problems:
        print(f"    !! {pr}")
        bad += 1
sys.exit(1 if bad else 0)
