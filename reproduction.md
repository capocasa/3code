# Reproduction: missing blank row after first submit

## The bug

After submitting the first prompt, the row that held the `○0%` token bar
collapses away instead of being left as an empty line. The committed echo
moves up one row, directly under the hint, instead of leaving a blank row
between the hint and the echo.

Actual (broken):

```
  type a prompt. :help for commands. :q or Ctrl-D to exit,
❯ this is a test just reply
  ○3% ↑4.7k ↓6 1s
  ○3%
❯ |
```

Expected (correct):

```
  type a prompt. :help for commands. :q or Ctrl-D to exit,
                                                              <- blank row (was ○0% bar)
❯ this is a test just reply
  ○3% ↑4.7k ↓6 1s
  ○3%
❯ |
```

The blank row is gone. That's the whole bug.

## Environment that reproduces it

- Real xterm on Xvfb `:88` (`Xvfb :88 -screen 0 1400x900x24`).
- 119 cols x 24 rows (`xterm -geometry 119x24+0+0`).
- `setsid xterm ... -e bash -c ...` (setsid required under the sandbox; bare
  xterm dies with `open ttydev: Permission denied`).
- App launched with stdin from a FIFO so it stays alive for per-keystroke
  typing. Do NOT use the `-S/3` slave-fd form (renders pure black on this
  Xvfb).
- Config: `/tmp/freshhome/.config/3code/config` (google provider,
  `reasoning = on`). HOME=/tmp/freshhome. Clear
  `rm -f /tmp/freshhome/tmp/3code/dirlock/*.lock` before each run.
- Binary: `~/p/3code/3code` (built from HEAD).

## Harness: `/tmp/hintcheck/fifo_5s.sh`

```bash
#!/bin/bash
BIN="$1"; TAG="${2:-run}"
HOME_D=/tmp/freshhome
FIFO=/tmp/app_fifo_$$
rm -f "$FIFO"; mkfifo "$FIFO"
export PATH=/usr/bin:/bin DISPLAY=:88 HOME=$HOME_D XDG_CONFIG_HOME=$HOME_D/.config
export XDG_DATA_HOME=$HOME_D/data TMPDIR=$HOME_D/tmp TERM=xterm-256color COLORTERM=truecolor LANG=C.UTF-8 USER=$USER
rm -f $HOME_D/tmp/3code/dirlock/*.lock
setsid xterm -geometry 119x24+0+0 -e bash -c "exec 3<>$FIFO; $BIN -x -i < $FIFO 2>&1 | tee /tmp/${TAG}_bytes.log" &
XTPID=$!
sleep 4.5
python3 - "$FIFO" "$TAG" <<'PY'
import os,sys,time,subprocess
fifo,tag=sys.argv[1],sys.argv[2]
e2=dict(os.environ); e2["DISPLAY"]=":88"
def snap(n):
    subprocess.run(["scrot","-a","0,0,1000,500",f"/tmp/{tag}_{n}.png"],env=e2)
fw=os.open(fifo,os.O_WRONLY)
snap("1_idle")
for ch in "this is a test just reply":
    os.write(fw,ch.encode()); time.sleep(0.12)
snap("2_typed")
os.write(fw,b"\r")
time.sleep(5); snap("3_after5s")   # wait 5s so the reply lands before the shot
os.close(fw)
PY
kill $XTPID 2>/dev/null
rm -f "$FIFO"
```

Run: `bash /tmp/hintcheck/fifo_5s.sh /home/carlo/p/3code/3code s3`

Screenshots land in `/tmp/s3_1_idle.png`, `/tmp/s3_2_typed.png`,
`/tmp/s3_3_after5s.png`. App's raw byte stream is `/tmp/s3_bytes.log`.

## CRITICAL timing fact

The screenshot MUST be taken ~5 seconds after Enter, not immediately. The
reply takes a couple seconds to stream back. An immediate post-Enter frame
shows the mid-commit state and is easy to misread. The 5s frame shows the
settled post-submit layout where the missing blank row is visible.

## Viewing / OCR

View: `DISPLAY=:0 feh /tmp/s3_1_idle.png /tmp/s3_2_typed.png /tmp/s3_3_after5s.png`

OCR (dim hint needs invert + upscale + low threshold):

```bash
cd /tmp && python3 - <<'PY'
from PIL import Image, ImageOps
for f in ["s3_1_idle","s3_2_typed","s3_3_after5s"]:
    im = Image.open(f"{f}.png").convert("L")
    im2 = ImageOps.invert(im).resize((im.width*4, im.height*4), Image.LANCZOS)
    im2 = im2.point(lambda p: 255 if p>60 else 0)
    im2.save(f"{f}_big.png")
PY
for f in s3_1_idle s3_2_typed s3_3_after5s; do
  echo "=== $f ==="; tesseract ${f}_big.png stdout --psm 6 2>/dev/null | sed '/^$/d'
done
```

## Root cause (FIXED)

The welcome banner + hint are painted RAW in `display.welcome()`
(src/threecode/display.nim:705) before the input thread and engine frame
model are up, so the engine's `hasScrollback` flag stays false even though
the hint occupies a real row. `writeTranscriptItem`
(src/threecode/engine.nim:674) only prepends the inter-item `\r\n`
separator `if e.hasScrollback`, so the first transcript commit skips it and
the echo lands flush under the hint. Later turns have `hasScrollback=true`
(already set by the first commit), so they separate correctly.

The erase/walk-up geometry was always correct. This is why five prior
geometry patches failed and the DSR probe reported the model internally
consistent: the divergence was the separator GATE, not the geometry.

## Fix

- `termengine.noteScrollbackExists()` (src/threecode/engine.nim) sets
  `hasScrollback = true` without writing bytes.
- Called in src/threecode.nim right after `welcome(prof)`.

Regression test: `tests/tty/test_first_submit_blank_row.nim` (reasoning on
+ off) asserts the echo lands two rows below the hint with a blank row
between.
