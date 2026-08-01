import std/[net, os, osproc, posix, strtabs, strutils, times, unittest]
import threecode/session

const binName = when defined(windows): "3code.exe" else: "3code"

proc binPath(): string = getCurrentDir() / binName

proc run(args: openArray[string]): tuple[o: string, code: int] =
  let (outp, code) = execCmdEx(binPath() & " " & args.join(" "))
  return (outp.strip(), code)

suite "cli argument validation":
  test "unknown long option errors":
    let r = run(["--nope"])
    check r.code == 2
    check "unknown option: --nope" in r.o

  test "unknown short option errors":
    let r = run(["-Z"])
    check r.code == 2
    check "unknown option: -Z" in r.o

  test "positional arg with --resume reports session-not-found":
    # A positional arg is no longer a syntax error with --resume; it is the
    # prompt to run once the session is resumed. A bogus id still fails,
    # but as a config error (session not found), not a usage error.
    let r = run(["--resume=does-not-exist", "ignored text"])
    check r.code == 3  # ExitConfig
    check "session not found" in r.o

  test "--interactive accepts a positional prompt":
    # --interactive <prompt> runs the prompt then drops into the REPL; it is
    # no longer a usage error. With an isolated XDG (no config) and EOF on
    # stdin, it reaches the provider wizard and aborts cleanly. We assert
    # only that it is accepted, not rejected as a usage error (exit 2).
    var tmp = getTempDir() / ("3code-cli-i-" & $getCurrentProcessId() & "deny" &
                              $epochTime().int64)
    createDir(tmp)
    let env = newStringTable({"XDG_DATA_HOME": tmp, "XDG_CONFIG_HOME": tmp})
    let (outp, code) = execCmdEx(binPath().quoteShell & " --interactive ignored-text",
                                  {poStdErrToStdOut, poUsePath, poDaemon},
                                  env, tmp)
    discard outp
    removeDir(tmp)
    check code != 2
    check "unexpected argument" notin outp

suite "cli --list cap and short-flag stacking":
  # Runs the real binary with an isolated XDG_DATA_HOME and a temp cwd so
  # `-l` is deterministic regardless of the developer's real sessions.
  # parseopt clusters short flags per-letter, so `-la` == `-l -a` == `-l`
  # (the all-directories meaning is disabled, but `-a` is still accepted).
  var tmp: string

  setup:
    tmp = getTempDir() / ("3code-cli-list-" & $getCurrentProcessId() & "deny" &
                          $epochTime().int64)
    createDir(tmp)
    # Resolve symlinks so the cwd key the test seeds under matches the cwd
    # the spawned binary computes via getCurrentDir(). On macOS getTempDir()
    # returns /var/folders/... but getcwd() resolves the /var -> /private/var
    # symlink, so an unresolved seed key would never match and -l would
    # report "no saved sessions".
    let savedCwd = getCurrentDir()
    setCurrentDir(tmp)
    tmp = getCurrentDir()
    setCurrentDir(savedCwd)

  teardown:
    if dirExists(tmp): removeDir(tmp)

  proc runIn(envCwd: string; flags: string): tuple[o: string, code: int] =
    when defined(windows):
      let cmd = "cmd /c set XDG_DATA_HOME=" & tmp & "&& " &
                quoteShell(binPath()) & " " & flags
      let (outp, code) = execCmdEx(cmd, workingDir = envCwd)
      result = (outp.strip(), code)
    else:
      let cmd = "XDG_DATA_HOME=" & tmp.quoteShell & " " &
                binPath().quoteShell & " " & flags
      let (outp, code) = execCmdEx(cmd, workingDir = envCwd)
      result = (outp.strip(), code)

  proc seedSession(stamp: string) =
    # Minimal valid .3log under the isolated sessions dir, plus a cwd-index
    # entry so the binary's O(1) `listSessionPathsForCwd` finds it without
    # scanning. saveSession does both; the test must mirror that. The index
    # is written directly under the isolated tmp root (not via the test
    # process's own XDG_DATA_HOME, which is the developer's real one).
    let dir = tmp / "3code" / "sessions"
    createDir(dir)
    let path = dir / (stamp & ".3log")
    writeFile(path, "session " & stamp & " profile=stub cwd=" & tmp & "\n\n" &
                     "system\n  sys\n\n" &
                     "user\n  session " & stamp & "\n\n")
    appendIndexAt(tmp / "3code" / "session-paths", tmp, stamp)

  test "-l reports no sessions for an empty directory":
    let r = runIn(tmp, "-l")
    check r.code == 3  # ExitConfig
    check "no saved sessions for" in r.o

  test "-l caps at 20 and shows the truncation hint":
    for i in 0 ..< 25:
      seedSession("2026010" & (if i < 10: "0" & $i else: $i) & "T120000")
    let r = runIn(tmp, "-l")
    check r.code == 0
    check "202601024T120000" in r.o   # newest, shown
    check "202601005T120000" in r.o   # 20th shown
    check "202601004T120000" notin r.o  # capped out
    check "20 of 25" in r.o           # truncation hint

  test "-la stacks like -l -a (both accepted, directory-scoped)":
    for i in 0 ..< 3:
      seedSession("2026020" & $i & "T120000")
    let stacked = runIn(tmp, "-la")
    let split = runIn(tmp, "-l -a")
    check stacked.code == 0
    check split.code == 0
    # -a is a no-op on scope now, so -la lists the same directory-scoped
    # set as -l -a and plain -l.
    check stacked.o == split.o
    check "20260202T120000" in stacked.o

  test "-a alone is accepted (implies -l, directory-scoped)":
    for i in 0 ..< 2:
      seedSession("2026030" & $i & "T120000")
    let r = runIn(tmp, "-a")
    check r.code == 0
    check "20260301T120000" in r.o

