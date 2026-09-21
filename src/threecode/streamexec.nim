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
  import registry
  import sandwall
  import sandwall/wall as sandwallWall

var wallWarnShown = false  ## one Windows wall warning per run

proc shPath(): string =
  ## POSIX shell path. Android/Termux has no /bin/sh; $PREFIX/bin/sh is
  ## the same dash/bash the interactive shell uses. A `bash_path` or
  ## `bash_source` config value that names an existing file wins, so the
  ## same setting works on every OS.
  when declared(bashPathOverride):
    if bashPathOverride.len > 0 and fileExists(bashPathOverride):
      return bashPathOverride
  when declared(bashSourcePref):
    if bashSourcePref.len > 0 and '/' in bashSourcePref and
        fileExists(bashSourcePref):
      return bashSourcePref
  when defined(android):
    getEnv("PREFIX", "/data/data/com.termux/files/usr") & "/bin/sh"
  else:
    "/bin/sh"

when defined(windows):
  var cachedBash* {.threadvar.}: string

  proc bundledGitRoot*(): string =
    ## Root of the 3code-owned PortableGit tree
    ## (`%LOCALAPPDATA%\3code\git`), dropped by the main-channel
    ## installer. Under a private profile like the legacy MSYS2 tree, so
    ## the sandwall account cannot read it without a runtime grant
    ## (see runStreamingBash).
    result = getEnv("LOCALAPPDATA") & r"\3code\git"

  proc bundledGitBash(): string =
    ## The installer's PortableGit tree ships the same two bashes as a
    ## Git for Windows install: `bin\bash.exe`, a launcher that exports
    ## MSYSTEM and builds a PATH carrying the full unix toolset, and
    ## `usr\bin\bash.exe`, the bare MSYS2 shell. Prefer the launcher
    ## (same rationale as gitForWindowsBash); fall back to the bare
    ## shell.
    let root = bundledGitRoot()
    for b in [root / "bin" / "bash.exe", root / "usr" / "bin" / "bash.exe"]:
      if fileExists(b): return b
    return ""

  proc bundledMsys2Root*(): string =
    ## Root of the 3code-owned MSYS2 tree (`%LOCALAPPDATA%\3code\msys64`).
    ## Under a private profile, so the sandwall account cannot read the
    ## tree in it without an explicit grant; callers stamp that at run
    ## time (see runBash) where the invoking user's own path is known.
    result = getEnv("LOCALAPPDATA") & r"\3code\msys64"

  proc bundledMsys2Bash(): string =
    ## The legacy installer dropped an MSYS2 tree into the 3code app dir
    ## (`%LOCALAPPDATA%\3code\msys64`). Installs from that era keep
    ## working; new installs find bash elsewhere.
    result = bundledMsys2Root() & r"\usr\bin\bash.exe"

  proc systemMsys2Bash(): string =
    ## A standalone MSYS2 install. The installer's default root is
    ## `C:\msys64`; `%ProgramFiles%\msys64` covers a non-default drive
    ## letter chosen in the GUI installer.
    for root in [r"C:\msys64", getEnv("ProgramFiles") / "msys64"]:
      let bash = root / "usr" / "bin" / "bash.exe"
      if fileExists(bash): return bash
    return ""

  proc gitForWindowsRoots(): seq[string] =
    ## Candidate roots of a Git for Windows install, most explicit first.
    ## The registry `InstallPath` is what Git's own installer writes, so
    ## it survives a non-standard install dir; the env-var roots cover the
    ## default install without a registry read and the 32-bit-3code-on-
    ## 64-bit case (a 32-bit process sees `ProgramFiles` as the (x86) tree
    ## but `ProgramW6432` as the real one); `%LOCALAPPDATA%\Programs` is
    ## where a per-user Git lands when installed without admin rights.
    try:
      let reg = getUnicodeValue(r"SOFTWARE\GitForWindows", "InstallPath",
                                HKEY_LOCAL_MACHINE)
      if reg.len > 0: result.add reg
    except CatchableError:
      discard
    for name in ["ProgramFiles", "ProgramW6432", "ProgramFiles(x86)"]:
      let root = getEnv(name)
      if root.len > 0: result.add root / "Git"
    let local = getEnv("LOCALAPPDATA")
    if local.len > 0: result.add local / "Programs" / "Git"

  proc gitForWindowsBash(): string =
    ## Git for Windows ships two bashes: `bin\bash.exe`, a launcher that
    ## exports MSYSTEM and builds a PATH carrying the full unix toolset
    ## plus `git.exe`, and `usr\bin\bash.exe`, the bare MSYS2 shell that
    ## resolves nothing without an explicit PATH. Prefer the launcher;
    ## fall back to the bare shell for portable layouts that lack it.
    let roots = gitForWindowsRoots()
    for root in roots:
      let launcher = root / "bin" / "bash.exe"
      if fileExists(launcher): return launcher
    for root in roots:
      let raw = root / "usr" / "bin" / "bash.exe"
      if fileExists(raw): return raw
    return ""

  proc toPosixPath(path: string): string =
    ## Convert a Windows path to the form MSYS2 bash accepts in every
    ## tree, full or stripped. The historical /c/... form needs an
    ## /etc/fstab cygdrive entry ("none / cygdrive binary,posix=0 0")
    ## that a stripped MinGit-style tree lacks: bash then fails with
    ## "No such file or directory" on the script and stdin paths. A
    ## Windows path with forward slashes (C:/Users/foo) is converted
    ## by the msys runtime itself in all layouts, fstab or not.
    result = path.replace('\\', '/')

  proc bundledRootOf*(bashPath: string): string =
    ## The 3code-owned tree (PortableGit or legacy MSYS2) the resolved
    ## bash lives under, or "" for a system-wide install. The sandwall
    ## account cannot traverse the invoking user's private profile, so
    ## the sandbox stamp in runStreamingBash grants read+execute on
    ## exactly this root, in the user's own context.
    for root in [bundledGitRoot(), bundledMsys2Root()]:
      if root.len > 0 and
          bashPath.toLowerAscii.startsWith(root.toLowerAscii & "\\"):
        return root
    return ""

  proc resolveBash*(): string =
    ## Windows bash resolution, run once at startup. Order: an explicit
    ## config override (`bash_path`) always wins, then the installer's
    ## own PortableGit tree (`%LOCALAPPDATA%\3code\git`, the version the
    ## installer pinned), then Git for Windows (the standard source:
    ## `winget install Git.Git` and 3code has a shell), then a
    ## standalone MSYS2 install, then the legacy 3code-installed MSYS2
    ## tree (deprioritized: the release-channel installer still drops
    ## it, and old installs are in the wild). A `bash_source` setting
    ## pins one source: "bundled-git", "git-for-windows", "msys2", or
    ## "bundled-msys2"; "auto" (the default) keeps the full order.
    ## Returns "" when none is found; the startup guard then warns and
    ## disables the bash tool.
    if cachedBash.len > 0: return cachedBash
    when declared(bashPathOverride):
      if bashPathOverride.len > 0 and fileExists(bashPathOverride):
        cachedBash = bashPathOverride
        return bashPathOverride
    when declared(bashSourcePref):
      let pick = case bashSourcePref
        of "bundled-git": bundledGitBash()
        of "git-for-windows": gitForWindowsBash()
        of "msys2": systemMsys2Bash()
        of "bundled-msys2": bundledMsys2Bash()
        else: ""
      if pick.len > 0 and fileExists(pick):
        cachedBash = pick
        return pick
    for cand in [bundledGitBash(), gitForWindowsBash(), systemMsys2Bash(),
                 bundledMsys2Bash()]:
      if cand.len > 0 and fileExists(cand):
        cachedBash = cand
        return cand
    return ""

