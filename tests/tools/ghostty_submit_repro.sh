#!/bin/bash
# Real-terminal repro under GHOSTTY (the surface the user reports from):
# "sometimes, sending a prompt removes the line above the prompt".
# Runs 3code inside ghostty on Xvfb :99, types multi-turn submits (idle,
# queued mid-turn, wrapped), screenshots the actual ghostty window, and
# captures the app->terminal bytes via script(1) for differential replay
# through the ttty grid. Any per-row divergence between the ghostty
# screenshot and the ttty replay of the same bytes is a model-vs-physical
# desync: the bug class the user sees.
#
# The user's own ghostty runs on the real display; everything here is
# scoped to DISPLAY=:99 and a fixture XDG_CONFIG_HOME, and
# --gtk-single-instance=false keeps us off their instance.
#
# Usage: ghostty_submit_repro.sh [turns] [iterations] [typing-delay-ms]
set -u
cd "$(dirname "$0")/../.."
BIN=${BIN:-build/3code_real_diag}
TURNS=${1:-12}
ITERS=${2:-2}
TYPEDELAY=${3:-35}
OUT=/tmp/ghrepro
rm -rf "$OUT"; mkdir -p "$OUT"

pkill -f "Xvfb :99" 2>/dev/null
sleep 0.3
Xvfb :99 -screen 0 1200x900x24 >/dev/null 2>&1 &
XVFB=$!
sleep 1
export DISPLAY=:99
openbox >/dev/null 2>&1 &
WM=$!
sleep 1

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
script -q -f -c "$OUT/appbin$iter -x -i" "$OUT/typescript$iter" 2>"$OUT/app$iter.err"
echo "exit=$?" > "$OUT/exit$iter.txt"
exec sleep 60
WRAP
  cp "$PWD/$BIN" "$OUT/appbin$iter"
  chmod +x "$ROOT/wrap.sh"
  env -u WAYLAND_DISPLAY -u XDG_SESSION_TYPE GDK_BACKEND=x11 \
    ghostty --gtk-single-instance=false --shell-integration=none \
    --font-size=12 --background=#ffffff --foreground=#000000 \
    --gtk-titlebar=false --window-padding-x=0 --window-padding-y=0 \
    --window-width=100 --window-height=30 -e "$ROOT/wrap.sh" \
    >"$OUT/ghostty$iter.log" 2>&1 &
  GH=$!
  sleep 3
  WID=""
  for cand in $(xdotool search --class ghostty 2>/dev/null); do
    if xdotool getwindowname "$cand" >/dev/null 2>&1; then WID=$cand; fi
  done
  if [ -z "$WID" ]; then
    echo "iter $iter: no ghostty window on :99 (log follows)"
    tail -5 "$OUT/ghostty$iter.log"
    kill "$GH" 2>/dev/null; wait "$GH" 2>/dev/null
    break
  fi
  echo "iter $iter: ghostty window $WID"
  xdotool windowfocus "$WID" 2>/dev/null
  sleep 0.5
  xdotool getwindowgeometry --shell "$WID" > "$OUT/shots$iter/geometry.txt"
  import -window "$WID" "$OUT/shots$iter/000-start.png"

  # Waits straddle the turn-end window (~0.6-1.2s post-Return on this drip
  # cadence) so some Enters land mid-stream (queued deferred submits).
  WAITS="0.15 0.2 0.18 0.25 0.15 0.22 0.19 0.16 0.24 0.2 0.17 0.23 0.15 0.21 0.18 0.2"
  snap() { # $1 = tag: screenshot + byte-stream prefix snapshot together
    import -window "$WID" "$OUT/shots$iter/$1.png"
    cp "$OUT/typescript$iter" "$OUT/shots$iter/$1.ts"
  }
  i=0
  for t in $(seq 1 "$TURNS"); do
    w=$(echo $WAITS | cut -d" " -f$(( (i % 16) + 1 )))
    i=$((i+1))
    sleep "$w"
    snap "$(printf %03d $t)-pre"
    # lengths straddling the 100-col wrap boundary: short, exactly-full,
    # one-past, two rows, five rows; every 5th turn recalls history (Up).
    case $(( (t - 1) % 5 )) in
      0) P="go number $t" ;;
      1) P="go number $t $(python3 -c "print('ab '*46, end='')") xy" ;;
      2) P="go number $t $(python3 -c "print('ab '*47, end='')") xy" ;;
      3) P="go number $t $(python3 -c "print('cd '*96, end='')") xy" ;;
      4) P="" ;;  # history recall: Up + Enter
    esac
    if [ -n "$P" ]; then
      xdotool type --window "$WID" --delay "$TYPEDELAY" "$P"
    else
      xdotool key --window "$WID" Up
      sleep 0.4
    fi
    sleep 0.5
    xdotool key --window "$WID" Return
    sleep 0.6
    snap "$(printf %03d $t)-post"
  done
  sleep 4
  snap 999-final
  kill "$GH" 2>/dev/null
  wait "$GH" 2>/dev/null
done

kill $MOCK $WM $XVFB 2>/dev/null

echo "== differential: ghostty screenshot vs ttty replay of same bytes =="
for iter in $(seq 1 "$ITERS"); do
  [ -f "$OUT/typescript$iter" ] || continue
  for snap in "$OUT/shots$iter"/*.png; do
    tag=$(basename "$snap" .png)
    [ -f "$OUT/shots$iter/$tag.ts" ] || continue
    python3 tools/ts_strip.py "$OUT/shots$iter/$tag.ts" > "$OUT/bytes.tmp"
    ./build/replay_ttty "$OUT/bytes.tmp" 100 30 > "$OUT/ttty.tmp"
    echo "-- iter $iter $tag"
    python3 tools/ghostty_mask_diff.py "$snap" "$OUT/ttty.tmp" 30 \
      || echo "   ^^ ITER $iter $tag: DIVERGENCE"
  done
done
echo done
