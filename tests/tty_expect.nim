## Reusable PTY expect helper for full-binary terminal tests.
##
## The helper starts a real process under a PTY, feeds all output through a
## ttty Grid, and records compact screen snapshots for debugging failures.

import std/[os, posix, random, strformat, strutils, times, unicode]
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
    pendingFrame*: bool
    lastOutputAt*: float
    frameEventFd*: cint
    frameAckFd*: cint
    tickerCommandFd*: cint
    tickerAckFd*: cint
    apiContinueFd*: cint

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
when defined(linux):
  proc syscall(number: clong): clong {.varargs, importc, header: "<unistd.h>".}
  var SYS_tgkill {.importc, header: "<sys/syscall.h>".}: clong

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

proc markFrameDirty(s: TtySession) =
  if not s.keepHistory:
    return
  s.pendingFrame = true
  s.lastOutputAt = epochTime()

proc flushFrame*(s: TtySession; force = false) =
  if not s.keepHistory or not s.pendingFrame or s.syncDepth > 0:
    return
  s.rememberFrame()
  s.pendingFrame = false

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

proc stripCsiWithIntermediates(bytes: string): string =
  ## ttty's lightweight CSI parser does not consume intermediate bytes
  ## such as the space in DECSCUSR (`ESC[ q`), which leaves the final
  ## byte as visible text. Strip those unsupported CSI forms before feeding
  ## the visual grid; raw bytes are still retained unchanged on the session.
  var i = 0
  while i < bytes.len:
    if bytes[i] == '\x1b' and i + 1 < bytes.len and bytes[i + 1] == '[':
      var j = i + 2
      var hasIntermediate = false
      while j < bytes.len and bytes[j] notin {'@'..'~'}:
        if bytes[j] in {' '..'/'}:
          hasIntermediate = true
        inc j
      if j < bytes.len and hasIntermediate:
        i = j + 1
      else:
        let stop = if j < bytes.len: j + 1 else: bytes.len
        result.add bytes[i ..< stop]
        i = stop
    else:
      result.add bytes[i]
      inc i

proc feedGridChunk(s: TtySession; chunk: string) =
  if chunk.len == 0:
    return
  s.raw.add chunk
  s.grid.feed chunk.stripCsiWithIntermediates()
  s.noteSyncState(chunk)
  s.markFrameDirty()

proc readPtyChunk(s: TtySession; waitMs: int): bool =
  var pfd: TPollfd
  pfd.fd = s.masterFd
  pfd.events = POLLIN
  let pr = poll(addr pfd, 1.Tnfds, max(0, waitMs).cint)
  if pr > 0 and (pfd.revents and (POLLIN or POLLHUP or POLLERR)) != 0:
    var buf: array[4096, char]
    let n = posix.read(s.masterFd, addr buf[0], buf.len)
    if n > 0:
      var chunk = newString(n)
      copyMem(chunk[0].addr, buf[0].addr, n)
      s.feedGridChunk(chunk)
      return true

proc pollOnce(s: TtySession, waitMs: int; recordIdleFrame = true): bool =
  if s.closed:
    return false

  var pfds: array[2, TPollfd]
  pfds[0].fd = s.masterFd
  pfds[0].events = POLLIN
  var pollCount = 1.Tnfds
  if s.frameEventFd > 0:
    pfds[1].fd = s.frameEventFd
    pfds[1].events = POLLIN
    pollCount = 2.Tnfds
  let pr = poll(addr pfds[0], pollCount, max(0, waitMs).cint)
  if pr > 0 and (pfds[0].revents and (POLLIN or POLLHUP or POLLERR)) != 0:
    result = s.readPtyChunk(0) or result
  if pr > 0 and pollCount == 2.Tnfds and
      (pfds[1].revents and (POLLIN or POLLHUP or POLLERR)) != 0:
    var buf: array[256, char]
    discard posix.read(s.frameEventFd, addr buf[0], buf.len)
    while s.readPtyChunk(5):
      discard
    s.flushFrame(force = true)
    if s.frameAckFd > 0:
      var ch = 'a'
      discard posix.write(s.frameAckFd, addr ch, 1)
    result = true
  elif not result and recordIdleFrame:
    s.flushFrame()

  if not s.exited:
    var status: cint = 0
    let waited = waitpid(s.pid, status, WNOHANG)
    if waited == s.pid:
      s.exited = true
      s.exitCode = statusCode(status)
      s.flushFrame(force = true)