suite "cli syntax errors do no startup work":
  # All argument parsing and syntax validation must complete and bail before
  # any side-effecting startup runs — in particular skill extraction, which
  # writes to `XDG_DATA_HOME/3code/skills/`. A usage error that creates that
  # directory is paying load-then-fail overhead. These run against an
  # isolated XDG_DATA_HOME so the skills dir is a clean signal.
  var tmp: string

  setup:
    tmp = getTempDir() / ("3code-cli-noop-" & $getCurrentProcessId() & "deny" &
                          $epochTime().int64)
    createDir(tmp)

  teardown:
    if dirExists(tmp): removeDir(tmp)

  proc runIn(envCwd: string; flags: string): tuple[o: string, code: int] =
    when defined(windows):
      let cmd = "cmd /c set XDG_DATA_HOME=" & tmp & "&& " &
                quoteShell(binPath()) & " " & flags
      let (outp, code) = execCmdEx(cmd, workingDir = envCwd)
      result = (outp.strip(), code)
    else:
      let cmd = "XDG_DATA_HOME=" & tmp.quoteShell & " " &
                binPath().quoteShell & " " & flags
      let (outp, code) = execCmdEx(cmd, workingDir = envCwd)
      result = (outp.strip(), code)

  proc skillsDirExists(): bool = dirExists(tmp / "3code" / "skills")

  test "bad --resume id bails before skill extraction":
    # A bogus --resume id is validated before side-effecting startup, so the
    # skills dir is never created. A positional prompt alongside --resume is
    # now legitimate (run once resumed), so only the id is rejected.
    let r = runIn(tmp, "--resume=does-not-exist extra")
    check r.code == 3  # ExitConfig
    check "session not found" in r.o
    check not skillsDirExists()

  test "unknown option bails before skill extraction":
    let r = runIn(tmp, "--nope")
    check r.code == 2
    check "unknown option: --nope" in r.o
    check not skillsDirExists()

  test "-l with no sessions bails before skill extraction":
    let r = runIn(tmp, "-l")
    check r.code == 3  # ExitConfig
    check "no saved sessions for" in r.o
    check not skillsDirExists()

  test "option missing its value bails before skill extraction":
    let r = runIn(tmp, "--model")
    check r.code == 2
    check "requires a value" in r.o
    check not skillsDirExists()

