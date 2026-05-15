## Reusable PTY expect helper for full-binary terminal tests.
##
## The helper starts a real process under a PTY, feeds all output through a
## ttty Grid, and records compact screen snapshots for debugging failures.

import std/[os, posix, strformat, strutils, times, unicode]
import posix/termios
import ttty/grid

type
  EnvVar* = tuple[key, val: string]

  TtyFrame* = object
    ms*: int
    rows*: seq[string]
    changedRows*: seq[int]
    cursorRow*, cursorCol*: int
    cursorHidden*: bool

  TtySession* = ref object
    masterFd*: cint
    pid*: Pid
    grid*: Grid
    raw*: string
    frames*: seq[TtyFrame]
    started*: float
    exited*: bool
    exitCode*: int
    keepHistory*: bool
    closed*: bool
    syncDepth*: int

const
  DefaultTtyCols* = 120
  DefaultTtyRows* = 40

proc openpty(masterFd, slaveFd: ptr cint; name: pointer; termp: pointer;
             winp: pointer): cint {.cdecl, importc: "openpty",
                                    header: "<pty.h>".}

proc login_tty(fd: cint): cint {.cdecl, importc: "login_tty",
                                 header: "<utmp.h>".}

proc clearenv(): cint {.cdecl, importc: "clearenv", header: "<stdlib.h>".}

var TIOCSWINSZ {.importc, header: "<sys/ioctl.h>".}: culong
const SigWinch = 28.cint

proc statusCode(status: cint): int =
  let s = status.int
  if (s and 0x7f) == 0:
    (s shr 8) and 0xff
  elif (s and 0x7f) != 0x7f:
    128 + (s and 0x7f)
  else:
    s

proc argvArray(bin: string, args: openArray[string]): cstringArray =
  var argv = newSeq[string](args.len + 1)
  argv[0] = bin
  for i, arg in args:
    argv[i + 1] = arg
  allocCStringArray(argv)

proc currentRows(s: TtySession): seq[string] =
  for r in 0 ..< s.grid.rows.len:
    result.add rowText(s.grid, r)

proc rememberFrame(s: TtySession) =
  if not s.keepHistory:
    return
  let rows = s.currentRows()
  if s.frames.len > 0 and s.frames[^1].rows == rows:
    return

  var changed: seq[int]
  if s.frames.len == 0:
    for i in 0 ..< rows.len:
      changed.add i
  else:
    let prev = s.frames[^1].rows
    for i in 0 ..< max(prev.len, rows.len):
      let oldText = if i < prev.len: prev[i] else: ""
      let newText = if i < rows.len: rows[i] else: ""
      if oldText != newText:
        changed.add i

  s.frames.add TtyFrame(
    ms: int((epochTime() - s.started) * 1000.0),
    rows: rows,
    changedRows: changed,
    cursorRow: s.grid.row,
    cursorCol: s.grid.col,
    cursorHidden: s.grid.cursorHidden)

proc noteSyncState(s: TtySession; chunk: string) =
  var i = 0
  while i < chunk.len:
    let start = chunk.find("\x1b[?2026h", i)
    let stop = chunk.find("\x1b[?2026l", i)
    if start < 0 and stop < 0:
      break
    if start >= 0 and (stop < 0 or start < stop):
      inc s.syncDepth
      i = start + "\x1b[?2026h".len
    else:
      if s.syncDepth > 0:
        dec s.syncDepth
      i = stop + "\x1b[?2026l".len

