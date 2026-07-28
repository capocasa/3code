## Terminal ground-truth probe.
##
## The fat-prompt walk-up model (`walkUp` / `paintedFooterRows` /
## `renderRow`) is internally consistent, but the PTY test harness (ttty)
## interprets captured bytes with the *same* model the code uses to emit
## them. A model-vs-physical desync (wrap-width disagreement, ED0-at-bottom
## semantics) is therefore invisible in every captured frame: the erase
## lands one row into committed scrollback and ttty applies the identical
## wrong assumption, so the frames look perfect.
##
## This module asks the *real* terminal where the cursor actually is (a DSR
## query, `CSI 6 n`, answered with absolute row/col) and logs the model's
## assumed geometry next to it at the moment of an erase. A divergence is
## the smoking gun the harness can never show.
##
## Safety: probing reads stdin, which the persistent input thread also
## reads. We therefore only probe when the input thread is parked — the
## submit / transcript-commit transitions, where the controller owns the
## editor and both reported bugs (line above the prompt vanishing, prompt
## jumping on submit) live. Live-typing repaints are never probed. The
## whole thing is opt-in via `THREECODE_TERMDBG=<path>` and a no-op
## otherwise, and dark under the PTY test harness.

import std/[os, posix, strutils, times]
import std/termios
import ./types
import ./terminal as termio

var
  dbgPath {.threadvar.}: string
  dbgInit {.threadvar.}: bool

proc dbgLog(line: string) =
  ## Append-only, never to the terminal: the probe must not disturb the
  ## very geometry it measures.
  try:
    let f = open(dbgPath, fmAppend)
    let t = epochTime().formatFloat(ffDecimal, 3)
    f.writeLine "[" & t & "] " & line
    f.close()
  except IOError:
    discard

proc termDbgEnabled*(): bool =
  ## True when probing is armed: env var set with a writable path, running
  ## on a real tty, and not under the PTY test harness (where the query
  ## bytes would pollute captured frames and the PTY doesn't answer DSR).
  if not dbgInit:
    dbgInit = true
    dbgPath = getEnv("THREECODE_TERMDBG")
  if dbgPath.len == 0: return false
  if getEnv("THREECODE_TEST_FRAME_FD").len > 0:
    dbgLog("DISARMED: under PTY test harness")
    return false
  when defined(posix):
    let inTty = isatty(0.cint) != 0
    let outTty = isatty(1.cint) != 0
    if not (inTty and outTty):
      dbgLog("DISARMED: not a tty (stdin=" & $inTty & " stdout=" & $outTty & ")")
      return false
  dbgLog("ARMED")
  result = true

proc queryCursorPos*(timeoutMs = 120): tuple[row, col: int] =
  ## Ask the terminal for its absolute cursor position via DSR (`CSI 6 n`,
  ## answered `CSI <row> ; <col> R`, 1-based). Returns (0, 0) on any
  ## failure. Temporarily drops stdin to raw non-blocking so the reply can
  ## be read without line buffering, then restores the prior termios.
  result = (0, 0)
  when defined(posix):
    const FdIn = 0.cint
    var orig: Termios
    if tcGetAttr(FdIn, addr orig) != 0: return
    var raw = orig
    raw.c_lflag = raw.c_lflag and not Cflag(ICANON or ECHO)
    raw.c_cc[VMIN] = 0.char
    raw.c_cc[VTIME] = 0.char
    if tcSetAttr(FdIn, TCSANOW, addr raw) != 0: return
    try:
      termio.writeRaw("\x1b[6n")
      var buf = newString(64)
      var total = 0
      var elapsed = 0
      const Step = 10
      while elapsed < timeoutMs:
        var pfd: TPollfd
        pfd.fd = FdIn
        pfd.events = POLLIN
        let r = poll(addr pfd, 1.Tnfds, Step.cint)
        elapsed += Step
        if r > 0 and (pfd.revents and POLLIN) != 0:
          let n = posix.read(FdIn, addr buf[total], buf.len - total)
          if n > 0:
            total += n
            if total >= 4 and buf[total - 1] == 'R':
              break
          else:
            break
      let reply = buf[0 ..< total]
      # Parse ESC [ row ; col R
      if reply.len >= 4 and reply[0] == '\x1b' and reply[1] == '[' and
         reply[^1] == 'R':
        let body = reply[2 ..< ^1]
        let semi = body.find(';')
        if semi > 0:
          let row = try: parseInt(body[0 ..< semi]) except CatchableError: 0
          let col = try: parseInt(body[semi + 1 .. ^1]) except CatchableError: 0
          result = (row, col)
    finally:
      discard tcSetAttr(FdIn, TCSANOW, addr orig)

proc probeDetail*(tag: string; walkUp, editorRows, footerRows, viewportRows,
                    liveRows: int) =
  ## Rich variant of probeErase that logs the walk-up's components, so a
  ## stale field (footerRows vs editorRows) is identifiable from the log.
  if not termDbgEnabled(): return
  let (row, col) = queryCursorPos()
  let comp = " ed=" & $editorRows & " ft=" & $footerRows &
    " vp=" & $viewportRows & " lv=" & $liveRows
  if row == 0:
    dbgLog tag & " DSR no-reply walkUp=" & $walkUp & comp
    return
  dbgLog tag & " cursor=(" & $row & "," & $col & ") walkUp=" & $walkUp &
    " targetRow=" & $(row - walkUp) & comp

proc probeErase*(tag: string; walkUp: int) =
  ## Log the model's walk-up against the terminal's reported cursor row at
  ## the point of an erase. The model intends to land on the volatile
  ## region's top row: `targetRow = physicalRow - walkUp`. If that target
  ## sits above the last committed scrollback row, the erase eats real
  ## content. We can't know the scrollback row here, so we log the raw
  ## numbers; a human (or a later diff) reads the story from the sequence.
  if not termDbgEnabled(): return
  let (row, col) = queryCursorPos()
  if row == 0:
    dbgLog tag & " DSR no-reply walkUp=" & $walkUp
    return
  let target = row - walkUp
  dbgLog tag & " cursor=(" & $row & "," & $col & ") walkUp=" & $walkUp &
    " targetRow=" & $target
