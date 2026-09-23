#!/bin/bash
# Real-terminal repro: "sometimes, sending a prompt removes the line above
# the prompt". Drives 3code inside a real xterm under Xvfb, screenshots each
# settled turn, OCRs the shots, and builds a marker-survival matrix: the
# echo of turn T, once on screen, must stay on screen (unless the screen
# scrolled, detected by losing the 3code banner).
#
# Usage: xterm_submit_repro.sh [turns] [iterations] [typing-delay-ms]
set -u
cd "$(dirname "$0")/../.."
BIN=$(ls build/3code_real_* | grep -v nimcache | head -1)
TURNS=${1:-12}
ITERS=${2:-2}
TYPEDELAY=${3:-40}
OUT=/tmp/xtrepro
rm -rf "$OUT"; mkdir -p "$OUT"

pkill -f "Xvfb :99" 2>/dev/null
pkill xterm 2>/dev/null
sleep 0.5
Xvfb :99 -screen 0 1024x768x24 >/dev/null 2>&1 &
XVFB=$!
sleep 1
export DISPLAY=:99

python3 tools/sse_drip_mock.py 4789 "$OUT/requests.log" > "$OUT/server.url" &
MOCK=$!
sleep 0.5
URL=$(cat "$OUT/server.url")

for iter in $(seq 1 "$ITERS"); do
  ROOT="$OUT/run$iter"
  mkdir -p "$ROOT/run" "$ROOT/xdg/3code" "$ROOT/tmp" "$OUT/shots$iter"
  cat > "$ROOT/xdg/3code/config" <<CFG
[settings]
current = "mock.glm"

[provider]
name = "mock"
url = "$URL"
key = "mock"
family = "glm"
models = "glm"
reasoning = on
CFG
  cat > "$ROOT/wrap.sh" <<WRAP
#!/bin/sh
HOME="$ROOT" XDG_CONFIG_HOME="$ROOT/xdg" XDG_DATA_HOME="$ROOT/data" \\
XDG_CACHE_HOME="$ROOT/xdg/cache" TMPDIR="$ROOT/tmp" \\
THREECODE_WALKUP_LOG="$OUT/walkup$iter.log" \\
script -q -f -c "$OUT/appbin -x -i" "$OUT/typescript$iter" 2>"$OUT/app$iter.err"
echo "exit=$?" > "$OUT/exit$iter.txt"
exec sleep 60
WRAP
  cp "$PWD/build/3code_real_diag" "$OUT/appbin"
  chmod +x "$ROOT/wrap.sh"
  xterm -geometry 100x30 -fs 12 -e "$ROOT/wrap.sh" &
  APP=$!
  sleep 2.5
  WID=""
  for cand in $(xdotool search --class xterm 2>/dev/null); do
    if xdotool getwindowname "$cand" >/dev/null 2>&1; then WID=$cand; fi
  done
  if [ -z "$WID" ]; then echo "iter $iter: no xterm window"; break; fi
  xdotool windowfocus "$WID" 2>/dev/null
  sleep 0.3
  import -window "$WID" "$OUT/shots$iter/000-start.png"

  # Deterministic pseudo-random waits that straddle the turn-end window
  # (~0.6-1.2s after Return on this drip cadence): Enter sometimes lands
  # right on the endTurn repaint, sometimes mid-stream, sometimes at idle.
  WAITS="0.15 0.2 0.18 0.25 0.15 0.22 0.19 0.16 0.24 0.2 0.17 0.23 0.15 0.21 0.18 0.2"
  i=0
  for t in $(seq 1 "$TURNS"); do
    w=$(echo $WAITS | cut -d" " -f$(( (i % 16) + 1 )))
    i=$((i+1))
    sleep "$w"
    import -window "$WID" "$OUT/shots$iter/$(printf %03d $t)-settled.png"
    # Prompt lengths straddling the wrap boundary at 100 cols: short,
    # exactly-full-row, one-past, two rows, five rows.
    case $(( (t - 1) % 5 )) in
      0) P="go number $t" ;;
      1) P="go number $t $(python3 -c "print('ab '*46, end='')") xy" ;;
      2) P="go number $t $(python3 -c "print('ab '*47, end='')") xy" ;;
      3) P="go number $t $(python3 -c "print('cd '*96, end='')") xy" ;;
      4) P="go number $t $(python3 -c "print('ef '*240, end='')") xy" ;;
    esac
    xdotool type --window "$WID" --delay "$TYPEDELAY" "$P"
    sleep 0.5
    xdotool key --window "$WID" Return
  done
  sleep 4
  import -window "$WID" "$OUT/shots$iter/999-final.png"
  kill $APP 2>/dev/null
  wait $APP 2>/dev/null
