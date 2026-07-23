## Reusable PTY expect helper for full-binary terminal tests.
##
## The helper starts a real process under a PTY, feeds all output through a
## ttty Grid, and records compact screen snapshots for debugging failures.
##
## Platform lifecycle: on POSIX the child is forked under a real PTY
## (openpty/login_tty/execv); on Windows it is spawned under the Windows
## Pseudo Console API (ConPTY: CreatePseudoConsole + a PROC_THREAD_ATTRIBUTE_
## PSEUDOCONSOLE attribute list + CreateProcessW). The `TtySession` record
## and the public expect*/send/resize/close API are identical across both;
## only the harness internals fork on `when defined(...)`.

import std/[os, random, strformat, strutils, times, unicode]
import ttty/grid

when defined(windows):
  import winlean
  # ConPTY and the PROC_THREAD_ATTRIBUTE list are not in Nim's winlean, so
  # declare them directly against kernel32 / the documented constants.
  type
    HPCON* = distinct Handle
    COORD* = object
      x*, y*: int16
    PROC_THREAD_ATTRIBUTE_LIST* = object
    SIZE_T* = uint
  const
    PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE* = 0x00020016'u32
    EXTENDED_STARTUPINFO_PRESENT* = 0x00080000'i32
    STILL_ACTIVE_DW* = 0x00000103'i32
  proc createPseudoConsole(size: COORD; hInput, hOutput: Handle;
      dwFlags: uint32; phPC: ptr HPCON): int32 {.stdcall,
      dynlib: "kernel32", importc: "CreatePseudoConsole".}
  proc resizePseudoConsole(hPC: HPCON; size: COORD): int32 {.stdcall,
      dynlib: "kernel32", importc: "ResizePseudoConsole".}
  proc closePseudoConsole(hPC: HPCON) {.stdcall,
      dynlib: "kernel32", importc: "ClosePseudoConsole".}
  proc initializeProcThreadAttributeList(
      lpAttributeList: pointer; dwAttributeCount: DWORD;
      dwFlags: DWORD; lpSize: ptr SIZE_T): WINBOOL {.stdcall,
      dynlib: "kernel32", importc: "InitializeProcThreadAttributeList".}
  proc deleteProcThreadAttributeList(lpAttributeList: pointer) {.stdcall,
      dynlib: "kernel32", importc: "DeleteProcThreadAttributeList".}
  proc updateProcThreadAttribute(lpAttributeList: pointer;
      dwFlags: DWORD; attribute: uint32; lpValue: pointer; cbSize: SIZE_T;
      lpPreviousValue: pointer; lpReturnSize: ptr SIZE_T): WINBOOL {.stdcall,
      dynlib: "kernel32", importc: "UpdateProcThreadAttribute".}
  type
    STARTUPINFOEX* = object
      startupInfo*: STARTUPINFO
      lpAttributeList*: pointer
else:
  import posix
  import posix/termios

# Platform-conditional fd-like type so the TtySession fields have one name
# across both branches: a POSIX file descriptor (cint) or a Windows HANDLE
# (int). 0 / invalid is the sentinel for "not set" on both.
when defined(windows):
  type FdLike* = Handle
  template fdValid(fd): bool = (fd).int != 0 and (fd).int != -1
else:
  type FdLike* = cint
  template fdValid(fd): bool = (fd).cint > 0

type
  EnvVar* = tuple[key, val: string]

  TtyFrame* = object
    ms*: int
    rows*: seq[string]
    changedRows*: seq[int]
    cursorRow*, cursorCol*: int
    cursorHidden*: bool

  TtySession* = ref object
    # The PTY/conduit handle and the child identifier. POSIX uses a single
    # PTY master fd + a Pid; Windows splits the ConPTY master into separate
    # read/write pipe handles and tracks the child via a process Handle. The
    # field names are kept constant so test bodies that reference them
    # (test_tty_functional's hardKill/discardClose, gated to POSIX) compile
    # on both; on Windows `masterFd` is the read side and `masterWriteFd`
    # the write side of the ConPTY's master pipe pair.
    masterFd*: FdLike
    when defined(windows):
      masterWriteFd*: Handle
      hpc*: HPCON
      hProcess*: Handle
      hThread*: Handle
      dwProcessId*: int32
    else:
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
    frameRecordingPaused*: bool
    lastOutputAt*: float
    rawConsumedLen*: int
    frameEventFd*: FdLike
    frameAckFd*: FdLike
    tickerCommandFd*: FdLike
    tickerAckFd*: FdLike
    apiContinueFd*: FdLike

const
  DefaultTtyCols* = 120
  DefaultTtyRows* = 40

# Clear the child's environment before re-seeding it. clearenv() is a
# glibc/BSD extension absent from macOS <stdlib.h> (undeclared -> compile
# error under Xcode), so delete each variable via Nim's portable delEnv.
proc clearEnv() =
  for key, val in envPairs():
    delEnv(key)

when defined(posix):
  # openpty and login_tty live in different headers across platforms:
  # openpty is in <pty.h> on glibc, <util.h> on macOS; login_tty is in
  # <utmp.h> on glibc (older glibc declared it in <pty.h>, but current
  # releases moved it), <util.h> on macOS. Import each symbol from its own
  # header so a single-platform header swap doesn't silently misdeclare the
  # other.
  proc openpty(masterFd, slaveFd: ptr cint; name: pointer; termp: pointer;
               winp: pointer): cint {.cdecl, importc: "openpty",
                                      header: (when defined(macosx): "<util.h>"
                                               else: "<pty.h>").}

  proc login_tty(fd: cint): cint {.cdecl, importc: "login_tty",
                                   header: (when defined(macosx): "<util.h>"
                                            else: "<utmp.h>").}

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
  if not s.keepHistory or not s.pendingFrame:
    return
  if not force and s.syncDepth > 0:
    return
  s.rememberFrame()
  s.pendingFrame = false

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

const
  SyncBegin = "\x1b[?2026h"
  SyncEnd = "\x1b[?2026l"