proc pollOnce(s: TtySession, waitMs: int): bool =
  if s.closed:
    return false

  var pfd: TPollfd
  pfd.fd = s.masterFd
  pfd.events = POLLIN
  let pr = poll(addr pfd, 1, max(0, waitMs).cint)
  if pr > 0 and (pfd.revents and (POLLIN or POLLHUP or POLLERR)) != 0:
    var buf: array[4096, char]
    let n = posix.read(s.masterFd, addr buf[0], buf.len)
    if n > 0:
      var chunk = newString(n)
      copyMem(chunk[0].addr, buf[0].addr, n)
      s.raw.add chunk
      s.grid.feed chunk
      s.noteSyncState(chunk)
      if s.syncDepth == 0:
        s.rememberFrame()
      result = true

  if not s.exited:
    var status: cint = 0
    let waited = waitpid(s.pid, status, WNOHANG)
    if waited == s.pid:
      s.exited = true
      s.exitCode = statusCode(status)

proc drain*(s: TtySession; settleMs = 20) =
  ## Capture any bytes currently ready on the PTY.
  let deadline = epochTime() + settleMs.float / 1000.0
  while epochTime() < deadline:
    if not s.pollOnce(1):
      sleep 1
  while s.pollOnce(0):
    discard

proc resize*(s: TtySession; cols, rows: int): bool {.discardable.} =
  ## Resize the PTY and send SIGWINCH to the child. POSIX only.
  s.grid.width = max(1, cols)
  s.grid.height = max(1, rows)
  var ws = IOctl_WinSize(ws_row: rows.cushort, ws_col: cols.cushort,
                         ws_xpixel: 0, ws_ypixel: 0)
  result = ioctl(s.masterFd, TIOCSWINSZ, addr ws) == 0
  if result and s.pid > 0 and not s.exited:
    discard kill(s.pid, SigWinch)

proc newTtySession*(bin: string; args: openArray[string] = [];
                    cwd = ""; env: openArray[EnvVar] = [];
                    cols = DefaultTtyCols; rows = DefaultTtyRows;
                    keepHistory = true): TtySession =
  ## Start `bin` under a real PTY with an isolated environment.
  ##
  ## `env` is the complete child environment, except TERM is defaulted to
  ## xterm-256color when not provided. Pass an absolute `bin` path unless the
  ## supplied env intentionally includes PATH for execv callers.
  var masterFd, slaveFd: cint
  doAssert openpty(addr masterFd, addr slaveFd, nil, nil, nil) == 0

  result = TtySession(
    masterFd: masterFd,
    grid: newGrid(),
    started: epochTime(),
    keepHistory: keepHistory,
    exitCode: -1)
  discard result.resize(cols, rows)

  let pid = fork()
  doAssert pid >= 0
  if pid == 0:
    discard close(masterFd)
    discard login_tty(slaveFd)
    discard clearenv()

    var hasTerm = false
    for item in env:
      if item.key == "TERM":
        hasTerm = true
      putEnv(item.key, item.val)
    if not hasTerm:
      putEnv("TERM", "xterm-256color")
    if cwd.len > 0:
      setCurrentDir(cwd)

    let argv = argvArray(bin, args)
    discard execv(bin.cstring, argv)
    quit 127

  result.pid = pid
  discard close(slaveFd)
  result.rememberFrame()

proc send*(s: TtySession; text: string) =
  if text.len == 0:
    return
  discard posix.write(s.masterFd, text[0].unsafeAddr, text.len)

proc ctrlC*(s: TtySession) =
  s.send "\x03"

proc ctrlD*(s: TtySession) =
  s.send "\x04"

proc signal*(s: TtySession; sig: cint) =
  if s.pid > 0 and not s.exited:
    discard kill(s.pid, sig)

proc screenText*(s: TtySession): string =
  for row in s.currentRows():
    result.add row
    result.add "\n"

proc historyText*(s: TtySession): string =
  for frame in s.frames:
    for row in frame.rows:
      result.add row
      result.add "\n"

proc cleanRaw*(raw: string): string =
  var i = 0
  while i < raw.len:
    if raw[i] == '\x1b':
      inc i
      if i < raw.len and raw[i] == '[':
        inc i
        while i < raw.len and raw[i] notin {'@'..'~'}:
          inc i
        if i < raw.len:
          inc i
      else:
        if i < raw.len:
          inc i
    elif raw[i] == '\r':
      inc i
    else:
      result.add raw[i]
      inc i