proc drain*(s: TtySession; settleMs = 20; recordFrame = true) =
  ## Capture any bytes currently ready on the PTY.
  let deadline = epochTime() + settleMs.float / 1000.0
  while epochTime() < deadline:
    if not s.pollOnce(1, recordFrame):
      sleep 1
  while s.pollOnce(0, recordFrame):
    discard
  if recordFrame:
    s.flushFrame(force = true)

proc resize*(s: TtySession; cols, rows: int): bool {.discardable.} =
  ## Resize the PTY and send SIGWINCH to the child. POSIX only.
  s.flushFrame(force = true)
  s.grid.width = max(1, cols)
  s.grid.height = max(1, rows)
  s.markFrameDirty()
  var ws = IOctl_WinSize(ws_row: rows.cushort, ws_col: cols.cushort,
                         ws_xpixel: 0, ws_ypixel: 0)
  result = ioctl(s.masterFd, TIOCSWINSZ, addr ws) == 0
  if result and s.pid > 0 and not s.exited:
    discard kill(s.pid, SigWinch)

proc resizeMainThread*(s: TtySession; cols, rows: int): bool {.discardable.} =
  ## Resize the PTY and send SIGWINCH to the child's main thread. Linux-only
  ## tests use this to reproduce API reads interrupted by terminal resize.
  result = s.resize(cols, rows)
  when defined(linux):
    if result and s.pid > 0 and not s.exited:
      discard syscall(SYS_tgkill, s.pid, s.pid, SigWinch)

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
  var framePipe: array[2, cint]
  doAssert pipe(framePipe) == 0
  discard fcntl(framePipe[1], F_SETFD, 0)
  var ackPipe: array[2, cint]
  doAssert pipe(ackPipe) == 0
  discard fcntl(ackPipe[0], F_SETFD, 0)
  var tickerPipe: array[2, cint]
  doAssert pipe(tickerPipe) == 0
  discard fcntl(tickerPipe[0], F_SETFD, 0)
  var tickerAckPipe: array[2, cint]
  doAssert pipe(tickerAckPipe) == 0
  discard fcntl(tickerAckPipe[1], F_SETFD, 0)
  var apiContinuePipe: array[2, cint]
  doAssert pipe(apiContinuePipe) == 0
  discard fcntl(apiContinuePipe[0], F_SETFD, 0)

  result = TtySession(
    masterFd: masterFd,
    frameEventFd: framePipe[0],
    frameAckFd: ackPipe[1],
    tickerCommandFd: tickerPipe[1],
    tickerAckFd: tickerAckPipe[0],
    apiContinueFd: apiContinuePipe[1],
    grid: newGrid(),
    started: epochTime(),
    keepHistory: keepHistory,
    exitCode: -1)
  discard result.resize(cols, rows)

  let pid = fork()
  doAssert pid >= 0
  if pid == 0:
    discard close(masterFd)
    discard close(framePipe[0])
    discard close(ackPipe[1])
    discard close(tickerPipe[1])
    discard close(tickerAckPipe[0])
    discard close(apiContinuePipe[1])
    discard login_tty(slaveFd)
    discard clearenv()

    var hasTerm = false
    for item in env:
      if item.key == "TERM":
        hasTerm = true
      putEnv(item.key, item.val)
    if not hasTerm:
      putEnv("TERM", "xterm-256color")
    putEnv("THREECODE_TEST_FRAME_FD", $framePipe[1])
    putEnv("THREECODE_TEST_FRAME_ACK_FD", $ackPipe[0])
    putEnv("THREECODE_TEST_TICKER_FD", $tickerPipe[0])
    putEnv("THREECODE_TEST_TICKER_ACK_FD", $tickerAckPipe[1])
    putEnv("THREECODE_TEST_API_CONTINUE_FD", $apiContinuePipe[0])
    if cwd.len > 0:
      setCurrentDir(cwd)

    let argv = argvArray(bin, args)
    discard execv(bin.cstring, argv)
    quit 127

  result.pid = pid
  discard close(slaveFd)
  discard close(framePipe[1])
  discard close(ackPipe[0])
  discard close(tickerPipe[0])
  discard close(tickerAckPipe[1])
  discard close(apiContinuePipe[0])
  result.rememberFrame()