proc feedGridChunk(s: TtySession; chunk: string) =
  ## Feed the grid incrementally, splitting on sync-burst boundaries so
  ## each SyncBegin..SyncEnd render is committed as its own frame with the
  ## grid in the state that burst produced. Feeding the whole chunk at once
  ## would snapshot the final grid for every intermediate SyncEnd, losing
  ## intermediate render states and causing boundary drift when the PTY
  ## delivers multiple bursts in one read().
  if chunk.len == 0:
    return
  s.raw.add chunk
  var i = 0
  while i < chunk.len:
    let nextBegin = chunk.find(SyncBegin, i)
    let nextEnd = chunk.find(SyncEnd, i)
    if nextBegin < 0 and nextEnd < 0:
      s.grid.feed chunk[i ..< chunk.len].stripCsiWithIntermediates()
      s.markFrameDirty()
      break
    if nextBegin >= 0 and (nextEnd < 0 or nextBegin < nextEnd):
      if nextBegin > i:
        s.grid.feed chunk[i ..< nextBegin].stripCsiWithIntermediates()
        s.markFrameDirty()
      inc s.syncDepth
      i = nextBegin + SyncBegin.len
    else:
      s.grid.feed chunk[i ..< nextEnd].stripCsiWithIntermediates()
      s.markFrameDirty()
      if s.syncDepth > 0:
        dec s.syncDepth
        if s.syncDepth == 0 and not s.frameRecordingPaused:
          s.flushFrame()
      i = nextEnd + SyncEnd.len

when defined(windows):
  proc pipeBytesAvail(h: Handle): int32 =
    ## Non-blocking check for bytes available on an anonymous pipe read handle.
    ## WaitForSingleObject is unreliable on anonymous pipe handles (they are
    ## not waitable for read-readiness the way console/event handles are), so
    ## we poll with PeekNamedPipe instead — it returns immediately with the
    ## count of unread bytes, or 0 if nothing is ready.
    var avail: int32 = 0
    if peekNamedPipe(h, nil, 0, nil, addr avail, nil):
      return avail
    # PeekNamedPipe fails when the write end is closed (child exited) — treat
    # that as no bytes available; the exit poll picks up the exit separately.
    0

proc readPtyChunk(s: TtySession; waitMs: int): bool =
  when defined(windows):
    # Bounded wait loop: poll PeekNamedPipe for available bytes, sleeping in
    # small increments, never issuing a blocking readFile on an empty pipe
    # (which would hang until the write end closes). A dead child that stops
    # writing drains the poll budget and we return cleanly.
    let deadline = epochTime() + max(0, waitMs).float / 1000.0
    while epochTime() < deadline:
      let avail = pipeBytesAvail(s.masterFd)
      if avail > 0:
        var buf: array[4096, char]
        var got: int32 = 0
        let toRead = min(avail, buf.len.int32)
        if readFile(s.masterFd, addr buf[0], toRead, addr got, nil) != 0 and got > 0:
          var chunk = newString(got)
          copyMem(chunk[0].addr, buf[0].addr, got)
          s.feedGridChunk(chunk)
          return true
        return false
      sleep(1)
    false
  else:
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

proc childExited(s: TtySession): bool =
  ## Non-blocking exit check. POSIX: waitpid(WNOHANG). Windows:
  ## GetExitCodeProcess (STILL_ACTIVE means not exited). Returns true and
  ## sets s.exitCode/s.exited when the child has exited.
  when defined(windows):
    var code: int32 = 0
    if getExitCodeProcess(s.hProcess, code) != 0 and code != STILL_ACTIVE_DW:
      s.exitCode = code.int
      s.exited = true
      s.flushFrame(force = true)
      return true
    false
  else:
    var status: cint = 0
    let waited = waitpid(s.pid, status, WNOHANG)
    if waited == s.pid:
      s.exited = true
      s.exitCode = statusCode(status)
      s.flushFrame(force = true)
      true
    else:
      false

proc pollOnce(s: TtySession, waitMs: int; recordIdleFrame = true): bool =
  if s.closed:
    return false

  when defined(windows):
    # Anonymous pipe handles are not waitable for read-readiness, so we poll
    # both the ConPTY output and the frame-event pipe with PeekNamedPipe,
    # sleeping in small increments until the waitMs budget is spent. The
    # frame-event branch mirrors the POSIX path: drain pending PTY bytes,
    # force a frame commit, ack the child, then fall through to exit check.
    let deadline = epochTime() + max(0, waitMs).float / 1000.0
    var sawMaster = false
    var sawFrame = false
    while epochTime() < deadline and not (sawMaster or sawFrame):
      if pipeBytesAvail(s.masterFd) > 0:
        sawMaster = true
      elif s.frameEventFd.int != 0 and s.frameEventFd.int != -1 and
          pipeBytesAvail(s.frameEventFd) > 0:
        sawFrame = true
      else:
        sleep(1)
    if sawMaster:
      result = s.readPtyChunk(0) or result
    if sawFrame:
      var buf: array[256, char]
      var got: int32 = 0
      discard readFile(s.frameEventFd, addr buf[0], buf.len.int32, addr got, nil)
      if got > 0:
        while s.readPtyChunk(5):
          discard
        s.flushFrame(force = true)
        if s.frameAckFd.int != 0 and s.frameAckFd.int != -1:
          var ch = 'a'
          var written: int32 = 0
          discard writeFile(s.frameAckFd, addr ch, 1, addr written, nil)
        result = true
    if not result and recordIdleFrame:
      s.flushFrame()
    discard s.childExited()
  else:
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
      let n = posix.read(s.frameEventFd, addr buf[0], buf.len)
      # Child exited: frame event pipe is closed, no point draining. Fall
      # through to the waitpid below rather than returning early, so the exit
      # is reaped and `s.exited` is set (an early return here skips reaping
      # and leaves a zombie the caller never observes).
      if n > 0:
        while s.readPtyChunk(5):
          discard
        s.flushFrame(force = true)
        if s.frameAckFd > 0:
          var ch = 'a'
          discard posix.write(s.frameAckFd, addr ch, 1)
        result = true
    elif not result and recordIdleFrame:
      s.flushFrame()
    discard s.childExited()

proc freshRaw*(s: TtySession): string =
  ## Raw bytes that arrived since the last successful `expect` match: the
  ## tail of `s.raw` past `rawConsumedLen`. This lets repeated flows match
  ## text that re-appears each iteration (e.g. wizard prompts in a stress
  ## loop) without latching onto stale bytes from a previous iteration.
  if s.rawConsumedLen >= s.raw.len:
    ""
  else:
    s.raw[s.rawConsumedLen ..< s.raw.len]

proc advanceRawMark*(s: TtySession) =
  s.rawConsumedLen = s.raw.len