proc cleanRaw*(s: TtySession): string =
  cleanRaw(s.raw)

proc rows*(s: TtySession): seq[string] =
  s.currentRows()

proc rowContaining*(s: TtySession; text: string): int =
  for i, row in s.currentRows():
    if text in row:
      return i
  -1

proc dumpFramesAround*(s: TtySession; text: string; radius = 2): string =
  var hits: seq[int]
  for i, frame in s.frames:
    for row in frame.rows:
      if text in row:
        hits.add i
        break

  if hits.len == 0:
    let start = max(0, s.frames.len - max(1, radius * 2 + 1))
    for i in start ..< s.frames.len:
      let frame = s.frames[i]
      result.add &"frame {i} @{frame.ms}ms changed={frame.changedRows}\n"
      for row in frame.rows:
        if row.len > 0:
          result.add row & "\n"
    return

  var ranges: seq[tuple[first, last: int]]
  for hit in hits:
    let first = max(0, hit - radius)
    let last = min(s.frames.high, hit + radius)
    if ranges.len > 0 and first <= ranges[^1].last + 1:
      ranges[^1].last = max(ranges[^1].last, last)
    else:
      ranges.add (first, last)

  for r in ranges:
    for i in r.first .. r.last:
      let frame = s.frames[i]
      result.add &"frame {i} @{frame.ms}ms changed={frame.changedRows}\n"
      for rowIdx, row in frame.rows:
        if row.len > 0:
          let mark = if rowIdx in frame.changedRows: "*" else: " "
          result.add &"{mark}{rowIdx:02d}: {row}\n"

proc framesText*(s: TtySession): string =
  for i, frame in s.frames:
    let cursorState =
      if frame.cursorHidden: "hidden"
      else: &"visible@({frame.cursorRow},{frame.cursorCol})"
    result.add &"===== frame {i:04d} @{frame.ms}ms changed={frame.changedRows} cursor={cursorState} =====\n"
    for rowIdx, row in frame.rows:
      var text = row
      if not frame.cursorHidden and rowIdx == frame.cursorRow:
        let col = max(0, frame.cursorCol)
        var bytePos = 0
        var cells = 0
        while bytePos < text.len and cells < col:
          bytePos += max(1, runeLenAt(text, bytePos))
          inc cells
        if cells < col:
          text.add repeat(" ", col - cells)
          text.add "█"
        elif bytePos < text.len:
          let next = bytePos + max(1, runeLenAt(text, bytePos))
          text = text[0 ..< bytePos] & "█" & text[next .. ^1]
        else:
          text.add "█"
      result.add text
      result.add "\n"

proc writeFrameArtifact*(s: TtySession; path: string) =
  let dir = path.splitPath.head
  if dir.len > 0:
    createDir(dir)
  writeFile(path, s.framesText())

type
  NormalizedFrame = object
    originalIndex: int
    ms: int
    rows: seq[string]

proc normalizeElapsed(row: string): string =
  var i = 0
  while i < row.len:
    if row[i].isDigit:
      let start = i
      while i < row.len and row[i].isDigit:
        inc i
      if i < row.len and row[i] == 's':
        let beforeOk = start == 0 or row[start - 1] in {' ', '\t', '(', '['}
        let afterOk = i + 1 >= row.len or row[i + 1] in {' ', '\t', ')', ']'}
        if beforeOk and afterOk:
          result.add "<elapsed>"
          inc i
        else:
          result.add row[start ..< i]
      else:
        result.add row[start ..< i]
    else:
      result.add row[i]
      inc i