suite "box subcommand (built-in sandwall)":
  # `3code box` is the sandbox backend the bash tool re-execs. It must
  # dispatch before any other startup (no TLS, no config, no sandbox file)
  # and confine the command via the OS-native backend.
  var boxTmp: string
  var backendWorks: bool  # does this kernel/OS actually support confinement?

  setup:
    boxTmp = getTempDir() / ("3code-box-" & $getCurrentProcessId() & "deny" &
                              $epochTime().int64)
    createDir(boxTmp)
    # Probe once: run a trivial confined command. If the OS-native backend
    # (Landlock/Seatbelt/ACL) can't restrict on this host (e.g. a kernel
    # built without Landlock, or a CI container lacking the syscall), box
    # exits nonzero and the confinement assertions below are skipped rather
    # than reported as failures. The dispatch/arg-parsing assertions stay
    # unconditional since they don't depend on the backend.
    backendWorks = run(["box", "restrict", boxTmp, "--", "true"]).code == 0

  teardown:
    removeDir(boxTmp)

  test "box with no args prints usage":
    let r = run(["box"])
    check r.code == 0
    check "3code box" in r.o
    check "restrict" in r.o

  test "box unknown subcommand errors":
    let r = run(["box", "nope"])
    check r.code == 2
    check "unknown subcommand" in r.o

  test "box restrict runs a command":
    if backendWorks:
      let r = run(["box", "restrict", boxTmp, "--", "echo", "confined-ok"])
      check r.code == 0
      check "confined-ok" in r.o
    else:
      skip()

  test "box restrict blocks writes outside the writable path":
    # Writable path is boxTmp; a write to its sibling must fail with
    # EACCES (Permission denied) at the syscall level, proving the
    # kernel backend is actually applied, not just parsed. We use `touch`
    # as a plain argv (no shell redirect) so the unquoted `run` join can't
    # be reinterpreted by execCmdEx's shell.
    if backendWorks:
      let outside = getTempDir() / ("3code-box-leak-" & $epochTime().int64)
      let r = run(["box", "restrict", boxTmp, "--", "touch", outside])
      check r.code != 0
      check "Permission denied" in r.o
      check not fileExists(outside)
    else:
      skip()

  test "box --policy confines per the policy file":
    # The bash tool launches box with --policy instead of resolved paths;
    # the box process must load the policy itself. Policy: writable cwd
    # (bare +), deny everything else. A write inside the project works,
    # a write outside fails.
    if backendWorks:
      let proj = boxTmp / "proj"
      createDir(proj)
      writeFile(proj / ".sandboxrc", "deny /\nallow\n")
      let inside = proj / "ok.txt"
      let rIn = run(["box", "--policy", proj / ".sandboxrc",
                     "restrict", "--", "touch", inside])
      check rIn.code == 0
      check fileExists(inside)
      let outside = getTempDir() / ("3code-box-poleak-" & $epochTime().int64)
      let rOut = run(["box", "--policy", proj / ".sandboxrc",
                      "restrict", "--", "touch", outside])
      check rOut.code != 0
      check not fileExists(outside)
      # A fully locked policy (no writable root) is accepted: the touch
      # simply has nowhere legal to land.
      writeFile(proj / ".sandboxrc", "deny /\n")
      let rLock = run(["box", "--policy", proj / ".sandboxrc",
                       "restrict", "--", "true"])
      check rLock.code == 0
    else:
      skip()

  test "box --policy reloads edits between launches":
    # Two launches, policy tightened in between: the second launch must
    # enforce the new file contents without any parent-side reload.
    if backendWorks:
      let proj = boxTmp / "proj2"
      createDir(proj)
      let pol = proj / ".sandboxrc"
      let target = proj / "t.txt"
      writeFile(pol, "deny /\nallow\n")
      check run(["box", "--policy", pol, "restrict", "--", "touch", target]).code == 0
      removeFile(target)
      writeFile(pol, "deny /\n")
      check run(["box", "--policy", pol, "restrict", "--", "touch", target]).code != 0
      check not fileExists(target)
    else:
      skip()