proc waitForOutput*(s: TtySession; timeoutMs = 5000; recordFrame = true): bool =
  ## Block until the child produces new output (PTY bytes or a frame event),
  ## or the timeout/deadline hits. This is the deterministic sync primitive:
  ## instead of polling on wall-clock, we wait for the child to actually emit
  ## something. PTY byte arrival is the ground-truth signal that the child
  ## rendered new state; frame events are an additional explicit sync point
  ## the child can emit at boundaries with no visible output.
  ##
  ## `pollOnce` watches both fds: the PTY master fd (bytes the child wrote)
  ## and the frame-event fd (explicit sync signal). Either one wakes us.
  ## Returns false on timeout or child exit. When `recordFrame` is false,
  ## SyncEnd-driven frame commits are suppressed so screen-state `expect*`
  ## procs can poll without committing non-deterministic intermediate frames.
  let deadline = epochTime() + timeoutMs.float / 1000.0
  let wasPaused = s.frameRecordingPaused
  if not recordFrame:
    s.frameRecordingPaused = true
  while epochTime() < deadline and not s.exited:
    if s.pollOnce(200, recordIdleFrame = false):
      if not recordFrame:
        s.frameRecordingPaused = wasPaused
      return true
  if not recordFrame:
    s.frameRecordingPaused = wasPaused
  false

proc drain*(s: TtySession; settleMs = 20; recordFrame = true) =
  ## Capture any bytes currently ready on the PTY. When `recordFrame` is true,
  ## every SyncEnd-wrapped render is committed as its own frame as it arrives,
  ## so the frame sequence is the child's deterministic sequence of sync-wrapped
  ## renders regardless of how the settle loop's poll timing slices the bytes.
  ## (Suppressing these commits and force-flushing one merged frame instead meant
  ## a render arriving *during* a drain got folded in while the same render
  ## arriving *between* drains became its own frame — same content, different
  ## partitioning, flaky golden comparison.) The trailing force-flush catches any
  ## pending state not closed by a SyncEnd. When `recordFrame` is false, no frame
  ## is committed (used by `expect*` procs, which poll screen state).
  let wasPaused = s.frameRecordingPaused
  if not recordFrame:
    s.frameRecordingPaused = true
  let deadline = epochTime() + settleMs.float / 1000.0
  while epochTime() < deadline and not s.exited:
    discard s.pollOnce(1, false)
  while s.pollOnce(0, false):
    discard
  s.frameRecordingPaused = wasPaused
  if recordFrame:
    s.flushFrame(force = true)