const PartialLineFlushMs = 700

type
  LineAcc = object
    ## One physical output line under terminal semantics: `phys` is the
    ## on-screen text, `col` the cursor's column within it. A bare `\r`
    ## (curl's classic progress meter, spinner rewrites) moves the column
    ## home and lets following chars overwrite the line in place instead of
    ## appending — stripping `\r` used to concatenate every meter snapshot
    ## into one unbounded mega-line that outgrew the viewport and flickered.
    phys: string
    col: int

proc feedLineChar(a: var LineAcc; ch: char) =
  if ch == '\r':
    a.col = 0
  else:
    if a.col < a.phys.len:
      a.phys[a.col] = ch
    else:
      a.phys.add ch
    inc a.col

proc emitCompleteLine(rawOut: var string; acc: var LineAcc;
                      onLine: proc(line: string);
                      partialShown: var bool; partialText: var string;
                      suppress: var bool) =
  rawOut.add acc.phys & "\n"
  if onLine != nil and not suppress and
      not (partialShown and partialText == acc.phys):
    onLine(acc.phys)
  acc = LineAcc()
  partialShown = false
  partialText.setLen(0)

proc feedOutputChunk(rawOut: var string; acc: var LineAcc; chunk: string;
                     onLine: proc(line: string);
                     partialShown: var bool; partialText: var string;
                     suppress: var bool) =
  for ch in chunk:
    if ch == '\x00':
      suppress = true
      continue
    if ch == '\n':
      emitCompleteLine(rawOut, acc, onLine, partialShown, partialText, suppress)
    else:
      feedLineChar(acc, ch)