proc normalizeSpinnerGlyphs(row: string): string =
  result = row
  if ("↑" notin result and "↓" notin result and "↻" notin result) or
      "<elapsed>" notin result:
    return

  for glyph in ["○", "●", "◐", "◓", "◑", "◒",
                "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]:
    result = result.replace(glyph, "<spinner>")

proc normalizeFrameRows*(rows: openArray[string]): seq[string] =
  for row in rows:
    result.add row.normalizeElapsed().normalizeSpinnerGlyphs().
      strip(leading = false, trailing = true)
  while result.len > 0 and result[^1].len == 0:
    result.setLen(result.len - 1)

proc normalizeSnapshotText(text: string): seq[string] =
  for row in text.splitLines():
    result.add row
  result = result.normalizeFrameRows()
  while result.len > 0 and result[0].len == 0:
    result.delete(0)

proc snapshotText(rows: openArray[string]): string =
  rows.join("\n")

proc rowsMatch(actual, expected: openArray[string]): bool =
  let expectedRows = @expected
  let actualRows = @actual
  proc matchAt(ai, ei: int): bool =
    if ei >= expectedRows.len:
      return ai >= actualRows.len
    if expectedRows[ei] == "...":
      if ei + 1 >= expectedRows.len:
        return true
      for nextAi in ai .. actualRows.len:
        if matchAt(nextAi, ei + 1):
          return true
      return false
    if ai >= actualRows.len:
      return false
    expectedRows[ei] in actualRows[ai] and matchAt(ai + 1, ei + 1)

  matchAt(0, 0)

proc diffScore(a, b: openArray[string]): int =
  for i in 0 ..< max(a.len, b.len):
    if i >= a.len or i >= b.len:
      result += 3
    elif a[i] != b[i]:
      result += 1

proc meaningfulFrames(s: TtySession): seq[NormalizedFrame] =
  for i, frame in s.frames:
    let rows = normalizeFrameRows(frame.rows)
    if rows.len == 0:
      continue
    if result.len == 0 or result[^1].rows != rows:
      result.add NormalizedFrame(originalIndex: i, ms: frame.ms, rows: rows)

proc matchedSeries(actual: openArray[NormalizedFrame];
                   expected: openArray[seq[string]]): tuple[ok: bool, failed: int] =
  var cursor = 0
  for expectedIndex, expectedRows in expected:
    var found = false
    while cursor < actual.len:
      if actual[cursor].rows.rowsMatch(expectedRows):
        found = true
        inc cursor
        break
      inc cursor
    if not found:
      return (false, expectedIndex)
  (true, expected.len)

proc nearestFrameDump(actual: openArray[NormalizedFrame];
                      expectedRows: openArray[string]): string =
  if actual.len == 0:
    return "no frames captured"

  var nearest = 0
  var nearestScore = diffScore(actual[0].rows, expectedRows)
  for i in 1 ..< actual.len:
    let score = diffScore(actual[i].rows, expectedRows)
    if score < nearestScore:
      nearest = i
      nearestScore = score

  let frame = actual[nearest]
  &"nearest actual frame {frame.originalIndex} @{frame.ms}ms " &
    &"(diff score {nearestScore}):\n" & snapshotText(frame.rows)

proc expectFrameSeries*(s: TtySession; expected: openArray[string];
                        timeoutMs = 5000): bool {.discardable.} =
  ## Assert that normalized full-screen snapshots appear in order.
  ##
  ## Frames are normalized to remove unstable terminal padding, elapsed seconds,
  ## and token-bar spinner glyph churn. Adjacent duplicate normalized frames are
  ## collapsed so assertions describe meaningful screen states rather than every
  ## refresh tick.
  var normalizedExpected: seq[seq[string]]
  for snapshot in expected:
    normalizedExpected.add normalizeSnapshotText(snapshot)

  let deadline = epochTime() + timeoutMs.float / 1000.0
  var failedIndex = 0
  var actual: seq[NormalizedFrame]
  while epochTime() < deadline:
    s.drain(5)
    actual = s.meaningfulFrames()
    let matched = actual.matchedSeries(normalizedExpected)
    if matched.ok:
      return true
    failedIndex = matched.failed
    sleep 5

  let expectedRows =
    if failedIndex < normalizedExpected.len: normalizedExpected[failedIndex]
    else: @[]
  doAssert false,
    &"expected frame-series snapshot {failedIndex} not found\n" &
    &"expected:\n{snapshotText(expectedRows)}\n\n" &
    &"{nearestFrameDump(actual, expectedRows)}\n\n" &
    &"normalized frames={actual.len}, raw frames={s.frames.len}"

proc expect*(s: TtySession; text: string; timeoutMs = 5000): bool {.discardable.} =
  let deadline = epochTime() + timeoutMs.float / 1000.0
  while epochTime() < deadline:
    s.drain(5)
    if text in s.screenText() or text in s.cleanRaw():
      return true
    if s.exited:
      s.drain(20)
      if text in s.screenText() or text in s.cleanRaw():
        return true
    sleep 5
  doAssert false, "expected text not found: " & text & "\n" &
    s.dumpFramesAround(text)

proc expectNo*(s: TtySession; text: string; settleMs = 250): bool {.discardable.} =
  let deadline = epochTime() + settleMs.float / 1000.0
  while epochTime() < deadline:
    s.drain(5)
    doAssert text notin s.screenText() and text notin s.cleanRaw(),
      "unexpected text found: " & text & "\n" & s.dumpFramesAround(text)
    sleep 5
  true

proc expectInHistory*(s: TtySession; text: string; timeoutMs = 5000): bool {.discardable.} =
  let deadline = epochTime() + timeoutMs.float / 1000.0
  while epochTime() < deadline:
    s.drain(5)
    if text in s.historyText() or text in s.cleanRaw():
      return true
    sleep 5
  doAssert false, "expected history text not found: " & text & "\n" &
    s.dumpFramesAround(text)

proc expectNeverInHistory*(s: TtySession; text: string) =
  s.drain(20)
  doAssert text notin s.historyText() and text notin s.cleanRaw(),
    "unexpected history text found: " & text & "\n" & s.dumpFramesAround(text)

proc frameHasParts(frame: TtyFrame; parts: openArray[string]): bool =
  for part in parts:
    var found = false
    for row in frame.rows:
      if part in row:
        found = true
        break
    if not found:
      return false
  true

proc expectSnapshot*(s: TtySession; parts: openArray[string];
                     timeoutMs = 5000): bool {.discardable.} =
  let deadline = epochTime() + timeoutMs.float / 1000.0
  while epochTime() < deadline:
    s.drain(5)
    for frame in s.frames:
      if frame.frameHasParts(parts):
        return true
    sleep 5
  doAssert false, "expected screen snapshot not found: " & @parts.join(", ") &
    "\n" & s.dumpFramesAround(if parts.len > 0: parts[0] else: "")

proc expectNoFrame*(s: TtySession; bad: proc(frame: TtyFrame): bool) =
  s.drain(20)
  for frame in s.frames:
    doAssert not bad(frame), "unexpected screen frame:\n" &
      &"frame @{frame.ms}ms changed={frame.changedRows}\n" &
      frame.rows.join("\n")

proc hasReasoningTickerRow*(frame: TtyFrame): bool =
  for row in frame.rows:
    if row.strip.startsWith("… ") or row.strip.startsWith("... "):
      return true

proc hasOrphanSpinnerRow*(frame: TtyFrame): bool =
  var lastNonEmpty = -1
  for i, row in frame.rows:
    if row.strip().len > 0:
      lastNonEmpty = i
  for i, row in frame.rows:
    let trimmed = row.strip()
    if trimmed.len == 0:
      continue
    var isSpinner = false
    for glyph in ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]:
      if trimmed.startsWith(glyph):
        isSpinner = true
        break
    if isSpinner:
      # The PTY trace can capture a footer repaint while the spinner row
      # is the last visible row. That is not scrollback corruption; only
      # rows stranded above later content are genuinely orphaned.
      if i == lastNonEmpty:
        continue
      let hasPromptBelow =
        (i + 1 < frame.rows.len and "❯" in frame.rows[i + 1]) or
        (i + 2 < frame.rows.len and "❯" in frame.rows[i + 2])
      let hasBarBelow =
        i + 1 < frame.rows.len and
        ("↑" in frame.rows[i + 1] or "↓" in frame.rows[i + 1] or
         "↻" in frame.rows[i + 1])
      if not hasPromptBelow and not hasBarBelow:
        return true