proc resize*(s: TtySession; cols, rows: int): bool {.discardable.} =
  ## Resize the PTY and send SIGWINCH to the child. POSIX only.
  s.flushFrame(force = true)
  s.grid.width = max(1, cols)
  s.grid.height = max(1, rows)
  # Real terminals clamp the cursor into the new viewport on a height change
  # (and scroll content up to keep the cursor in view). The ttty grid only
  # stores width/height and leaves the cursor row untouched, so without this
  # clamp the child's next relative repaint walks up from a row that has been
  # left below the visible area — the same "wall of chrome" bug a real
  # terminal avoids by repositioning the cursor. Mirror that here.
  if s.grid.row >= s.grid.height:
    s.grid.row = max(0, s.grid.height - 1)
  if s.grid.col >= s.grid.width:
    s.grid.col = max(0, s.grid.width - 1)
  s.markFrameDirty()
  when defined(windows):
    # ResizePseudoConsole replaces the TIOCSWINSZ ioctl; ConPTY signals the
    # size change to the child internally (no SIGWINCH equivalent needed).
    result = resizePseudoConsole(s.hpc,
        COORD(x: cols.int16, y: rows.int16)) == 0
  else:
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
  ## Start `bin` under a real PTY (POSIX) or Pseudo Console (Windows) with an
  ## isolated environment.
  ##
  ## `env` is the complete child environment, except TERM is defaulted to
  ## xterm-256color when not provided. Pass an absolute `bin` path unless the
  ## supplied env intentionally includes PATH for execv callers.
  when defined(windows):
    # Five inheritable anonymous IPC pipes (mirroring the POSIX pipe pairs):
    #   framePipe        : child writes 'f' to signal a render boundary
    #   ackPipe          : parent acks each frame event
    #   tickerPipe       : parent drives one spinner frame
    #   tickerAckPipe    : child acks a spinner frame
    #   apiContinuePipe  : parent releases a blocked stub response
    # On Windows the child-side handlers for these are currently POSIX-gated
    # in src/ (see docs/windows-testing.md), so the frame-event/ticker waits
    # in the harness timeout (bounded) and tests settle via drain() polling.
    # The pipes are wired now so enabling the child side later needs no
    # harness change.
    proc makePipe(readEnd, writeEnd: var Handle) =
      var sa = SECURITY_ATTRIBUTES(nLength: sizeof(SECURITY_ATTRIBUTES).int32,
                                   bInheritHandle: 1)
      doAssert createPipe(readEnd, writeEnd, sa, 0) != 0
      # The read end is kept by the parent; mark it non-inheritable so only
      # the intended write end crosses into the child (and vice versa).
      discard setHandleInformation(readEnd, HANDLE_FLAG_INHERIT, 0)

    var pttyInRead, pttyInWrite, pttyOutRead, pttyOutWrite: Handle
    var sa = SECURITY_ATTRIBUTES(nLength: sizeof(SECURITY_ATTRIBUTES).int32,
                                 bInheritHandle: 1)
    doAssert createPipe(pttyInRead, pttyInWrite, sa, 0) != 0
    doAssert createPipe(pttyOutRead, pttyOutWrite, sa, 0) != 0
    # The ConPTY master side keeps pttyInWrite (to send input to the child)
    # and pttyOutRead (to read child output); the slave ends (pttyInRead,
    # pttyOutWrite) are handed to the pseudoconsole and must NOT be inherited
    # by the child process directly.
    discard setHandleInformation(pttyInWrite, HANDLE_FLAG_INHERIT, 0)
    discard setHandleInformation(pttyOutRead, HANDLE_FLAG_INHERIT, 0)

    var hpc: HPCON
    doAssert createPseudoConsole(
        COORD(x: cols.int16, y: rows.int16),
        pttyInRead, pttyOutWrite, 0, addr hpc) == 0
    # Close the PTY-slave ends now: CreatePseudoConsole holds its own copy,
    # and if these inheritable handles stay open they get inherited by the
    # child (bInheritHandles=TRUE), giving it raw duplicates of the
    # pseudoconsole pipes alongside the pseudoconsole attachment itself.
    # That duplicate-attachment fails console init with
    # STATUS_DLL_INIT_FAILED (0xC0000142) — even for cmd.exe. This matches
    # the canonical CreatePseudoConsole sample, which closes these here.
    discard closeHandle(pttyInRead)
    discard closeHandle(pttyOutWrite)

    var frameRead, frameWrite, ackRead, ackWrite: Handle
    var tickerRead, tickerWrite, tickerAckRead, tickerAckWrite: Handle
    var apiRead, apiWrite: Handle
    makePipe(frameRead, frameWrite)
    makePipe(ackRead, ackWrite)
    makePipe(tickerRead, tickerWrite)
    makePipe(tickerAckRead, tickerAckWrite)
    makePipe(apiRead, apiWrite)
    # Invert inheritance on the ends the child keeps, so makePipe's default
    # (parent keeps read end) is corrected per-pipe: the child needs the
    # write ends of frame/tickerAck and the read ends of ack/ticker/api.
    discard setHandleInformation(frameWrite, HANDLE_FLAG_INHERIT,
                                 HANDLE_FLAG_INHERIT)
    discard setHandleInformation(ackRead, HANDLE_FLAG_INHERIT,
                                 HANDLE_FLAG_INHERIT)
    discard setHandleInformation(tickerRead, HANDLE_FLAG_INHERIT,
                                 HANDLE_FLAG_INHERIT)
    discard setHandleInformation(tickerAckWrite, HANDLE_FLAG_INHERIT,
                                 HANDLE_FLAG_INHERIT)
    discard setHandleInformation(apiRead, HANDLE_FLAG_INHERIT,
                                 HANDLE_FLAG_INHERIT)

    result = TtySession(
      masterFd: pttyOutRead,
      masterWriteFd: pttyInWrite,
      hpc: hpc,
      grid: newGrid(),
      started: epochTime(),
      keepHistory: keepHistory,
      exitCode: -1,
      frameEventFd: frameRead,
      frameAckFd: ackWrite,
      tickerCommandFd: tickerWrite,
      tickerAckFd: tickerAckRead,
      apiContinueFd: apiWrite)

    # Build the STARTUPINFOEX with a PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE
    # attribute so CreateProcess attaches the child to this pseudoconsole.
    var attrSize: SIZE_T = 0
    discard initializeProcThreadAttributeList(nil, 1, 0, addr attrSize)
    # The attribute list buffer must be zero-initialized: InitializeProcThread-
    # AttributeList writes its header but leaves trailing slack uninitialized,
    # and CreateProcessW reads it back as part of STARTUPINFOEX — garbage in
    # there can corrupt the pseudoconsole attach.
    var attrList = cast[pointer](alloc0(attrSize))
    doAssert initializeProcThreadAttributeList(attrList, 1, 0, addr attrSize) != 0
    doAssert updateProcThreadAttribute(attrList, 0,
        PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, cast[pointer](unsafeAddr hpc),
        sizeof(HPCON).SIZE_T, nil, nil) != 0

    var si = STARTUPINFOEX(startupInfo: STARTUPINFO(cb: sizeof(STARTUPINFOEX).int32))
    si.lpAttributeList = attrList
    # The child's environment: re-seed from `env` (TERM defaulted), plus the
    # IPC pipe handles as integers. The child reads these to find its pipes.
    # Unlike the POSIX fork path (which wipes the parent env then re-seeds),
    # the Windows child needs the parent's system variables for DLL
    # resolution — without SystemRoot/windir the loader cannot find system
    # DLLs and the child dies with STATUS_DLL_INIT_FAILED (0xC0000142).
    # Start from the caller's `env` (test isolation), then inherit any
    # system vars that DLL resolution or the runtime needs if the caller
    # did not override them.
    # An empty `env` means "inherit the parent environment entirely" — leave
    # envBlock empty so createProcessW gets a NULL lpEnvironment (and the
    # IPC FD vars are skipped). Otherwise build a double-null-terminated
    # UTF-16 block from `env` plus inherited system vars and the IPC FDs.
    var envBlock = ""
    if env.len > 0:
      var hasTerm = false
      for item in env:
        if item.key == "TERM":
          hasTerm = true
        envBlock.add item.key & "=" & item.val & "\0"
      if not hasTerm:
        envBlock.add "TERM=xterm-256color\0"
      # Inherit critical Windows system vars the loader/runtime depend on.
      # These are safe to carry (they identify the OS install, not test state);
      # the test's own isolation uses XDG_DATA_HOME etc., not these.
      for sysKey in ["SystemRoot", "windir", "TEMP", "TMP", "COMSPEC",
                     "PATHEXT", "APPDATA", "LOCALAPPDATA", "PROGRAMDATA",
                     "USERPROFILE"]:
        var present = false
        for item in env:
          if item.key.cmpIgnoreCase(sysKey) == 0:
            present = true
            break
        if not present:
          let sysVal = getEnv(sysKey)
          if sysVal.len > 0:
            envBlock.add sysKey & "=" & sysVal & "\0"
      # PATH must be present for the child to resolve DLLs via the standard
      # search path; inherit it unless the caller explicitly set one.
      var hasPath = false
      for item in env:
        if item.key.cmpIgnoreCase("PATH") == 0:
          hasPath = true
          break
      if not hasPath and getEnv("PATH").len > 0:
        envBlock.add "PATH=" & getEnv("PATH") & "\0"
      envBlock.add "THREECODE_TEST_FRAME_FD=" & $frameWrite.int & "\0"
      envBlock.add "THREECODE_TEST_FRAME_ACK_FD=" & $ackRead.int & "\0"
      envBlock.add "THREECODE_TEST_TICKER_FD=" & $tickerRead.int & "\0"
      envBlock.add "THREECODE_TEST_TICKER_ACK_FD=" & $tickerAckWrite.int & "\0"
      envBlock.add "THREECODE_TEST_API_CONTINUE_FD=" & $apiRead.int & "\0\0"

    var pi: PROCESS_INFORMATION
    # CommandLine is the program + args as a single UTF-16 string; the app
    # name is passed separately so we don't need to quote the binary path.
    var cmd = bin
    for a in args:
      cmd.add " " & a.quoteShell()
    let cmdW = newWideCString(cmd)
    # Keep the wide objects alive across the createProcessW call (the
    # converter hands createProcessW a raw pointer into their storage).
    let appW = newWideCString(bin)
    # An empty env block means "inherit the parent's environment entirely"
    # (lpEnvironment = NULL): pass no env pointer and drop the
    # CREATE_UNICODE_ENVIRONMENT flag. This is also the cleanest test of
    # whether a constructed env block is the cause of a 0xC0000142 child.
    var envPtr: WideCString = nil
    var envObj: WideCStringObj
    var createFlags = EXTENDED_STARTUPINFO_PRESENT
    if envBlock.len > 0:
      envObj = newWideCString(envBlock)
      envPtr = envObj
      createFlags = createFlags or CREATE_UNICODE_ENVIRONMENT
    # The child's working directory defaults to the parent's (NULL
    # lpCurrentDirectory) when cwd is empty; the child then finds DLLs via
    # the exe directory (always first in the search order) just as it does
    # when launched standalone.
    var cwdW: WideCStringObj
    var cwdPtr: WideCString = nil
    if cwd.len > 0:
      cwdW = newWideCString(cwd)
      cwdPtr = cwdW
    # bInheritHandles MUST be FALSE for a ConPTY child. The canonical
    # CreatePseudoConsole sample passes FALSE; passing TRUE causes the child
    # to inherit handles that conflict with the pseudoconsole attachment,
    # and the child's console/DLL init fails with STATUS_DLL_INIT_FAILED
    # (0xC0000142) — even cmd.exe, even with a fully inherited env.
    # This is safe because the child-side IPC hooks (emitTestFrameEvent etc.)
    # are POSIX-gated in src/, so the Windows child does not use the IPC
    # pipes set in its env; it settles via drain() polling instead.
    let ok = createProcessW(appW, cmdW, nil, nil, 0,
        createFlags, envPtr, cwdPtr, si.startupInfo, pi)
    deleteProcThreadAttributeList(attrList)
    dealloc(attrList)
    doAssert ok != 0, "CreateProcessW failed: " & $getLastError()
    result.hProcess = pi.hProcess
    result.hThread = pi.hThread
    result.dwProcessId = pi.dwProcessId
    # Close the child-side IPC pipe ends in the parent; the child has its
    # own duplicates via inheritance. Closing here ensures the parent's read
    # on the master returns EOF when the child exits (no lingering write
    # end). The PTY-slave ends (pttyInRead/pttyOutWrite) were already closed
    # right after CreatePseudoConsole above.
    discard closeHandle(frameWrite)
    discard closeHandle(ackRead)
    discard closeHandle(tickerRead)
    discard closeHandle(tickerAckWrite)
    discard closeHandle(apiRead)
    result.rememberFrame()
  else:
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
      clearEnv()

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
  # Bounded write: if the child has deadlocked and stopped reading stdin,
  # the PTY input buffer fills and a plain write() blocks forever, hanging
  # the whole testament category. Poll for writability first; a child that
  # can't drain within a short window is treated as dead and the test fails
  # its next assertion cleanly instead of hanging.
  if not s.exited:
    when defined(windows):
      # Bounded write: anonymous pipe writes complete synchronously for small
      # buffers (keystrokes), but a child that has deadlocked and stopped
      # reading can fill the pipe buffer and block forever. We rely on the
      # child's ConPTY host thread to drain; the settle below times out if it
      # doesn't, failing the next assertion cleanly instead of hanging.
      var written: int32 = 0
      discard writeFile(s.masterWriteFd, text[0].unsafeAddr, text.len.int32,
                        addr written, nil)
    else:
      var wfd: TPollfd
      wfd.fd = s.masterFd
      wfd.events = POLLOUT
      if poll(addr wfd, 1.Tnfds, 2000.cint) > 0:
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
    # Pause SyncEnd-driven frame commits for the whole send: the child's
    # per-keystroke editor repaints are non-deterministic in count (the PTY
    # driver may batch or split the bytes), so capturing them as frames
    # introduces drift. Recording stays paused through the settle below so
    # late repaints still in flight (and any submit render from a trailing
    # \n in the same send) are fed to the grid but never committed as
    # intermediate frames; only the final settled state is committed.
    s.frameRecordingPaused = true
    while epochTime() < deadline and
        printable notin s.currentRows().join("\n") and printable notin s.raw:
      discard s.pollOnce(20, recordIdleFrame = false)
  else:
    # Control sequence (Ctrl-C, ESC, \n submit): no printable echo to wait
    # for. Block for the first output byte (up to 1s). Recording stays
    # unpaused so the child's sync-wrapped commit render is captured as
    # frames during the settle below.
    discard s.waitForOutput(1000)
    # Drain until the child goes quiet: a control sequence like Ctrl-C can
    # trigger multiple sync-wrapped render bursts (interrupt notice, prompt
    # repaint) with small inter-burst gaps. Poll with a short wait and keep
    # going while bytes keep arriving; only stop when a poll returns nothing.
    # 1s cap is a dead-child safety net, not pacing.
    let ctrlSettleDeadline = epochTime() + 1.0
    while epochTime() < ctrlSettleDeadline and not s.exited:
      if not s.pollOnce(10, recordIdleFrame = false):
        # One more poll at 0ms to catch a final byte that arrived in the
        # gap, then stop.
        discard s.pollOnce(0, recordIdleFrame = false)
        break
    s.flushFrame(force = true)
    return
  # Printable settle: pause SyncEnd-driven frame commits so per-keystroke
  # repaints are fed to the grid but never committed as intermediate frames;
  # only the final settled state is committed. Late repaints in flight (and
  # any submit render from a trailing \n in the same send) land here too.
  let settleDeadline = epochTime() + 0.05
  while epochTime() < settleDeadline and not s.exited:
    if not s.pollOnce(5, recordIdleFrame = false):
      break
  s.frameRecordingPaused = false
  s.flushFrame(force = true)

