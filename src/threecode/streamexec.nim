## Streaming bash execution using osproc.startProcess.
##
## Runs a shell command with stdout piped for line-by-line reading.
## stderr is merged into stdout (2>&1) so it appears inline as it would
## in a real terminal. Each complete line is forwarded to the `onLine`
## callback for live display. Returns the raw merged output and the
## exit code — clipping and post-processing live in `actions.nim`.

import std/[atomics, os, osproc, strformat, strtabs, strutils, tables, terminal, times]
when defined(posix):
  import std/posix except Time
  import std/termios
else:
  import std/streams
import types, util, shell, sandbox
when defined(windows):
  import sandwall/wall as sandwallWall

var wallWarnShown = false  ## one Windows wall warning per run

proc shPath(): string =
  ## POSIX shell path. Android/Termux has no /bin/sh; $PREFIX/bin/sh is
  ## the same dash/bash the interactive shell uses.
  when defined(android):
    getEnv("PREFIX", "/data/data/com.termux/files/usr") & "/bin/sh"
  else:
    "/bin/sh"

when defined(windows):
  var cachedBash* {.threadvar.}: string

  proc bundledMsys2Bash(): string =
    ## The installer drops an MSYS2 tree into the 3code app dir
    ## (`%LOCALAPPDATA%\3code\msys64`), so 3code owns its bash + unix
    ## toolset regardless of what else is on the system. No probing of
    ## system MSYS2 roots or PATH: a single deterministic location.
    result = getEnv("LOCALAPPDATA") & r"\3code\msys64\usr\bin\bash.exe"

  proc toPosixPath(path: string): string =
    ## Convert a Windows path to a POSIX path for MSYS2 bash.
    ## C:\Users\foo -> /c/Users/foo
    result = path.replace('\\', '/')
    if result.len >= 2 and result[1] == ':':
      let drive = result[0].toLowerAscii
      result = "/" & drive & result[2 .. ^1]

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

  let tmp = tempDir() / ("3code_bash_" & $getCurrentProcessId() & "_" & $epochTime().int64)
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
  var p =
    when defined(posix):
      let wrapped = &"exec sh \"{scriptPath}\" <\"{stdinPath}\" 2>&1"
      # Sandbox: when the global sandbox is active, re-exec *this* binary
      # as `3code sandbox restrict ...` so it forks, setsid()s, applies the
      # OS-native restriction (Landlock/Seatbelt), and exec()s sh. box calls
      # setsid() itself before exec, so the sh process is its own
      # session/group leader and the cancel/timeout signal-the-pgroup path
      # still works: we signal box's pid (== sh's pid after exec), the group
      # leader. The backend is compiled in, so `procboxExe` is just our own
      # path and is always set when `active`; the unconfined setsid fallback
      # below only runs when the sandbox is off entirely.
      if sandboxEnabled and sandbox.active and sandbox.procboxExe.len > 0 and
          not sandbox.gathering:
        # The box subprocess loads the policy files itself (--policy), so
        # every launch enforces the freshest file contents; no mtime
        # plumbing needed here. The script + stdin live in a temp dir
        # under getTempDir(); expose it read-only (sh only reads the
        # script, it never writes there). The policy force-read-only and
        # Landlock writability warning live in box.nim.
        discard sandbox.reloadIfChanged(getCurrentDir())
        let policy = sandbox.activePolicyPath(getCurrentDir())
        var args = @["sandbox"]
        args.add ["--policy", policy]
        args.add "restrict"
        # No explicit writable paths: those come from the policy
        # inside box (a fully-locked policy simply yields none, which
        # box accepts). The script temp dir is read-only; sh only reads
        # the script, never writes there.
        args.add ["--ro", tmp]
        args.add "--"
        args.add shPath()
        args.add "-c"
        args.add wrapped
        # Network wall: host rules in the policy mean the box child is
        # fenced; route its traffic through the per-run proxy. The
        # script temp dir also holds the proxy's unix socket, which
        # must sit under a writable rule: the bare `+` of the default
        # policy is the project dir, NOT tmp, so add tmp writable when
        # fencing (only then - the read-only default stands otherwise).
        var env: StringTableRef = nil
        when defined(posix):
          sandbox.moveWallSock(tmp)
          if sandbox.ensureWallProxy(getCurrentDir()):
            # box args: swap the --ro tmp for a writable tmp so the
            # bridge can connect() the unix socket inside the netns.
            args = @[]
            args.add "sandbox"
            args.add ["--policy", policy]
            args.add "restrict"
            args.add tmp
            args.add "--"
            args.add shPath()
            args.add "-c"
            args.add wrapped
            env = newStringTable()  # case-sensitive on posix; env names differ by case
            for k, v in envPairs(): env[k] = v
            for (k, v) in sandbox.wallEnv(sandbox.procboxExe,
                $int(sandbox.wallProxyPort()), sandbox.proxySockPath(),
                getEnv("GIT_SSH_COMMAND", "")):
              env[k] = v
        startProcess(sandbox.procboxExe, args = args, env = env,
                     options = {poStdErrToStdOut, poUsePath})
      else:
        # Unconfined path: sandbox off, no backend, or gather mode.
        # Gather mode additionally records the bash working dir as an
        # `allow` rule: inside the project that is already allowed (a
        # no-op rule), outside it opens the dir the command ran in.
        if sandboxEnabled and sandbox.active and
            sandbox.gathering:
          sandbox.gatherRecordBash(getCurrentDir())
        let setsidExe = findExe("setsid")
        if setsidExe.len > 0:
          startProcess(setsidExe, args = [shPath(), "-c", wrapped],
                       options = {poStdErrToStdOut, poUsePath})
        else:
          startProcess(shPath(), args = ["-c", wrapped],
                       options = {poStdErrToStdOut, poUsePath})
    else:
      let b = resolveBash()
      if b == "":
        return ("bash not found", 127, cap)
      # Windows wall: fencing is keyed on the sandwall user (sandwall
      # wall/wfp.nim), set up once via `3code wall setup-windows`. With
      # host rules but no setup, bash runs unfenced - warn once per run
      # unless `[settings] sandbox_wall_warn = off`.
      if sandboxWallWarn and not wallWarnShown and
          sandbox.active and sandbox.wallProxyNeeded(sandbox.current):
        wallWarnShown = true
        when defined(windows):
          let fenceInstalled = try: sandwallWall.acFenceStatus().installed
                               except CatchableError: false
          if not fenceInstalled:
            stderr.writeLine("3code: policy has host rules but the " &
              "Windows wall is not set up; bash runs unfenced. Run " &
              "`3code wall setup-windows` once as admin. " &
              "(disable this warning: [settings] sandbox_wall_warn = off)")
      # On Windows, we use bash -c with the script file path.
      # We set MSYSTEM, HOME, and PATH using putenv so that bash
      # can find its tools and the user's home directory.
      # We don't pass env to startProcess because that would replace
      # the entire environment (including SYSTEMROOT, WINDIR, etc.)
      # which would cause bash to fail.
      putenv("MSYSTEM", "MSYS")
      putenv("HOME", getEnv("USERPROFILE"))
      let msysBin = getEnv("LOCALAPPDATA") & r"\3code\msys64\usr\bin"
      putenv("PATH", msysBin & ";" & getEnv("PATH"))
      let posixScript = toPosixPath(scriptPath)
      let posixStdin = toPosixPath(stdinPath)
      # Use bash -c to source the script and exit
      let bashCmd = &"source \"{posixScript}\" <\"{posixStdin}\" 2>&1; exit"
      startProcess(b, args = ["-c", bashCmd],
                   options = {poStdErrToStdOut, poUsePath})
  startToolCancelWatcher(p.processID)
  startToolTimeoutWatcher(cap)
  var cancelled = false
  var timedOut = false
  var code = 0

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
    code = p.waitForExit()
    p.close()
    try: removeDir(tmp) except CatchableError: discard

  if cancelled:
    if rawOut.len > 0 and not rawOut.endsWith("\n"):
      rawOut.add "\n"
    rawOut.add ansiForegroundColorCode(fgMagenta) & InterruptedByUserMsg & ansiResetCode
    return (rawOut, 130, cap)
  if timedOut:
    if rawOut.len > 0 and not rawOut.endsWith("\n"):
      rawOut.add "\n"
    return (rawOut, 124, cap)

  # Gather mode ran bash unconfined: scan the output for tool-reported
  # denials (a path in an EACCES message, a host in a connect failure)
  # and append a targeted allow rule per hit. Never a broad grant.
  if sandboxEnabled and sandbox.active and sandbox.gathering:
    sandbox.gatherScanBashOutput(rawOut)

  # Sandbox denial hint: a sandboxed command cannot tell EPERM from the
  # kernel sandbox apart from a plain filesystem permission problem, so
  # a bare "Permission denied" would send the agent retrying blindly.
  # When the policy is enforced and the output smells like EACCES,
  # append a pointer at the policy file. OSError messages are appended
  # after the command's own output, so the hint lands at the end.
  if code != 0 and sandboxEnabled and sandbox.active and
      not sandbox.gathering and
      ("Permission denied" in rawOut or "Operation not permitted" in rawOut):
    if rawOut.len > 0 and not rawOut.endsWith("\n"):
      rawOut.add "\n"
    rawOut.add "sandbox deny, see " & sandbox.sandboxPathInCwd() & "\n"

  return (rawOut, code, cap)