proc emitPartialLine(acc: LineAcc; onLine: proc(line: string);
                     partialShown: var bool; partialText: var string;
                     suppress: var bool) =
  if onLine != nil and not suppress and acc.phys.len > 0 and
      (not partialShown or partialText != acc.phys):
    onLine(acc.phys)
    partialShown = true
    partialText = acc.phys

proc emitFinalPartial(rawOut: var string; acc: var LineAcc;
                      onLine: proc(line: string);
                      partialShown: var bool; partialText: var string;
                      suppress: var bool) =
  if acc.phys.len == 0:
    return
  emitCompleteLine(rawOut, acc, onLine, partialShown, partialText, suppress)

when defined(posix):
  proc readChunk(buf: var array[4096, char]; n: int): string =
    result = newString(n)
    if n > 0:
      copyMem(addr result[0], addr buf[0], n)

  proc readAvailableOutput(p: Process, rawOut: var string;
                           acc: var LineAcc;
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
          feedOutputChunk(rawOut, acc, readChunk(buf, n.int),
                          onLine, partialShown, partialText, suppress)
          lastActivity = epochTime()
        else:
          processExited = true
      elif p.peekExitCode != -1:
        processExited = true

      if acc.phys.len > 0 and
          (epochTime() - lastActivity) * 1000 >= PartialLineFlushMs.float:
        emitPartialLine(acc, onLine, partialShown, partialText, suppress)

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
          feedOutputChunk(rawOut, acc, readChunk(buf, n.int),
                          onLine, partialShown, partialText, suppress)
        break

    emitFinalPartial(rawOut, acc, onLine, partialShown, partialText, suppress)

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
  # Windows tool cancel/timeout. POSIX signals the tool's process group;
  # the Windows equivalent is a Job Object the child is assigned to right
  # after spawn: TerminateJobObject kills the whole tree (bash + every
  # native descendant holding the output pipe open) in one call, and the
  # same handle is the timeout watchdog's lever. The cancel trigger is the
  # input thread (ESC / Ctrl-C during a turn raise InputCancelled ->
  # requestTurnInterrupt -> cancelActiveTool); POSIX additionally peeks
  # raw stdin for 0x03/0x1b, which the Windows console path delivers
  # through the editor instead.
  import std/winlean
  const
    PROCESS_TERMINATE = 0x0001'i32
    PROCESS_SET_QUOTA = 0x0100'i32
  proc createJobObject(lpJobAttributes, lpName: pointer): Handle {.stdcall,
      dynlib: "kernel32", importc: "CreateJobObjectA".}
  proc assignProcessToJobObject(hJob, hProcess: Handle): int32 {.stdcall,
      dynlib: "kernel32", importc: "AssignProcessToJobObject".}
  proc terminateJobObject(hJob: Handle, uExitCode: int32): int32 {.stdcall,
      dynlib: "kernel32", importc: "TerminateJobObject".}
  proc openProcess(dwDesiredAccess, bInheritHandle,
      dwProcessId: int32): Handle {.stdcall, dynlib: "kernel32",
      importc: "OpenProcess".}

  var
    toolJobHandle: Handle = 0
    toolSandwallRun = false
    toolCancelHit: Atomic[bool]
    toolTimedOut: Atomic[bool]
    toolTimeoutStop: Atomic[bool]
    toolTimeoutThread: Thread[void]
    toolTimeoutCap: Atomic[int]

  proc cancelActiveTool*() {.gcsafe.} =
    # Both levers: the startProcess job (plain path) and the sandwall
    # job (in-process CPLW path). toolSandwallRun routes the kill; a
    # terminated sandwall job wakes a caller blocked in waitForExit.
    if toolJobHandle == 0 and not toolSandwallRun:
      return
    toolCancelHit.store(true, moRelaxed)
    if toolSandwallRun:
      interruptActiveRun()
    if toolJobHandle != 0:
      discard terminateJobObject(toolJobHandle, 1'i32)

  proc setToolStdinWatcherEnabled*(enabled: bool) = discard

  proc startToolCancelWatcher(pid: int) =
    # Arm the job for the freshly spawned tool process. The process handle
    # can be dropped once assigned: the job holds its own reference.
    toolCancelHit.store(false, moRelaxed)
    if toolJobHandle != 0:
      discard closeHandle(toolJobHandle)
      toolJobHandle = 0
    let hProc = openProcess(PROCESS_TERMINATE or PROCESS_SET_QUOTA, 0,
                            pid.int32)
    if hProc == 0: return
    let job = createJobObject(nil, nil)
    if job != 0 and assignProcessToJobObject(job, hProc) != 0:
      toolJobHandle = job
    else:
      if job != 0: discard closeHandle(job)
    discard closeHandle(hProc)

  proc stopToolCancelWatcher(): bool =
    result = toolCancelHit.load(moRelaxed)
    if toolJobHandle != 0:
      # A cancel that raced the watcher arming (or a cancel-in-flight)
      # must not leave a live child for waitForExit to block on: kill
      # before releasing the job handle.
      if result: discard terminateJobObject(toolJobHandle, 1'i32)
      discard closeHandle(toolJobHandle)
      toolJobHandle = 0

  proc toolTimeoutLoop() {.thread, nimcall.} =
    let deadline = epochTime() + toolTimeoutCap.load(moRelaxed).float
    while not toolTimeoutStop.load(moRelaxed):
      if epochTime() >= deadline:
        if toolJobHandle != 0 or toolSandwallRun:
          toolTimedOut.store(true, moRelaxed)
          cancelActiveTool()
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

proc localFileSig(path: string): (Time, int) =
  try: (getLastModificationTime(path), getFileSize(path).int)
  except CatchableError: (Time(), 0)

proc runStreamingBash*(act: Action, cache: ReadCache,
                       onLine: proc(line: string) = nil):
    tuple[rawOut: string, code: int, cap: int] =
  # When the OS sandbox backend is unavailable, bash runs unconfined
  # here; that is announced once at startup (see main), not refused.
  let cmd = act.body.strip
  let mutPath = bashMutationPath(cmd)
  let (readPath, fullRead) = bashReadPath(cmd)

  if cache != nil and readPath != "" and fullRead:
    let p = resolvePath(readPath)
    if fileExists(p) and cache.state.hasKey(p) and localFileSig(p) == cache.state[p]:
      return (&"[unchanged since prior read of {p} — wasted call; refer to the earlier read instead. Do not re-read to verify; patch/write would have failed if the change had not applied.]", 0, DefaultBashTimeout)

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
      if sandboxEnabled and sandbox.active and sandbox.procboxExe.len > 0:
        # The box subprocess loads the policy files itself (--policy), so
        # every launch enforces the freshest file contents; no mtime
        # plumbing needed here. The script + stdin live in a temp dir
        # under getTempDir(); expose it read-only (sh only reads the
        # script, it never writes there). The policy force-read-only and
        # Landlock writability warning live in box.nim.
        discard sandbox.reloadIfChanged(getCurrentDir())
        # A file only: when neither repo nor user policy exists, the
        # built-in default is materialized under tempDir() (which the
        # default itself leaves writable), never into the user config.
        let policy = sandbox.defaultPolicyFilePath(getCurrentDir())
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
        # Unconfined path: sandbox off or no working backend.
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
        return ("bash tool disabled: no bash found. Install Git for " &
                "Windows: https://git-scm.com/download/win", 127, cap)
      # On Windows, we use bash -c with the script file path.
      # We set MSYSTEM, HOME, and PATH using putenv so that bash
      # can find its tools and the user's home directory.
      # We don't pass env to startProcess because that would replace
      # the entire environment (including SYSTEMROOT, WINDIR, etc.)
      # which would cause bash to fail.
      putenv("MSYSTEM", "MSYS")
      # HOME for the sandboxed child is the per-run tmp: sandwall cannot
      # read the invoking user's profile. HISTFILE is discarded so bash
      # never writes history there. Do not rewrite USERPROFILE: Nim
      # getHomeDir / collapseHome must keep pointing at the real user.
      putenv("HOME", tmp)
      putenv("HISTFILE", "/dev/null")
      putenv("HISTSIZE", "0")
      putenv("CHERE_INVOKING", "1")
      putenv("CYGWIN", "nodosfilewarning")
      # Prepend the directory holding the resolved bash so a bare MSYS2
      # `usr\bin` bash (the bundled trees' fallback, a standalone MSYS2,
      # or a `bash_path` override) finds its unix tools. Git's
      # `bin\bash.exe` launcher ignores this and builds its own PATH, so
      # the same line is correct for both.
      let bashBin = b.parentDir
      putenv("PATH", bashBin & ";" & getEnv("PATH"))
      # bash stats /tmp at startup and warns "could not find /tmp,
      # please create!" when it is missing. A full Git for Windows
      # install ships <root>\tmp; a stripped MinGit-style tree does
      # not, and without /etc/fstab the msys runtime falls back to
      # the root-relative dir. Create it once per tree (idempotent,
      # no-op when present). A system-wide install under Program
      # Files may deny the write; the warning is cosmetic there, so
      # ignore the failure.
      var msysRoot = bundledRootOf(b)
      if msysRoot.len == 0:
        # A system-wide tree: the msys root is the bash dir's
        # great-grandparent (usr\bin\bash.exe -> root) or
        # grandparent (bin\bash.exe -> root).
        var d = b.parentDir
        for _ in 1..2:
          if d.parentDir.len == 0: break
          d = d.parentDir
        msysRoot = d
      if msysRoot.len > 0:
        try:
          createDir(msysRoot / "tmp")
        except CatchableError: discard
      let posixScript = toPosixPath(scriptPath)
      let posixStdin = toPosixPath(stdinPath)
      # Use bash -c to source the script and exit
      let bashCmd = &"source \"{posixScript}\" <\"{posixStdin}\" 2>&1; exit"
      when defined(windows):
        # Windows cannot confine this process; restrict only stamps
        # ACLs. Re-execing 3code.exe just to call restrict+CPLW pays a
        # full Nim+SSL init per command. Call boxMain in-process and
        # capture the named-pipe pump instead.
        if sandboxEnabled and sandbox.active and sandbox.procboxExe.len > 0:
          discard sandbox.reloadIfChanged(getCurrentDir())
          var fenced = false
          if sandbox.wallProxyNeeded(sandbox.current):
            # The cached startup resolution (enum when the token is
            # elevated, behavioral probe otherwise). fenceStatus alone
            # reads as not-installed for a standard user whose engine
            # enum is denied, which used to print the OPEN-network
            # warning on healthy fences and airgap bash behind it.
            let fenceInstalled = sandbox.netFenceState() == sandbox.nfsInstalled
            if fenceInstalled:
              try:
                fenced = sandbox.ensureWallProxy(getCurrentDir())
              except CatchableError:
                fenced = false
            elif sandboxWallWarn and not wallWarnShown:
              wallWarnShown = true
              stderr.writeLine("3code sandbox: WARNING: host rules are " &
                "present but the WFP fence is not installed. The child " &
                "will have OPEN network access. Run '3code setup' once.")
          if fenced:
            for (k, v) in sandbox.wallEnv(sandbox.procboxExe,
                $int(sandbox.wallProxyPort()), "",
                getEnv("GIT_SSH_COMMAND", "")):
              putenv(k, v)
          let resolved = sandbox.current.resolve()
          var writable = resolved.writable
          var readonly = resolved.readonly
          if fenced: writable.add tmp else: readonly.add tmp
          # The sandwall account re-spawns bash out of THIS user's
          # bundled tree (PortableGit or legacy MSYS2), which sits under
          # a private profile the sandwall account cannot traverse. The
          # one-time `setup` grant used the elevated setup account's
          # %LOCALAPPDATA%, which differs whenever a standard user
          # elevated with a separate admin's credentials - so the tree
          # the sandbox actually runs bash from had no ACE and bash died
          # with access denied. Stamp read+execute here, in the invoking
          # user's own context (they own the tree, so no admin needed);
          # sandwall's read list handles the ancestors + skip-when-
          # already-stamped. A system-wide bash needs no stamp.
          let msysRoot = bundledRootOf(b)
          if msysRoot.len > 0 and dirExists(msysRoot):
            readonly.add msysRoot
          sandwallWall.beginCapture()
          var inProcCode = 127
          var cancelledIn = false
          var timedOutIn = false
          toolSandwallRun = true
          startToolCancelWatcher(0)
          startToolTimeoutWatcher(cap)
          try:
            inProcCode = int(runSandboxed(writable, [b, "-c", bashCmd],
                                          read = readonly,
                                          denied = resolved.denied))
          except CatchableError as e:
            discard sandwallWall.endCapture()
            return ("3code sandbox: " & e.msg, 127, cap)
          finally:
            cancelledIn = stopToolCancelWatcher()
            timedOutIn = stopToolTimeoutWatcher()
            toolSandwallRun = false
          let captured = sandwallWall.endCapture()
          var rawIn = ""
          var accIn = LineAcc()
          var partialShownIn = false
          var partialTextIn = ""
          var suppressIn = false
          for ch in captured:
            if ch == '\x00':
              suppressIn = true
              continue
            if ch == '\n':
              emitCompleteLine(rawIn, accIn, onLine, partialShownIn,
                               partialTextIn, suppressIn)
            else:
              feedLineChar(accIn, ch)
          emitFinalPartial(rawIn, accIn, onLine, partialShownIn,
                           partialTextIn, suppressIn)
          try: removeDir(tmp) except CatchableError: discard
          if cancelledIn:
            if rawIn.len > 0 and not rawIn.endsWith("\n"):
              rawIn.add "\n"
            rawIn.add ansiForegroundColorCode(fgMagenta) & InterruptedByUserMsg & ansiResetCode
            return (rawIn, 130, cap)
          if timedOutIn:
            if rawIn.len > 0 and not rawIn.endsWith("\n"):
              rawIn.add "\n"
            return (rawIn, 124, cap)
          if inProcCode != 0 and sandboxEnabled and sandbox.active and
              ("Permission denied" in rawIn or
               "Operation not permitted" in rawIn):
            if rawIn.len > 0 and not rawIn.endsWith("\n"):
              rawIn.add "\n"
            rawIn.add "sandbox deny, see " & sandbox.sandboxPathInCwd() & "\n"
          return (rawIn, inProcCode, cap)
        else:
          if sandboxEnabled and sandboxWallWarn and not wallWarnShown and
              sandbox.active and sandbox.wallProxyNeeded(sandbox.current):
            wallWarnShown = true
            stderr.writeLine("3code: policy has host rules but the " &
              "Windows sandbox is not set up; bash runs unfenced. " &
              "Run `3code setup` once as admin. " &
              "(disable this warning: [settings] sandbox_wall_warn = off)")
          startProcess(b, args = ["-c", bashCmd],
                       options = {poStdErrToStdOut, poUsePath})
      else:
        startProcess(b, args = ["-c", bashCmd],
                     options = {poStdErrToStdOut, poUsePath})
  startToolCancelWatcher(p.processID)
  startToolTimeoutWatcher(cap)
  var cancelled = false
  var timedOut = false
  var code = 0

  var rawOut = ""
  try:
    var acc = LineAcc()
    when defined(posix):
      readAvailableOutput(p, rawOut, acc, onLine)
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
          emitCompleteLine(rawOut, acc, onLine, partialShown, partialText, suppress)
        else:
          feedLineChar(acc, ch)
      emitFinalPartial(rawOut, acc, onLine, partialShown, partialText, suppress)
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

  # Sandbox denial hint: a sandboxed command cannot tell EPERM from the
  # kernel sandbox apart from a plain filesystem permission problem, so
  # a bare "Permission denied" would send the agent retrying blindly.
  # When the policy is enforced and the output smells like EACCES,
  # append a pointer at the policy file. OSError messages are appended
  # after the command's own output, so the hint lands at the end.
  if code != 0 and sandboxEnabled and sandbox.active and
      ("Permission denied" in rawOut or "Operation not permitted" in rawOut):
    if rawOut.len > 0 and not rawOut.endsWith("\n"):
      rawOut.add "\n"
    rawOut.add "sandbox deny, see " & sandbox.sandboxPathInCwd() & "\n"

  return (rawOut, code, cap)