proc advanceTicker*(s: TtySession) =
  ## Deterministically advance one live spinner/ticker frame in the child.
  ## The ack read is bounded: a child that already exited (ticker thread
  ## gone) or is starved under CI load can't service the ack, and an
  ## unbounded read would hang the whole testament category. We poll the
  ## ack fd with a timeout; on timeout we just proceed — a missing spinner
  ## frame surfaces as a failed assertion downstream, not an infinite hang.
  if not fdValid(s.tickerCommandFd) or not fdValid(s.tickerAckFd):
    return
  if s.exited:
    return
  when defined(windows):
    var ch = 't'
    var written: int32 = 0
    discard writeFile(s.tickerCommandFd, addr ch, 1, addr written, nil)
    # Bounded ack wait: poll PeekNamedPipe for the ack byte (anonymous pipe
    # handles are not waitable), never blocking indefinitely.
    let ackDeadline = epochTime() + 2.0
    while epochTime() < ackDeadline:
      if pipeBytesAvail(s.tickerAckFd) > 0:
        var ack: array[1, char]
        var got: int32 = 0
        discard readFile(s.tickerAckFd, addr ack[0], 1, addr got, nil)
        break
      sleep(1)
  else:
    var ch = 't'
    discard posix.write(s.tickerCommandFd, addr ch, 1)
    var pfd: TPollfd
    pfd.fd = s.tickerAckFd
    pfd.events = POLLIN
    if poll(addr pfd, 1.Tnfds, 2000.cint) > 0:
      var ack: array[1, char]
      discard posix.read(s.tickerAckFd, addr ack[0], 1)
  s.drain(20, recordFrame = true)