proc expectNoPromptRowText*(s: TtySession; texts: openArray[string]) =
  s.drain(20)
  for frame in s.frames:
    for row in frame.rows:
      if row.startsWith("❯ "):
        for text in texts:
          doAssert text notin row, "assistant text on prompt row:\n" &
            &"frame @{frame.ms}ms changed={frame.changedRows}\n" &
            frame.rows.join("\n")

proc expectNoReasoningTickerRows*(s: TtySession) =
  s.expectNoFrame(hasReasoningTickerRow)

proc expectNoOrphanSpinnerRows*(s: TtySession) =
  s.expectNoFrame(hasOrphanSpinnerRow)

proc expectExit*(s: TtySession; code: int; timeoutMs = 5000): bool {.discardable.} =
  let deadline = epochTime() + timeoutMs.float / 1000.0
  while epochTime() < deadline:
    s.drain(5)
    if s.exited:
      doAssert s.exitCode == code,
        &"expected exit code {code}, got {s.exitCode}"
      return true
    sleep 5
  doAssert false, &"expected process exit code {code}, still running"

proc tokenBarRows*(s: TtySession): seq[string] =
  ## Return rows that look like the compact token/status bar.
  for row in s.currentRows():
    if ("↑" in row or "↓" in row or "↻" in row) and "s" in row:
      result.add row

