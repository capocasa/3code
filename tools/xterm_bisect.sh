#!/bin/bash
# Bisect the first byte offset where a real xterm and ttty's grid diverge
# on the same captured byte stream (the model-vs-physical desync point).
# Usage: xterm_bisect.sh <typescript> [steps]
set -u
FILE=${1:-/tmp/xtrepro/typescript1}
STEPS=${2:-24}
OUT=/tmp/xtbisect
rm -rf "$OUT"; mkdir -p "$OUT"
SIZE=$(stat -c %s "$FILE")

pkill -f "Xvfb :99" 2>/dev/null; pkill xterm 2>/dev/null; sleep 0.4
Xvfb :99 -screen 0 1024x768x24 >/dev/null 2>&1 &
XVFB=$!
sleep 1
export DISPLAY=:99

gen_mask() { # $1 = prefix file, $2 = out mask
  xterm -geometry 100x30 -fs 12 -e sh -c "stty -onlcr -echo; cat '$1'; sleep 30" &
  XP=$!
  sleep 1.2
  WID=""
  for cand in $(xdotool search --class xterm 2>/dev/null); do
    xdotool getwindowname "$cand" >/dev/null 2>&1 && WID=$cand
  done
  [ -z "$WID" ] && { echo "nowin"; return; }
  import -window "$WID" "$2.png"
  kill $XP 2>/dev/null; wait $XP 2>/dev/null
  python3 tools/shot_profile.py "$2.png" >/dev/null 2>&1  # warm
  python3 - "$2.png" > "$2.mask" <<'PY'
import sys
from PIL import Image
img = Image.open(sys.argv[1]).convert("L")
w, h = img.size
px = img.load()
rowh = h / 30.0
for r in range(30):
    y0, y1 = int(r * rowh), int((r + 1) * rowh)
    dark = sum(1 for y in range(y0, y1) for x in range(0, w, 2) if px[x, y] < 190)
    print(1 if dark > 2 else 0)
PY
}

for i in $(seq 1 "$STEPS"); do
  off=$(( SIZE * i / STEPS ))
  dd if="$FILE" of="$OUT/p$i" bs=1 count=$off status=none
  gen_mask "$OUT/p$i" "$OUT/m$i" || exit 1
  echo "offset $off mask=$(tr -d '\n' < "$OUT/m$i.mask")"
done
kill $XVFB 2>/dev/null
echo "done; masks in $OUT"