proc continueStubApi*(s: TtySession) =
  ## Release a stub response blocked on waitForTestContinue.
  if not fdValid(s.apiContinueFd):
    return
  var ch = 'c'
  when defined(windows):
    var written: int32 = 0
    discard writeFile(s.apiContinueFd, addr ch, 1, addr written, nil)
  else:
    discard posix.write(s.apiContinueFd, addr ch, 1)

proc ctrlC*(s: TtySession) =
  s.send "\x03"

proc ctrlD*(s: TtySession) =
  s.send "\x04"

proc signal*(s: TtySession; sig: cint) =
  ## POSIX-only: Windows has no signal API; ConPTY tests use ctrlC/ctrlD
  ## (byte-level input) instead. The `sig` argument is a POSIX signal number.
  when defined(posix):
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
  writeFile(path & ".raw", s.cleanRaw())

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
  ## Replace any animated spinner phase glyph at the start of a row with the
  ## canonical solid `⣿`. The phase is timing-dependent (which animation
  ## frame the capture landed on) and must never break a golden comparison,
  ## so this collapses all phases unconditionally — not only when an elapsed
  ## token happens to trail the glyph.
  result = row
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
  const marker = "testdata/output/tty/"
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

proc isPromptRow(row: string): bool =
  row.strip(leading = true).startsWith("❯")

proc onlyPromptDiffers(prev, cur: seq[string]): bool =
  if prev.len != cur.len: return false
  var found = false
  for i in 0 ..< cur.len:
    if prev[i] != cur[i]:
      if found or not isPromptRow(cur[i]): return false
      found = true
  found

proc promptDifferingRow(prev, cur: seq[string]): string =
  for i in 0 ..< cur.len:
    if prev[i] != cur[i]: return cur[i]
  ""

proc isTypingPrefix(prev, cur, nextRows: seq[string]): bool =
  ## True when `cur` is an intermediate typing state: it differs from `prev`
  ## only in the prompt row, the next frame also differs only in the prompt
  ## row, and the prompt text grows from cur toward next (cur's prompt is a
  ## prefix of next's prompt). These transient per-keystroke repaints are
  ## non-deterministic in count; collapse them to the final typed state.
  if not onlyPromptDiffers(prev, cur): return false
  if not onlyPromptDiffers(cur, nextRows): return false
  let curPrompt = promptDifferingRow(prev, cur).strip(leading = true)
  let nxtPrompt = promptDifferingRow(cur, nextRows).strip(leading = true)
  nxtPrompt.startsWith(curPrompt) and curPrompt.len < nxtPrompt.len

proc meaningfulFrameText*(s: TtySession): string =
  ## Full-frame visual recording suitable for expected-frame review. Every changed
  ## screen state is preserved; adjacent duplicate normalized states are compressed.
  ## Intermediate typing repaints (partial prompt text that grows toward the next
  ## frame) are collapsed to the final typed state, since their count varies with
  ## PTY byte scheduling and is not a content change.
  var lastRows: seq[string]
  randomize()
  var i = 0
  let n = s.frames.len
  while i < n:
    let rows = normalizeFrameRows(s.frames[i].frameRowsWithCursor())
    inc i
    if rows.allRowsEmpty:
      continue
    if rows == lastRows:
      continue
    if i < n:
      let nextRows = normalizeFrameRows(s.frames[i].frameRowsWithCursor())
      if isTypingPrefix(lastRows, rows, nextRows):
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

proc normalizeSpinnerPhases(text: string): string =
  ## Text-level pass over a whole recording: collapse animated spinner phase
  ## glyphs to the canonical `⣿` on every row. Applied symmetrically to both
  ## the fixture and the actual in `expectMeaningfulFrameArtifact`, so a raw
  ## phase captured into either side (the multiline fixture predates
  ## per-row spinner normalization and carries raw `⠋`/`⠙`/`⠹` phases) cannot
  ## break the comparison. The phase is timing noise, not content.
  for line in text.splitLines(keepEol = true):
    result.add line.normalizeSpinnerGlyphs()

proc normalizeWrappedPathTail(text: string): string =
  ## A long skill path that exceeds the 120-col terminal hard-wraps; the
  ## `normalizeTtyRunRoots` prefix redaction collapses the path AFTER capture
  ## but cannot UN-wrap a line the terminal already broke. The wrap point is
  ## deterministic: the skill path always lands as `...implementation.m` + a
  ## lone `d` on the next row. Rejoin such a lone trailing fragment back onto
  ## the line it broke from, applied symmetrically so a captured wrap on either
  ## side of the comparison cannot break the golden match. The split is content
  ## (terminal width), not behavior.
  let lines = text.splitLines(keepEol = true)
  var i = 0
  while i < lines.len:
    let cur = lines[i]
    let curStripped = cur.strip()
    if i + 1 < lines.len and curStripped.endsWith(".m") and
        lines[i + 1].strip() == "d":
      let eol = if cur.endsWith("\n"): "\n" else: ""
      result.add cur[0 ..< cur.len - eol.len] & "d" & eol
      inc i, 2
      continue
    result.add cur
    inc i

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
  doAssert actual.normalizeVersionBanner.normalizeSpinnerPhases.normalizeFrameSeparators.
      normalizeWrappedPathTail.stripFrameBlanks ==
      expected.normalizeVersionBanner.normalizeSpinnerPhases.normalizeFrameSeparators.
      normalizeWrappedPathTail.stripFrameBlanks,
    "full-frame recording differed from expected frames\nexpected: " & expectedPath &
      "\nactual: " & actualPath

proc expect*(s: TtySession; text: string; timeoutMs = 5000): bool {.discardable.} =
  ## Poll for `text` on the live screen or raw byte stream. Frame commits
  ## are suppressed during the wait: `expect` checks screen state and raw
  ## bytes, neither of which needs recorded frames, and the child's initial
  ## editor redraw (which can capture transient state like the idle hint
  ## before the first keystroke clears it) arrives non-deterministically
  ## relative to when the text is found. Suppressing it keeps the frame
  ## list deterministic.
  let deadline = epochTime() + timeoutMs.float / 1000.0
  while epochTime() < deadline:
    s.drain(0, recordFrame = false)
    if text in s.screenText() or text in cleanRaw(s.freshRaw()):
      s.advanceRawMark()
      # Drain any output that arrived while searching (e.g. the initial
      # editor redraw's SyncEnd) so the grid is fully settled before the
      # caller's next action. Without this, a `send` immediately after
      # `expect` can race the child's first redraw: the typing echo may
      # arrive before the redraw commits, leaving the cursor on the wrong
      # row and causing the first keystroke's editor move-up to clear a
      # row it shouldn't (the idle hint).
      s.drain(20, recordFrame = false)
      return true
    if s.exited:
      s.drain(20, recordFrame = false)
      if text in s.screenText() or text in cleanRaw(s.freshRaw()):
        s.advanceRawMark()
        return true
      return false
    let remaining = max(1, int((deadline - epochTime()) * 1000))
    discard s.waitForOutput(remaining, recordFrame = false)
  doAssert false, "expected text not found: " & text & "\n" &
    s.dumpFramesAround(text)