done

kill $MOCK $XVFB 2>/dev/null

echo "== survival matrix =="
for iter in $(seq 1 "$ITERS"); do
  python3 - "$OUT/shots$iter" "$TURNS" <<'PY'
import subprocess, sys, glob, os, re
shots = sorted(glob.glob(os.path.join(sys.argv[1], "*.png")))
turns = int(sys.argv[2])
def ocr(p):
    subprocess.run(["convert", p, "-resize", "200%", "-colorspace", "Gray",
                    "-sharpen", "0x1", "/tmp/up.png"], check=False,
                   capture_output=True)
    r = subprocess.run(["tesseract", "/tmp/up.png", "stdout", "--psm", "6"],
                       capture_output=True, text=True)
    return r.stdout
# markers: "go number N" with fuzzy OCR of digits; use word-run heuristics:
# any line containing "number" plus a digit sequence.
def markers(text):
    found = set()
    for line in text.splitlines():
        if "number" in line.lower():
            for tok in re.findall(r"\d+", line):
                found.add(int(tok))
    return found
seen = {}   # turn -> shot index where its echo last appeared
scrolled_at = None
shots_txt = []
for i, p in enumerate(shots):
    t = ocr(p)
    shots_txt.append((i, p, t))
    if "3code" not in t and scrolled_at is None:
        scrolled_at = i
report = []
for turn in range(1, turns + 1):
    present = [i for i, p, t in shots_txt if turn in markers(t)]
    if not present:
        # turns appearing only after scroll are untrackable, not lost
        report.append(f"turn {turn}: never-on-ocr (scrolled={scrolled_at})")
        continue
    first = present[0]
    missing = []
    for i, p, t in shots_txt:
        if i <= first: continue
        if scrolled_at is not None and i >= scrolled_at: break
        if turn not in markers(t):
            if len(markers(t)) > 0:
                missing.append(os.path.basename(p))
    if missing:
        report.append(f"turn {turn}: seen at shot {first}, MISSING in " +
                      ", ".join(missing[:4]))
    else:
        report.append(f"turn {turn}: ok (first shot {first})")

# Structural check: between two consecutive echo rows there must be answer
# content (>=1 row) plus a blank separator; adjacent echoes or an echo
# directly under an answer with no blank mean a row was eaten at commit.
for i, p, t in shots_txt:
    lines = [l.strip() for l in t.splitlines()]
    echoes = [(idx, l) for idx, l in enumerate(lines)
              if "number" in l.lower() and re.search(r"\d+", l)]
    for a in range(1, len(echoes)):
        i0, l0 = echoes[a - 1]
        i1, l1 = echoes[a]
        # only adjacent-ish pairs on the same screen; ignore a wrapped pair
        # (echo continuation lines end with the digit, first row has 'go')
        between = [x for x in lines[i0 + 1:i1] if x]
        n0 = set(re.findall(r"\d+", l0))
        n1 = set(re.findall(r"\d+", l1))
        if len(n0 & n1):  # same echo wrapped to two rows: not a pair
            continue
        if len(between) < 2:
            report.append(f"STRUCT {os.path.basename(p)}: echoes "
                          f"'{l0}' and '{l1}' have {len(between)} "
                          "content rows between them")
print("\n".join(report))
bad = [r for r in report if "MISSING" in r or "STRUCT" in r]
sys.exit(1 if bad else 0)
PY
  [ $? -ne 0 ] && echo "ITER $iter: LINE LOSS DETECTED"
done
echo "done"
