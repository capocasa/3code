## Streaming bash execution using osproc.startProcess.
##
## Runs a shell command with stdout piped for line-by-line reading.
## stderr is merged into stdout (2>&1) so it appears inline as it would
## in a real terminal. Each complete line is forwarded to the `onLine`
## callback for live display. Returns the raw merged output and the
## exit code — clipping and post-processing live in `actions.nim`.

import std/[atomics, os, osproc, strformat, strutils, tables, terminal, times]
when defined(posix):
  import std/posix except Time
  import std/termios
else:
  import std/streams
import types, util, shell

when defined(windows):
  var cachedBash* {.threadvar.}: string

  proc bundledMsys2Bash(): string =
    ## The installer drops an MSYS2 tree into the 3code app dir
    ## (`%LOCALAPPDATA%\3code\msys64`), so 3code owns its bash + unix
    ## toolset regardless of what else is on the system. No probing of
    ## system MSYS2 roots or PATH: a single deterministic location.
    result = getEnv("LOCALAPPDATA") & r"\3code\msys64\usr\bin\bash.exe"

  proc resolveBash*(): string =
    ## Windows bash resolution. Order: the 3code-owned bundled MSYS2
    ## (the supported, always-present source), then an explicit config
    ## override (`bash_path`) for hyper-users, then nothing (hard-fail
    ## at the startup guard). We never fall back to a system or PATH
    ## bash: the bundled toolset is the whole point.
    if cachedBash.len > 0: return cachedBash
    let bundled = bundledMsys2Bash()
    if fileExists(bundled):
      cachedBash = bundled
      return bundled
    when declared(bashPathOverride):
      if bashPathOverride.len > 0 and fileExists(bashPathOverride):
        cachedBash = bashPathOverride
        return bashPathOverride
    return ""

const PartialLineFlushMs = 700

proc emitCompleteLine(rawOut: var string; lineBuf: var string;
                      onLine: proc(line: string);
                      partialShown: var bool; partialText: var string;
                      suppress: var bool) =
  rawOut.add lineBuf & "\n"
  if onLine != nil and not suppress and
      not (partialShown and partialText == lineBuf):
    onLine(lineBuf)
  lineBuf.setLen(0)
  partialShown = false
  partialText.setLen(0)

proc feedOutputChunk(rawOut: var string; lineBuf: var string; chunk: string;
                     onLine: proc(line: string);
                     partialShown: var bool; partialText: var string;
                     suppress: var bool) =
  for ch in chunk:
    if ch == '\x00':
      suppress = true
      continue
    if ch == '\n':
      emitCompleteLine(rawOut, lineBuf, onLine, partialShown, partialText, suppress)
    elif ch != '\r':
      lineBuf.add ch

proc emitPartialLine(lineBuf: string; onLine: proc(line: string);
                     partialShown: var bool; partialText: var string;
                     suppress: var bool) =
  if onLine != nil and not suppress and lineBuf.len > 0 and
      (not partialShown or partialText != lineBuf):
    onLine(lineBuf)
    partialShown = true
    partialText = lineBuf

proc emitFinalPartial(rawOut: var string; lineBuf: var string;
                      onLine: proc(line: string);
                      partialShown: var bool; partialText: var string;
                      suppress: var bool) =
  if lineBuf.len == 0:
    return
  emitCompleteLine(rawOut, lineBuf, onLine, partialShown, partialText, suppress)

when defined(posix):
  proc readChunk(buf: var array[4096, char]; n: int): string =
    result = newString(n)
    if n > 0:
      copyMem(addr result[0], addr buf[0], n)

  proc readAvailableOutput(p: Process, rawOut: var string;
                           lineBuf: var string;
                           onLine: proc(line: string)) =
    var partialShown = false
    var partialText = ""
    var suppress = false
    var lastActivity = epochTime()
    var processExited = false
    let fd = cint(p.outputHandle)

    while true:
      var pfd: TPollfd
      pfd.fd = fd
      pfd.events = POLLIN or POLLHUP or POLLERR
      let r = poll(addr pfd, 1.Tnfds, 100.cint)
      if r > 0 and (pfd.revents and POLLIN) != 0:
        var buf: array[4096, char]
        let n = posix.read(fd, addr buf[0], buf.len)
        if n > 0:
          feedOutputChunk(rawOut, lineBuf, readChunk(buf, n.int),
                          onLine, partialShown, partialText, suppress)
          lastActivity = epochTime()
        else:
          processExited = true
      elif p.peekExitCode != -1:
        processExited = true

      if lineBuf.len > 0 and
          (epochTime() - lastActivity) * 1000 >= PartialLineFlushMs.float:
        emitPartialLine(lineBuf, onLine, partialShown, partialText, suppress)

      if processExited:
        while true:
          var pfdDrain: TPollfd
          pfdDrain.fd = fd
          pfdDrain.events = POLLIN
          let rd = poll(addr pfdDrain, 1.Tnfds, 0.cint)
          if rd <= 0 or (pfdDrain.revents and POLLIN) == 0:
            break
          var buf: array[4096, char]
          let n = posix.read(fd, addr buf[0], buf.len)
          if n <= 0:
            break
          feedOutputChunk(rawOut, lineBuf, readChunk(buf, n.int),
                          onLine, partialShown, partialText, suppress)
        break

    emitFinalPartial(rawOut, lineBuf, onLine, partialShown, partialText, suppress)