proc expectNo*(s: TtySession; text: string; settleMs = 250): bool {.discardable.} =
  let deadline = epochTime() + settleMs.float / 1000.0
  while epochTime() < deadline and not s.exited:
    s.drain(0, recordFrame = false)
    doAssert text notin s.screenText() and text notin s.cleanRaw(),
      "unexpected text found: " & text & "\n" & s.dumpFramesAround(text)
    let remaining = max(1, int((deadline - epochTime()) * 1000))
    discard s.waitForOutput(remaining, recordFrame = false)
  true

proc cursorRowHasText(s: TtySession; text: string): bool =
  ## Check the live grid (not a stale frame) for text on the cursor row.
  ## The child's token-bar repaint can erase the prompt row after typing,
  ## so a committed frame may not capture the echoed text. Checking the
  ## live grid catches the text if it's currently visible, and checking
  ## fresh raw bytes catches it if it was echoed but later erased.
  let rows = s.currentRows()
  if not s.grid.cursorHidden and s.grid.row >= 0 and
      s.grid.row < rows.len and text in rows[s.grid.row]:
    return true
  # The text may have been echoed (in raw) but erased from the grid by
  # a token-bar repaint. If it's in the fresh raw bytes, the editor was
  # alive and processing input.
  text in cleanRaw(s.freshRaw())

proc expectTypedAtPrompt*(s: TtySession; text: string;
                           timeoutMs = 5000): bool {.discardable.} =
  ## Verify typed text is live at the prompt: caret visible and the text
  ## present on the cursor row. Catches the regression where an interrupt
  ## leaves the prompt painted but the editor dead — `send` writes bytes to
  ## the pty but nothing repaints, so the text never appears on the cursor row.
  let deadline = epochTime() + timeoutMs.float / 1000.0
  while epochTime() < deadline and not s.exited:
    s.drain(0, recordFrame = false)
    if s.cursorRowHasText(text):
      return true
    let remaining = max(1, int((deadline - epochTime()) * 1000))
    discard s.waitForOutput(remaining, recordFrame = false)
  doAssert false, "typed text not live at prompt: " & text & "\n" &
    s.dumpFramesAround(text)

proc expectInHistory*(s: TtySession; text: string; timeoutMs = 5000): bool {.discardable.} =
  let deadline = epochTime() + timeoutMs.float / 1000.0
  while epochTime() < deadline:
    s.drain(0, recordFrame = false)
    if text in s.historyText() or text in s.cleanRaw():
      return true
    let remaining = max(1, int((deadline - epochTime()) * 1000))
    discard s.waitForOutput(remaining, recordFrame = false)
  doAssert false, "expected history text not found: " & text & "\n" &
    s.dumpFramesAround(text)

proc expectNeverInHistory*(s: TtySession; text: string) =
  s.drain(20, recordFrame = false)
  doAssert text notin s.historyText() and text notin s.cleanRaw(),
    "unexpected history text found: " & text & "\n" & s.dumpFramesAround(text)

proc expectExit*(s: TtySession; code: int; timeoutMs = 5000): bool {.discardable.} =
  let deadline = epochTime() + timeoutMs.float / 1000.0
  while epochTime() < deadline:
    s.drain(0, recordFrame = false)
    if s.exited:
      doAssert s.exitCode == code, &"expected exit code {code}, got {s.exitCode}"
      return true
    let remaining = max(1, int((deadline - epochTime()) * 1000))
    discard s.waitForOutput(remaining, recordFrame = false)
  doAssert false, &"expected process exit code {code}, still running"

proc expectAlive*(s: TtySession;
    msg = "REGRESSION (premature exit): the REPL exited mid-session. " &
           "This is the 'fix premature exit' bug class. " &
           "The process must stay alive across every interaction.") =
  s.drain(0, recordFrame = false)
  if s.exited:
    doAssert false, msg & "\nexit code: " & $s.exitCode & "\n" &
      s.dumpFramesAround("")

proc expectIdleCaret*(s: TtySession; timeoutMs = 5000) =
  ## Wait for the turn to fully end: the caret is visible again (the cursor is
  ## hidden for the whole turn by `beginTurn`, shown again by `endTurn`) and
  ## sits on the live `❯` prompt row. This is the reliable turn-completion
  ## signal under eager streaming, where content and the prompt glyph both
  ## appear mid-turn, so `expect "❯"` and content-count checks can fire while
  ## the turn is still running and race the next send.
  let deadline = epochTime() + timeoutMs.float / 1000.0
  while epochTime() < deadline and not s.exited:
    s.drain(0, recordFrame = false)
    if s.cursorRowHasText("\u276f"):
      return
    let remaining = max(1, int((deadline - epochTime()) * 1000))
    discard s.waitForOutput(remaining, recordFrame = false)
  doAssert false, "turn did not reach idle (caret not visible on prompt):\n" &
    s.dumpFramesAround("")

proc expectPromptLive*(s: TtySession; timeoutMs = 5000): bool {.discardable.} =
  ## Assert the prompt is present AND the process is still alive. Catches the
  ## regression where a turn repaints the prompt but the child has already died.
  discard s.expect("\u276f", timeoutMs)
  s.expectAlive()
  true

proc countIn*(s: TtySession; text: string;
              where = "history"): int =
  ## Count non-overlapping occurrences of `text` in the chosen view.
  ## `where` is "screen" (live grid), "history" (recorded frames), or
  ## "raw" (cleaned raw byte stream).
  let hay =
    case where
    of "screen": s.screenText()
    of "raw": s.cleanRaw()
    else: s.historyText()
  if text.len == 0:
    return 0
  var i = 0
  while i <= hay.len - text.len:
    if hay[i ..< i + text.len] == text:
      inc result
      i += text.len
    else:
      inc i

proc expectCount*(s: TtySession; text: string; n: int;
                  where = "history";
                  timeoutMs = 5000): bool {.discardable.} =
  var last = -1
  let deadline = epochTime() + timeoutMs.float / 1000.0
  while epochTime() < deadline:
    s.drain(0, recordFrame = false)
    last = s.countIn(text, where)
    if last == n:
      return true
    if s.exited:
      s.drain(20, recordFrame = false)
      last = s.countIn(text, where)
      return last == n
    let remaining = max(1, int((deadline - epochTime()) * 1000))
    discard s.waitForOutput(remaining, recordFrame = false)
  doAssert false, &"REGRESSION (duplicate or swallow): expected count {n} of " &
    &"{text} in {where}, got {last}. This is the 'prompt echoed twice / " &
    &"line swallowed' bug class. \n" & s.dumpFramesAround(text)