proc send*(s: TtySession; text: string) =
  if text.len == 0:
    return
  discard posix.write(s.masterFd, text[0].unsafeAddr, text.len)
  var printable = ""
  var inEsc = false
  for ch in text:
    if inEsc:
      if ch in {'@'..'~'}:
        inEsc = false
    elif ch == '\x1b':
      inEsc = true
    elif ch >= ' ' and ch != '\x7f':
      printable.add ch
  let deadline = epochTime() + 1.0
  if printable.len > 0:
    while epochTime() < deadline and
        printable notin s.currentRows().join("\n") and printable notin s.raw:
      discard s.pollOnce(20, recordIdleFrame = false)
  else:
    discard s.pollOnce(1000, recordIdleFrame = false)
  while s.pollOnce(0):
    discard
  s.flushFrame(force = true)

proc advanceTicker*(s: TtySession) =
  ## Deterministically advance one live spinner/ticker frame in the child.
  if s.tickerCommandFd <= 0 or s.tickerAckFd <= 0:
    return
  var ch = 't'
  discard posix.write(s.tickerCommandFd, addr ch, 1)
  var ack: array[1, char]
  discard posix.read(s.tickerAckFd, addr ack[0], 1)
  s.drain(20, recordFrame = true)

proc continueStubApi*(s: TtySession) =
  ## Release a stub response blocked on waitForTestContinue.
  if s.apiContinueFd <= 0:
    return
  var ch = 'c'
  discard posix.write(s.apiContinueFd, addr ch, 1)

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
          result.add "0s"
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
  if " 0s" notin result and not result.endsWith("0s"):
    return

  for glyph in ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]:
    if result.strip(leading = true, trailing = false).startsWith(glyph):
      let pos = result.find(glyph)
      if pos >= 0:
        result = result[0 ..< pos] & "⣿" & result[pos + glyph.len .. ^1]
      return

proc normalizeTtyRunRoots(row: string): string =
  ## Collapse the per-run output root to `<tty-run>`, including any repo-root
  ## prefix, so frames are identical regardless of which worktree or clone
  ## the suite runs from. Skill and prompt paths materialize under the
  ## test's isolated XDG_DATA_HOME, which nests under that absolute root.
  const marker = "tests/output/tty/"
  result = row
  var start = result.find(marker)
  while start >= 0:
    let runStart = start + marker.len
    let dataPos = result.find("/data/", runStart)
    if dataPos < 0:
      break
    # The marker sits inside an absolute path. Drop the repo-root prefix
    # before `tests/` so the normalized frame does not embed the cwd.
    var prefixEnd = start
    while prefixEnd > 0 and result[prefixEnd - 1] != ' ':
      dec prefixEnd
    result = result[0 ..< prefixEnd] & "<tty-run>" & result[dataPos .. ^1]
    start = result.find(marker, prefixEnd + "<tty-run>".len)

proc normalizeFrameRows*(rows: openArray[string]): seq[string] =
  for row in rows:
    var normalized = row.normalizeElapsed().normalizeSpinnerGlyphs().
      normalizeTtyRunRoots().strip(leading = false, trailing = true)
    if normalized.endsWith("█"):
      normalized = normalized[0 ..< normalized.len - "█".len].
        strip(leading = false, trailing = true)
    result.add normalized