when defined(posix):
  var
    toolCancelStop: Atomic[bool]
    toolCancelHit: Atomic[bool]
    toolCancelPid: Atomic[int]
    toolStdinWatcherEnabled: Atomic[bool]
    toolCancelThread: Thread[void]
    toolCancelActive: bool
    toolCancelOrig: Termios
    toolCancelOrigValid: bool
    # Native bash timeout. We don't depend on an external `timeout`/`gtimeout`
    # binary (absent on stock macOS, which broke every tool call there). A
    # watchdog thread sleeps `cap` seconds, then signals the process group and
    # sets this flag so the read loop bails and the caller maps it to exit 124
    # (GNU timeout's convention).
    toolTimedOut: Atomic[bool]
    toolTimeoutStop: Atomic[bool]
    toolTimeoutThread: Thread[void]
    toolTimeoutCap: Atomic[int]

  toolStdinWatcherEnabled.store(true, moRelaxed)

  proc signalToolProcessTree(pid: int; signal: cint) {.gcsafe.} =
    ## Streamed tools run in their own process group when `setsid` is
    ## available. Signal the group first so wrappers such as `timeout` and
    ## their child shell do not leave the visible tool stuck after Ctrl-C.
    if pid <= 0: return
    discard posix.kill(Pid(-pid), signal)
    discard posix.kill(Pid(pid), signal)

  proc cancelActiveTool*() {.gcsafe.} =
    let pid = toolCancelPid.load(moRelaxed)
    signalToolProcessTree(pid, SIGTERM)

  proc setToolStdinWatcherEnabled*(enabled: bool) {.gcsafe.} =
    toolStdinWatcherEnabled.store(enabled, moRelease)

  proc restoreToolCancelTermios() =
    if toolCancelOrigValid:
      discard tcSetAttr(0.cint, TCSANOW, addr toolCancelOrig)
      toolCancelOrigValid = false

  proc drainToolCancelInput() =
    if isatty(0.cint) == 0: return
    while true:
      var pfd: TPollfd
      pfd.fd = 0.cint
      pfd.events = POLLIN
      let r = poll(addr pfd, 1.Tnfds, 0.cint)
      if r <= 0 or (pfd.revents and POLLIN) == 0:
        break
      var buf: array[64, char]
      let n = posix.read(0.cint, addr buf[0], buf.len)
      if n <= 0:
        break

  proc isAlive(pid: Pid): bool {.inline.} =
    ## Check if a process is still alive using kill(pid, 0).
    posix.kill(pid, 0) == 0

  proc toolCancelLoop() {.thread, nimcall.} =
    while not toolCancelStop.load(moRelaxed):
      var pfd: TPollfd
      pfd.fd = 0.cint
      pfd.events = POLLIN
      let r = poll(addr pfd, 1.Tnfds, 100.cint)
      if r > 0 and (pfd.revents and POLLIN) != 0:
        var buf: array[64, char]
        let n = posix.read(0.cint, addr buf[0], buf.len)
        if n > 0:
          for i in 0 ..< n.int:
            let b = buf[i].uint8
            if b == 0x03 or b == 0x1b:
              toolCancelHit.store(true, moRelaxed)
              cancelActiveTool()
              let pid = toolCancelPid.load(moRelaxed)
              if pid > 0:
                for _ in 0..<20:
                  if not isAlive(Pid(pid)): break
                  sleep(100)
                if isAlive(Pid(pid)):
                  signalToolProcessTree(pid, SIGKILL)
              return

  proc toolTimeoutLoop() {.thread, nimcall.} =
    let deadline = epochTime() + toolTimeoutCap.load(moRelaxed).float
    while not toolTimeoutStop.load(moRelaxed):
      if epochTime() >= deadline:
        let pid = toolCancelPid.load(moRelaxed)
        if pid > 0:
          toolTimedOut.store(true, moRelaxed)
          signalToolProcessTree(pid, SIGTERM)
          sleep(200)
          signalToolProcessTree(pid, SIGKILL)
        return
      sleep(200)

  proc startToolTimeoutWatcher(cap: int) =
    toolTimeoutCap.store(cap, moRelaxed)
    toolTimedOut.store(false, moRelaxed)
    toolTimeoutStop.store(false, moRelaxed)
    createThread(toolTimeoutThread, toolTimeoutLoop)

  proc stopToolTimeoutWatcher(): bool =
    result = toolTimedOut.load(moRelaxed)
    toolTimeoutStop.store(true, moRelaxed)
    try: joinThread(toolTimeoutThread) except CatchableError: discard

  proc startToolCancelWatcher(pid: int) =
    toolCancelPid.store(pid, moRelaxed)
    toolCancelHit.store(false, moRelaxed)
    if not toolStdinWatcherEnabled.load(moAcquire): return
    if toolCancelActive: return
    if isatty(0.cint) == 0: return
    var t: Termios
    if tcGetAttr(0.cint, addr t) != 0: return
    toolCancelOrig = t
    toolCancelOrigValid = true
    t.c_lflag = t.c_lflag and not Cflag(ICANON or ECHO or ISIG)
    t.c_cc[VMIN] = 0.char
    t.c_cc[VTIME] = 0.char
    if tcSetAttr(0.cint, TCSANOW, addr t) != 0:
      toolCancelOrigValid = false
      return
    toolCancelStop.store(false, moRelaxed)
    createThread(toolCancelThread, toolCancelLoop)
    toolCancelActive = true

  proc stopToolCancelWatcher(): bool =
    result = toolCancelHit.load(moRelaxed)
    if toolCancelActive:
      toolCancelStop.store(true, moRelaxed)
      joinThread(toolCancelThread)
      toolCancelActive = false
      drainToolCancelInput()
      restoreToolCancelTermios()
      result = result or toolCancelHit.load(moRelaxed)
    toolCancelPid.store(0, moRelaxed)