suite "wall subcommand (built-in sandwall wall)":
  # `3code wall` exposes the network firewall: proxy, connect, and the
  # Windows setup entry points. POSIX runs test dispatch and the proxy
  # end-to-end over loopback only.

  test "wall with no args prints usage":
    let r = run(["wall"])
    check r.code == 0
    check "3code wall" in r.o
    check "proxy" in r.o

  test "wall unknown subcommand errors":
    let r = run(["wall", "nope"])
    check r.code == 2
    check "unknown subcommand" in r.o

  test "wall connect without HOST PORT errors":
    let r = run(["wall", "connect"])
    check r.code == 2

  test "wall setup-windows is a no-op on posix":
    when defined(posix):
      let r = run(["wall", "setup-windows"])
      check r.code == 0
      check "only needed on Windows" in r.o

  when defined(posix):
    test "wall proxy enforces the allowlist end to end":
      # Loopback-only end-to-end: spawn `3code wall proxy` with a temp
      # policy, then CONNECT through it with a raw socket. Allowed
      # 127.0.0.1:<echo> tunnels; denied.example is refused.
      let dir = getTempDir() / ("3code-wall-" & $getCurrentProcessId() & "deny" &
                                $epochTime().int64)
      createDir(dir)
      defer: removeDir(dir)
      let pol = dir / "policy"
      writeFile(pol, "deny /\nallow " & dir & "\nallow 127.0.0.1\n")
      # pick a free proxy port
      let probe = newSocket(buffered = false)
      probe.bindAddr(Port(0), "127.0.0.1")
      let proxyPort = probe.getLocalAddr()[1]
      probe.close()
      # one-shot echo server on its own port
      let echoSock = newSocket(buffered = false)
      echoSock.setSockOpt(OptReuseAddr, true)
      echoSock.bindAddr(Port(0), "127.0.0.1")
      echoSock.listen()
      let echoPort = echoSock.getLocalAddr()[1]
      let proxy = startProcess(binPath(), args = ["wall", "proxy",
          "--policy", pol, "--port", $int(proxyPort), "-v"],
          options = {poStdErrToStdOut, poParentStreams})
      defer:
        proxy.terminate()
        discard proxy.waitForExit(5000)
        proxy.close()
        echoSock.close()
      # give the listener a moment, then CONNECT allowed target. All
      # tunnel I/O is raw posix with a deadline: std/net's buffered
      # sockets either hide the header remainder in an internal buffer
      # or wait on data the select-based recv never sees (both bit this
      # test), and an unbounded posix.recv hangs the suite forever when
      # the child proxy dies mid-test.
      sleep(500)
      proc posixRecvAll(fd: SocketHandle; minLen: int;
                        term = ""): string =
        ## Read until minLen bytes (or `term` appears). Raises on a 10s
        ## data deadline - `check` inside a proc does not abort it.
        var buf = newString(4096)
        var waited = 0
        while result.len < minLen or
            (term.len > 0 and term notin result):
          var fds = [TPollfd(fd: fd.cint, events: POLLIN, revents: 0)]
          doAssert posix.poll(addr fds[0], 1, 100) >= 0
          if fds[0].revents == 0:
            waited += 100
            doAssert waited < 10_000, "no data for 10s"
            continue
          let n = posix.recv(fd, addr buf[0], 4096, 0'i32)
          doAssert n > 0, "peer closed"
          result.add buf[0 ..< n]
      proc posixSend(fd: SocketHandle; data: string) =
        check posix.send(fd, data.cstring, data.len, 0'i32) == data.len
      let c = newSocket(buffered = false)
      defer: c.close()
      try:
        c.connect("127.0.0.1", proxyPort, timeout = 5000)
      except OSError:
        # listener may need another beat on a loaded host
        sleep(1000)
        c.connect("127.0.0.1", proxyPort, timeout = 5000)
      posixSend(c.getFd(), "CONNECT 127.0.0.1:" & $int(echoPort) &
        " HTTP/1.1\r\n\r\n")
      check "200" in posixRecvAll(c.getFd(), 0, "\r\n\r\n")
      let efd = posix.accept(echoSock.getFd(), nil, nil)
      check efd.int >= 0
      posixSend(c.getFd(), "ping-through-wall")
      check posixRecvAll(efd, "ping-through-wall".len) == "ping-through-wall"
      posixSend(efd, "pong-back")
      check posixRecvAll(c.getFd(), "pong-back".len) == "pong-back"
      discard posix.close(efd)
      # The proxy serves connections sequentially (fork-safety, see
      # sandwall wall/proxy.nim): the idle tunnel above would block any
      # second connection, so close it before testing the deny.
      c.close()
      # denied host: proxy refuses the CONNECT
      let d = newSocket(buffered = false)
      defer: d.close()
      d.connect("127.0.0.1", proxyPort, timeout = 5000)
      posixSend(d.getFd(), "CONNECT denied.example:443 HTTP/1.1\r\n\r\n")
      check "200" notin posixRecvAll(d.getFd(), 0, "\r\n\r\n")