proc expectOnScreen*(s: TtySession; text: string;
                     timeoutMs = 5000): bool {.discardable.} =
  ## Like `expect` but matches ONLY the live screen grid, never cleanRaw().
  ## Use this to assert text is actually painted on the terminal, not merely
  ## present in the byte stream that scrolled past.
  let deadline = epochTime() + timeoutMs.float / 1000.0
  while epochTime() < deadline:
    s.drain(0, recordFrame = false)
    if text in s.screenText():
      return true
    if s.exited:
      s.drain(20, recordFrame = false)
      return text in s.screenText()
    let remaining = max(1, int((deadline - epochTime()) * 1000))
    discard s.waitForOutput(remaining, recordFrame = false)
  doAssert false, "REGRESSION (render-then-overwrite): expected text not " &
    "found on the live grid: " & text & ". This is the bug class where a " &
    "frame flashes correctly then gets overwritten; the bytes were in the " &
    "raw stream but are no longer visible. \n" & s.dumpFramesAround(text)

proc framePresenceRuns*(s: TtySession; needle: string): int =
  ## Count contiguous runs of frames whose rows contain an exact
  ## (whitespace-stripped) match for `needle`. One run means the row
  ## committed once and was never erased; zero means it never appeared;
  ## more than one means it flickered out and back in (the overwrite bug).
  ## Single-frame gaps are ignored: a transient clear that lasts exactly
  ## one frame (a mid-burst repaint state captured by SyncEnd splitting)
  ## does not count as a real disappearance.
  var wasPresent = false
  var gapLen = 0
  for frame in s.frames:
    var present = false
    for row in frame.rows:
      if row.strip == needle:
        present = true
        break
    if present:
      if not wasPresent and gapLen == 0:
        inc result
      wasPresent = true
      gapLen = 0
    else:
      if wasPresent:
        inc gapLen
      if gapLen > 1:
        wasPresent = false

proc expectRowAppearsOnce*(s: TtySession; text: string): bool {.discardable.} =
  ## Assert a row exactly equal to `text` (after stripping whitespace)
  ## appears in exactly one contiguous run of recorded frames — i.e. it
  ## commits once and is never erased and re-committed. Catches the
  ## scrollback-overwrite regression where a committed row flickers out and
  ## back in. Drain all the frames you care about before calling this.
  let runs = s.framePresenceRuns(text)
  doAssert runs == 1, &"REGRESSION (scrollback overwrite): expected row to " &
    &"appear once (one contiguous run), appeared {runs} times: {text}. This " &
    &"is the bug class where a committed row flickers out and back in. \n" &
    s.dumpFramesAround(text)
  true

proc tokenBarRows(s: TtySession): seq[string] =
  ## Return rows that look like the compact token/status bar.
  for row in s.currentRows():
    if ("↑" in row or "↓" in row or "↻" in row) and "s" in row:
      result.add row

proc expectTokenBar*(s: TtySession; parts: openArray[string];
                     timeoutMs = 5000): bool {.discardable.} =
  let deadline = epochTime() + timeoutMs.float / 1000.0
  while epochTime() < deadline and not s.exited:
    s.drain(0, recordFrame = false)
    for row in s.tokenBarRows():
      var foundAll = true
      for part in parts:
        if part notin row:
          foundAll = false
          break
      if foundAll:
        return true
    let remaining = max(1, int((deadline - epochTime()) * 1000))
    discard s.waitForOutput(remaining, recordFrame = false)
  doAssert false, "expected token bar parts not found: " & @parts.join(", ") &
    "\n" & s.screenText()

proc close*(s: TtySession) =
  if s.closed:
    return
  s.drain(20, recordFrame = false)
  when defined(windows):
    if not s.exited:
      # TerminateProcess replaces kill(SIGTERM). Bounded wait on the process
      # handle (never INFINITE) — a stuck child must not hang the category.
      discard terminateProcess(s.hProcess, 1)
      discard waitForSingleObject(s.hProcess, 500)
      discard s.childExited()
      if not s.exited:
        # Forced reap window: poll GetExitCodeProcess for a short time.
        let reapDeadline = epochTime() + 2.0
        while epochTime() < reapDeadline and not s.exited:
          discard s.childExited()
          sleep(10)
    # Close the pseudoconsole first so the ConPTY host thread exits cleanly,
    # then the pipe handles and the process/thread handles.
    closePseudoConsole(s.hpc)
    discard closeHandle(s.masterFd)
    if s.masterWriteFd.int != 0 and s.masterWriteFd.int != -1:
      discard closeHandle(s.masterWriteFd)
    if fdValid(s.frameEventFd):
      discard closeHandle(s.frameEventFd); s.frameEventFd = 0
    if fdValid(s.frameAckFd):
      discard closeHandle(s.frameAckFd); s.frameAckFd = 0
    if fdValid(s.tickerCommandFd):
      discard closeHandle(s.tickerCommandFd); s.tickerCommandFd = 0
    if fdValid(s.tickerAckFd):
      discard closeHandle(s.tickerAckFd); s.tickerAckFd = 0
    if fdValid(s.apiContinueFd):
      discard closeHandle(s.apiContinueFd); s.apiContinueFd = 0
    if s.hProcess.int != 0 and s.hProcess.int != -1:
      discard closeHandle(s.hProcess)
    if s.hThread.int != 0 and s.hThread.int != -1:
      discard closeHandle(s.hThread)
  else:
    if not s.exited:
      discard kill(s.pid, SIGTERM)
      let deadline = epochTime() + 0.5
      while epochTime() < deadline and not s.exited:
        discard s.pollOnce(20)
      if not s.exited:
        discard kill(s.pid, SIGKILL)
        discard s.pollOnce(20)
      if not s.exited:
        # Bounded reap: a blocking waitpid(0) hangs forever if the child is
        # stuck (e.g. uninterruptible I/O on the PTY under CI load). Poll with
        # WNOHANG for a short window; if still unreaped, leave it — the runner
        # reaps orphans at job end, and an infinite block here hangs the whole
        # testament category.
        var status: cint = 0
        let reapDeadline = epochTime() + 2.0
        while epochTime() < reapDeadline:
          if waitpid(s.pid, status, WNOHANG) == s.pid:
            s.exited = true
            s.exitCode = statusCode(status)
            break
          sleep(10)
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