else:
  proc cancelActiveTool*() = discard
  proc setToolStdinWatcherEnabled*(enabled: bool) = discard
  proc startToolCancelWatcher(pid: int) = discard
  proc stopToolCancelWatcher(): bool = false
  proc startToolTimeoutWatcher(cap: int) = discard
  proc stopToolTimeoutWatcher(): bool = false

proc localFileSig(path: string): (Time, int) =
  try: (getLastModificationTime(path), getFileSize(path).int)
  except CatchableError: (Time(), 0)

proc runStreamingBash*(act: Action, cache: ReadCache,
                       onLine: proc(line: string) = nil):
    tuple[rawOut: string, code: int, cap: int] =
  let cmd = act.body.strip
  let mutPath = bashMutationPath(cmd)
  let (readPath, fullRead) = bashReadPath(cmd)

  if cache != nil and readPath != "" and fullRead:
    let p = resolvePath(readPath)
    if fileExists(p) and cache.state.hasKey(p) and localFileSig(p) == cache.state[p]:
      return (&"[unchanged since prior read of {p}; see earlier read in this session]", 0, DefaultBashTimeout)

  let tmp = getTempDir() / ("3code_bash_" & $getCurrentProcessId() & "_" & $epochTime().int64)
  createDir(tmp)
  let scriptPath = tmp / "cmd.sh"
  let stdinPath = tmp / "stdin"

  let script = """export PAGER=cat GIT_PAGER=cat PSQL_PAGER=cat MYSQL_PAGER=cat
export LESS= TERM=dumb CI=1 NO_COLOR=1 GIT_TERMINAL_PROMPT=0
export DEBIAN_FRONTEND=noninteractive
""" & cmd & "\n"
  writeFile(scriptPath, script)
  writeFile(stdinPath, act.stdin)

  let cap = bashTimeoutSecs(act.timeoutSecs)
  let wrapped = when defined(windows):
    &". \"{scriptPath}\" <\"{stdinPath}\" 2>&1"
  else:
    &"exec sh \"{scriptPath}\" <\"{stdinPath}\" 2>&1"

  var p =
    when defined(posix):
      let setsidExe = findExe("setsid")
      if setsidExe.len > 0:
        startProcess(setsidExe, args = ["/bin/sh", "-c", wrapped],
                     options = {poStdErrToStdOut, poUsePath})
      else:
        startProcess("/bin/sh", args = ["-c", wrapped],
                     options = {poStdErrToStdOut, poUsePath})
    else:
      let b = resolveBash()
      if b == "":
        return ("bash not found", 127, cap)
      startProcess(b, args = ["-c", wrapped],
                   options = {poStdErrToStdOut, poUsePath})
  startToolCancelWatcher(p.processID)
  startToolTimeoutWatcher(cap)
  var cancelled = false
  var timedOut = false

  var rawOut = ""
  try:
    var lineBuf = ""
    when defined(posix):
      readAvailableOutput(p, rawOut, lineBuf, onLine)
    else:
      let outStream = p.outputStream
      var partialShown = false
      var partialText = ""
      var suppress = false
      while not outStream.atEnd:
        let ch = outStream.readChar()
        if ch == '\x00':
          suppress = true
          continue
        if ch == '\n':
          emitCompleteLine(rawOut, lineBuf, onLine, partialShown, partialText, suppress)
        elif ch != '\r':
          lineBuf.add ch
      emitFinalPartial(rawOut, lineBuf, onLine, partialShown, partialText, suppress)
  finally:
    cancelled = stopToolCancelWatcher()
    timedOut = stopToolTimeoutWatcher()

  let code = p.waitForExit()
  p.close()

  try: removeDir(tmp) except CatchableError: discard

  if cancelled:
    if rawOut.len > 0 and not rawOut.endsWith("\n"):
      rawOut.add "\n"
    rawOut.add ansiForegroundColorCode(fgMagenta) & "interrupted by user" & ansiResetCode
    return (rawOut, 130, cap)
  if timedOut:
    if rawOut.len > 0 and not rawOut.endsWith("\n"):
      rawOut.add "\n"
    return (rawOut, 124, cap)

  return (rawOut, code, cap)
