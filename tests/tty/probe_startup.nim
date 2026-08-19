## Timing probe: spawn a real 3code binary under ConPTY, measure
## wall time from CreateProcess to the first output byte (welcome
## screen), and print the child's -d:startupTrace stderr (which the
## ConPTY merges into stdout). Windows-only by construction (ConPTY).
import std/[os, strutils, times]
import ../tty_expect

let bin = paramStr(1)
let t0 = epochTime()
let s = newTtySession(bin)
var firstByteMs = -1
let deadline = epochTime() + 60.0
while epochTime() < deadline and not s.exited:
  if s.pollOnce(25, recordIdleFrame = false):
    firstByteMs = int((epochTime() - t0) * 1000)
    break
if firstByteMs < 0:
  echo "TIMEOUT: no output within 60s"
  s.close()
  quit 1
# Drain briefly to collect the full welcome + trace lines.
s.drain(50)
echo "first-output-byte: ", firstByteMs, " ms"
echo "---- raw (trace lines) ----"
for line in s.raw.splitLines():
  if "[trace]" in line:
    echo line
echo "---- screen ----"
for row in s.rows():
  echo row
s.close()