proc expectTokenBar*(s: TtySession; parts: openArray[string];
                     timeoutMs = 5000): bool {.discardable.} =
  let deadline = epochTime() + timeoutMs.float / 1000.0
  while epochTime() < deadline:
    s.drain(5)
    for row in s.tokenBarRows():
      var foundAll = true
      for part in parts:
        if part notin row:
          foundAll = false
          break
      if foundAll:
        return true
    sleep 5
  doAssert false, "expected token bar parts not found: " & @parts.join(", ") &
    "\n" & s.screenText()

proc expectTokenBarStable*(s: TtySession; settleMs = 300): bool {.discardable.} =
  let deadline = epochTime() + settleMs.float / 1000.0
  while epochTime() < deadline:
    s.drain(5)
    let bars = s.tokenBarRows()
    if bars.len > 0:
      let rs = s.rows()
      var barRow = -1
      for i in countdown(rs.high, 0):
        if bars[^1] in rs[i]:
          barRow = i
          break
      doAssert barRow >= 0, "token bar disappeared:\n" & s.screenText()
      if barRow > 0:
        doAssert rs[barRow - 1] notin bars,
          "adjacent stacked token bars:\n" & s.screenText()
      doAssert barRow + 1 < rs.len and "❯" in rs[barRow + 1],
        "token bar without prompt below:\n" & s.screenText()
    sleep 5
  true

proc close*(s: TtySession) =
  if s.closed:
    return
  s.drain(20)
  if not s.exited:
    discard kill(s.pid, SIGTERM)
    let deadline = epochTime() + 0.5
    while epochTime() < deadline and not s.exited:
      discard s.pollOnce(20)
    if not s.exited:
      discard kill(s.pid, SIGKILL)
      discard s.pollOnce(20)
    if not s.exited:
      var status: cint = 0
      if waitpid(s.pid, status, 0) == s.pid:
        s.exited = true
        s.exitCode = statusCode(status)
  discard close(s.masterFd)
  s.closed = true