proc frameRowsWithCursor(frame: TtyFrame): seq[string] =
  result = frame.rows
  if frame.cursorHidden or frame.cursorRow < 0 or frame.cursorRow >= result.len:
    return
  var text = result[frame.cursorRow]
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
  result[frame.cursorRow] = text

proc allRowsEmpty(rows: openArray[string]): bool =
  result = true
  for row in rows:
    if row.len > 0:
      return false

proc meaningfulFrameText*(s: TtySession): string =
  ## Full-frame visual recording suitable for expected-frame review. Every changed
  ## screen state is preserved; adjacent duplicate normalized states are compressed.
  var lastRows: seq[string]
  randomize()
  for frame in s.frames:
    let rows = normalizeFrameRows(frame.frameRowsWithCursor())
    if rows.allRowsEmpty:
      continue
    if rows == lastRows:
      continue
    result.add &"===== {rand(100..999)} =====\n"
    for row in rows:
      result.add row
      result.add "\n"
    lastRows = rows

proc normalizeFrameSeparators(text: string): string =
  ## Expected fixtures may use hand-friendly arbitrary frame labels. Only the
  ## separator boundary matters for comparison.
  for line in text.splitLines(keepEol = true):
    if line.startsWith("=====") and line.strip.endsWith("====="):
      result.add "===== frame =====\n"
    else:
      result.add line

proc normalizeVersionBanner(text: string): string =
  ## Replace version strings like `v0.5.0-main-6e809ef1-unstaged` with a
  ## stable placeholder so fixture comparison doesn't break on every commit.
  var inBanner = false
  for line in text.splitLines(keepEol = true):
    if "3code v" in line and "the economical coding agent" in line:
      let prefix = "3code v"
      let suffix = "   the economical coding agent"
      let startPos = line.find(prefix)
      let endPos = line.find(suffix, startPos + prefix.len)
      if startPos >= 0 and endPos > startPos:
        result.add line[0..<startPos] & prefix & "VERSION" & suffix & line[endPos+suffix.len..^1]
      else:
        result.add line
    else:
      result.add line

proc stripFrameBlanks(text: string): string =
  ## Drop blank rows inside each frame for comparison. The separator row a
  ## full repaint inserts between the prompt echo and arriving assistant
  ## content is a transient grid state: depending on PTY byte scheduling it
  ## lands in the captured frame as a blank row or not at all. That
  ## 0-vs-1-blank difference is timing noise, not a content change. Content
  ## rows are always non-blank, so stripping blanks cannot hide a missing or
  ## altered row; multi-blank spacing regressions are covered by the dedicated
  ## separators test, which inspects frames directly.
  var inFrame = false
  for line in text.splitLines(keepEol = true):
    if line.startsWith("=====") and line.strip.endsWith("====="):
      result.add "===== frame =====\n"
      inFrame = true
    elif inFrame and line.strip.len == 0:
      discard
    else:
      result.add line

proc writeMeaningfulFrameArtifact*(s: TtySession; path: string) =
  let dir = path.splitPath.head
  if dir.len > 0:
    createDir(dir)
  writeFile(path, s.meaningfulFrameText())

proc expectMeaningfulFrameArtifact*(s: TtySession; expectedPath,
                                    actualPath: string) =
  let actual = s.meaningfulFrameText()
  let dir = actualPath.splitPath.head
  if dir.len > 0:
    createDir(dir)
  writeFile(actualPath, actual)
  doAssert fileExists(expectedPath),
    "missing expected full-frame artifact: " & expectedPath & "\nactual written to: " &
      actualPath
  let expected = readFile(expectedPath)
  doAssert actual.normalizeVersionBanner.normalizeFrameSeparators.stripFrameBlanks ==
      expected.normalizeVersionBanner.normalizeFrameSeparators.stripFrameBlanks,
    "full-frame recording differed from expected frames\nexpected: " & expectedPath &
      "\nactual: " & actualPath

proc expect*(s: TtySession; text: string; timeoutMs = 5000): bool {.discardable.} =
  let deadline = epochTime() + timeoutMs.float / 1000.0
  while epochTime() < deadline:
    s.drain(5, recordFrame = false)
    if text in s.screenText() or text in s.cleanRaw():
      return true
    if s.exited:
      s.drain(20, recordFrame = false)
      if text in s.screenText() or text in s.cleanRaw():
        return true
    sleep 5
  doAssert false, "expected text not found: " & text & "\n" &
    s.dumpFramesAround(text)

proc expectNo*(s: TtySession; text: string; settleMs = 250): bool {.discardable.} =
  let deadline = epochTime() + settleMs.float / 1000.0
  while epochTime() < deadline:
    s.drain(5, recordFrame = false)
    doAssert text notin s.screenText() and text notin s.cleanRaw(),
      "unexpected text found: " & text & "\n" & s.dumpFramesAround(text)
    sleep 5
  true

proc expectTypedAtPrompt*(s: TtySession; text: string;
                           timeoutMs = 5000): bool {.discardable.} =
  ## Verify typed text is live at the prompt: caret visible and the text
  ## present on the cursor row. Catches the regression where an interrupt
  ## leaves the prompt painted but the editor dead — `send` writes bytes to
  ## the pty but nothing repaints, so the text never appears on the cursor row.
  let deadline = epochTime() + timeoutMs.float / 1000.0
  while epochTime() < deadline:
    s.drain(5, recordFrame = false)
    if s.frames.len > 0:
      let f = s.frames[^1]
      if not f.cursorHidden and f.cursorRow >= 0 and
          f.cursorRow < f.rows.len and text in f.rows[f.cursorRow]:
        return true
    if s.exited:
      break
    sleep 5
  doAssert false, "typed text not live at prompt: " & text & "\n" &
    s.dumpFramesAround(text)

proc expectInHistory*(s: TtySession; text: string; timeoutMs = 5000): bool {.discardable.} =
  let deadline = epochTime() + timeoutMs.float / 1000.0
  while epochTime() < deadline:
    s.drain(5, recordFrame = false)
    if text in s.historyText() or text in s.cleanRaw():
      return true
    sleep 5
  doAssert false, "expected history text not found: " & text & "\n" &
    s.dumpFramesAround(text)

proc expectNeverInHistory*(s: TtySession; text: string) =
  s.drain(20, recordFrame = false)
  doAssert text notin s.historyText() and text notin s.cleanRaw(),
    "unexpected history text found: " & text & "\n" & s.dumpFramesAround(text)

proc expectExit*(s: TtySession; code: int; timeoutMs = 5000): bool {.discardable.} =
  let deadline = epochTime() + timeoutMs.float / 1000.0
  while epochTime() < deadline:
    s.drain(5, recordFrame = false)
    if s.exited:
      doAssert s.exitCode == code,
        &"expected exit code {code}, got {s.exitCode}"
      return true
    sleep 5
  doAssert false, &"expected process exit code {code}, still running"

proc tokenBarRows(s: TtySession): seq[string] =
  ## Return rows that look like the compact token/status bar.
  for row in s.currentRows():
    if ("↑" in row or "↓" in row or "↻" in row) and "s" in row:
      result.add row

proc expectTokenBar*(s: TtySession; parts: openArray[string];
                     timeoutMs = 5000): bool {.discardable.} =
  let deadline = epochTime() + timeoutMs.float / 1000.0
  while epochTime() < deadline:
    s.drain(5, recordFrame = false)
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

proc close*(s: TtySession) =
  if s.closed:
    return
  s.drain(20, recordFrame = false)
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
  if s.frameEventFd > 0:
    discard close(s.frameEventFd)
    s.frameEventFd = 0
  if s.frameAckFd > 0:
    discard close(s.frameAckFd)
    s.frameAckFd = 0
  if s.tickerCommandFd > 0:
    discard close(s.tickerCommandFd)
    s.tickerCommandFd = 0
  if s.tickerAckFd > 0:
    discard close(s.tickerAckFd)
    s.tickerAckFd = 0
  if s.apiContinueFd > 0:
    discard close(s.apiContinueFd)
    s.apiContinueFd = 0
  s.closed = true
