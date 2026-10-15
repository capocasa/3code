import std/[net, os, osproc, posix, sequtils, streams, strtabs, strutils,
               times, unittest]
import threecode/session

const binName = when defined(windows): "3code.exe" else: "3code"

proc binPath(): string = getCurrentDir() / binName

proc run(args: openArray[string]): tuple[o: string, code: int] =
  # Each arg must be shell-quoted: execCmdEx re-parses the command line
  # through /bin/sh, so a bare join lets metacharacters in an argument
  # (e.g. `>>` inside an sh -c payload) escape into the OUTER shell.
  let cmd = binPath().quoteShell & " " & args.mapIt(it.quoteShell).join(" ")
  let (outp, code) = execCmdEx(cmd)
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

suite "cli --list cap, all-directories scope, and --find":
  # Runs the real binary with an isolated XDG_DATA_HOME and a temp cwd so
  # `-l` / `-f` are deterministic regardless of the developer's real
  # sessions. parseopt clusters short flags per-letter, so `-la` == `-l -a`.
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

  proc seedSession(stamp: string, body = "", cwd = "") =
    # Minimal valid .3log under the isolated sessions dir, plus a cwd-index
    # entry so the binary's O(1) `listSessionPathsForCwd` finds it without
    # scanning. saveSession does both; the test must mirror that. The index
    # is written directly under the isolated tmp root (not via the test
    # process's own XDG_DATA_HOME, which is the developer's real one).
    # `body` lands as the first user message (newlines re-indented to stay
    # valid body lines); `cwd` defaults to the test cwd so sessions from
    # "other directories" can be seeded too.
    let dir = tmp / "3code" / "sessions"
    createDir(dir)
    let path = dir / (stamp & ".3log")
    let text =
      if body == "": "session " & stamp
      else: body
    let bodyLines = text.split("\n").mapIt("  " & it).join("\n")
    writeFile(path, "session " & stamp & " profile=stub cwd=" &
                     (if cwd == "": tmp else: cwd) & "\n\n" &
                     "system\n  sys\n\n" &
                     "user\n" & bodyLines & "\n\n")
    appendIndexAt(tmp / "3code" / "session-paths",
                  (if cwd == "": tmp else: cwd), stamp)

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

  test "-l --page 2 shows the next screenful, then bounds-checks":
    for i in 0 ..< 22:
      seedSession("2026010" & (if i < 10: "0" & $i else: $i) & "T120000")
    let r1 = runIn(tmp, "-l")
    check r1.code == 0
    check "202601000T120000" notin r1.o         # oldest capped out on page 1
    check "--page 2 for more" in r1.o
    let r2 = runIn(tmp, "-l --page 2")
    check r2.code == 0
    check "202601001T120000" in r2.o           # the overflow pair
    check "202601000T120000" in r2.o
    check "--page" notin r2.o                  # last page: no more hint
    let r3 = runIn(tmp, "-l --page 3")
    check r3.code == 2
    check "out of range" in r3.o

  test "-la lists every directory with its cwd, -l stays local":
    seedSession("20260201T120000", body = "local session")
    seedSession("20260202T120000", body = "far session",
                cwd = "/elsewhere/proj")
    let all = runIn(tmp, "-la")
    check all.code == 0
    check "20260201T120000" in all.o
    check "20260202T120000" in all.o
    check "/elsewhere/proj" in all.o
    let local = runIn(tmp, "-l")
    check "20260202T120000" notin local.o
    check "20260201T120000" in local.o

  test "-la stacks like -l -a":
    for i in 0 ..< 3:
      seedSession("2026030" & $i & "T120000")
    check runIn(tmp, "-la").o == runIn(tmp, "-l -a").o

  test "-a alone implies -l with all-directories scope":
    seedSession("20260401T120000")
    seedSession("20260402T120000", body = "far", cwd = "/elsewhere")
    let r = runIn(tmp, "-a")
    check r.code == 0
    check "20260401T120000" in r.o
    check "20260402T120000" in r.o
    check "/elsewhere" in r.o

  test "-f finds sessions by content with a stripped snippet":
    seedSession("20260501T120000", body = "the zebra runs at dawn")
    let r = runIn(tmp, "-f zebra")
    check r.code == 0
    check "20260501T120000" in r.o
    check "zebra runs at dawn" in r.o
    check "profile=stub" notin r.o          # 3log headers stripped

  test "-f matches phrases across line breaks and spacing":
    seedSession("20260601T120000", body = "quick brown\nfox jumps")
    let r = runIn(tmp, "-f \"brown fox\"")
    check r.code == 0
    check "20260601T120000" in r.o
    check "fox jumps" in r.o                 # snippet joins the spanned lines

  test "-f never matches 3log header text":
    seedSession("20260701T120000", body = "zebra")
    check runIn(tmp, "-f profile").code == 3
    check runIn(tmp, "-f stub").code == 3

  test "-f usage errors":
    seedSession("20260801T120000")
    check runIn(tmp, "-f").code == 2
    let r = runIn(tmp, "-f nothingshere")
    check r.code == 3
    check "no sessions matching nothingshere" in r.o

  test "-fa searches every directory":
    seedSession("20260901T120000", body = "walrus", cwd = "/elsewhere")
    check runIn(tmp, "-f walrus").code == 3
    let r = runIn(tmp, "-fa walrus")
    check r.code == 0
    check "20260901T120000" in r.o
    check "/elsewhere" in r.o

  test "-f --page bounds-checks like -l":
    seedSession("20261001T120000", body = "zebra")
    check runIn(tmp, "-f zebra --page 1").code == 0
    let r = runIn(tmp, "-f zebra --page 2")
    check r.code == 2
    check "out of range" in r.o

suite "cli resume value forms":
  # #62: `--resume <id>` parsed `<id>` as the prompt and `-r<id>` as a
  # short-flag cluster. Every value-taking option now accepts the value
  # attached (`-rID`), `=`/`:`-separated, or space-separated. Verified
  # against the dir lock's second line (the session id the process
  # holds), read while the process sits in the provider wizard with its
  # stdin held open: the observable that the NAMED session was loaded,
  # not just that the id was validated.
  var tmp: string

  setup:
    tmp = getTempDir() / ("3code-cli-resume-" & $getCurrentProcessId() & "deny" &
                          $epochTime().int64)
    createDir(tmp / "d" / "3code" / "sessions")
    createDir(tmp / "d" / "3code" / "session-paths")
    createDir(tmp / "c")
    let savedCwd = getCurrentDir()
    setCurrentDir(tmp)
    tmp = getCurrentDir()   # resolve symlink (macOS /var -> /private/var)
    setCurrentDir(savedCwd)
    for id in ["20260101T110000", "20260102T120000"]:
      writeFile(tmp / "d" / "3code" / "sessions" / (id & ".3log"),
        "session " & id & " profile=stub cwd=" & tmp & "\n\n" &
        "system\n  sys\n\nuser\n  hello " & id & "\n\n")
      appendIndexAt(tmp / "d" / "3code" / "session-paths", tmp, id)

  teardown:
    if dirExists(tmp): removeDir(tmp)

  proc heldSessionId(flags: string): string =
    ## Run the binary with stdin held open (it parks in the provider
    ## wizard under the isolated empty config), read the dir lock's
    ## session-id line, then close stdin and reap.
    let lockPath = dirLockPathFor(tmp)
    try: removeFile(lockPath) except OSError: discard
    # startProcess(env=...) REPLACES the environment. TMPDIR must ride
    # along: the child derives the dir-lock path from its own tempDir(),
    # and on macOS (per-user TMPDIR, always set) a stripped env moves
    # the child's lock to /tmp while this side watches $TMPDIR - the
    # lock never appears where the test looks (#62 never ran on mac
    # before the static-ssl CI run).
    var env = newStringTable({"XDG_DATA_HOME": tmp / "d",
                              "XDG_CONFIG_HOME": tmp / "c"})
    if getEnv("TMPDIR").len > 0: env["TMPDIR"] = getEnv("TMPDIR")
    let p = startProcess(binPath(), args = flags.splitWhitespace(),
                         workingDir = tmp, env = env,
                         options = {poStdErrToStdOut, poUsePath})
    # 30s cap: the debug test binary with static OpenSSL is ~60MB;
    # its cold start under testament load can be slow on a 3-core
    # runner. The window only stretches on failure - the loop exits
    # the moment the lock appears.
    for i in 0 ..< 600:
      if fileExists(lockPath): break
      sleep 50
    result = try: readFile(lockPath).strip.splitLines[^1] except CatchableError: ""
    p.inputStream().close()
    discard p.waitForExit()
    close(p)

  proc runIn(flags: string): tuple[o: string, code: int] =
    let env = newStringTable({"XDG_DATA_HOME": tmp / "d",
                              "XDG_CONFIG_HOME": tmp / "c"})
    let (outp, code) = execCmdEx(binPath().quoteShell & " " & flags,
                                 {poStdErrToStdOut, poUsePath, poDaemon},
                                 env, tmp)
    result = (outp.strip(), code)

  test "attached, separated, and space forms all load the named session":
    for flags in ["--resume=20260101T110000", "--resume:20260101T110000",
                  "-r=20260101T110000", "-r:20260101T110000",
                  "--resume 20260101T110000", "-r 20260101T110000",
                  "-r20260101T110000"]:
      check heldSessionId(flags) == "20260101T110000"

  test "bare -r and --resume still mean the latest session":
    check heldSessionId("-r") == "20260102T120000"
    check heldSessionId("--resume") == "20260102T120000"

  test "an option token after -r is not eaten as its value":
    check heldSessionId("-r -x") == "20260102T120000"

  test "a bogus id fails session-not-found in every form":
    for flags in ["--resume nope", "-r nope", "-rnope"]:
      let r = runIn(flags)
      check r.code == 3
      check "session not found: nope" in r.o

  test "-c attached/space/=/: forms are equivalent":
    # The same mechanism serves every value-taking option; -c has a
    # deterministic offline observable (config file actually read).
    writeFile(tmp / "cfg", "[settings]\ncurrent = \"x\"\n")
    let expect = runIn("-c " & (tmp / "cfg").quoteShell).o
    for form in ["-c", "-c=", "-c:"]:
      let r = runIn(form & (tmp / "cfg").quoteShell)
      check r.code == 3
      check "no [provider] section" in r.o
      check r.o == expect

  test "-m attached form reaches the wizard like -m VALUE":
    # No provider under the isolated config: both forms abort at the
    # first-run wizard with identical output; before the fix `-mVAL`
    # died as "unknown option: -V...".
    let expect = runIn("-m zai.glm-5.3").o
    let r = runIn("-mzai.glm-5.3")
    check r.code == 3
    check r.o == expect

suite "cli --config switch":
  # -c/--config redirects the config file. The observable used here: a
  # file that sets `current` without a [provider] section dies naming
  # configPath(), which only happens because the file was actually read
  # (the `current` came from it); without -c an isolated XDG goes to the
  # first-run wizard instead.
  var tmp: string

  setup:
    tmp = getTempDir() / ("3code-cli-cfg-" & $getCurrentProcessId() & "deny" &
                          $epochTime().int64)
    createDir(tmp)

  teardown:
    if dirExists(tmp): removeDir(tmp)

  proc runIn(flags: string): tuple[o: string, code: int] =
    let env = newStringTable({"XDG_DATA_HOME": tmp, "XDG_CONFIG_HOME": tmp})
    let (outp, code) = execCmdEx(binPath().quoteShell & " " & flags,
                                 {poStdErrToStdOut, poUsePath, poDaemon},
                                 env, tmp)
    result = (outp.strip(), code)

  test "-c reads the named file":
    writeFile(tmp / "cfg", "[settings]\ncurrent = \"x\"\n")
    let r = runIn("-c " & (tmp / "cfg").quoteShell)
    check r.code == 3  # ExitConfig
    check "no [provider] section" in r.o
    check (tmp / "cfg") in r.o

  test "--config=VALUE form works too":
    writeFile(tmp / "cfg", "[settings]\ncurrent = \"x\"\n")
    let r = runIn("--config=" & (tmp / "cfg").quoteShell)
    check r.code == 3  # ExitConfig
    check "no [provider] section" in r.o

  test "-c with a missing file is benign, not a die":
    # A missing config has always been the first-run state; -c pointing
    # at nothing must keep that meaning (wizard on EOF stdin aborts with
    # a config exit), not turn into a new error.
    let r = runIn("-c " & (tmp / "nope").quoteShell)
    check r.code == 3
    check "no [provider] section" notin r.o

  test "--config without a value errors":
    let r = runIn("--config")
    check r.code == 2
    check "requires a value" in r.o

  test "-h documents the switch":
    let r = run(["-h"])
    check r.code == 2
    check "--config FILE" in r.o

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

suite "sandbox subcommand (built-in sandwall)":
  # `3code sandbox` is the sandbox backend the bash tool re-execs. It must
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
    backendWorks = run(["sandbox", "restrict", boxTmp, "--", "true"]).code == 0

  teardown:
    removeDir(boxTmp)

  test "sandbox with no args prints usage":
    let r = run(["sandbox"])
    check r.code == 0
    check "3code sandbox" in r.o
    check "restrict" in r.o

  test "sandbox unknown subcommand errors":
    let r = run(["sandbox", "nope"])
    check r.code == 2
    check "unknown subcommand" in r.o

  test "sandbox restrict runs a command":
    if backendWorks:
      let r = run(["sandbox", "restrict", boxTmp, "--", "echo", "confined-ok"])
      check r.code == 0
      check "confined-ok" in r.o
    else:
      skip()

  test "sandbox restrict blocks writes outside the writable path":
    # Writable path is boxTmp; a write to its sibling must fail with
    # EACCES (Permission denied) at the syscall level, proving the
    # kernel backend is actually applied, not just parsed. We use `touch`
    # as a plain argv (no shell redirect) so the unquoted `run` join can't
    # be reinterpreted by execCmdEx's shell.
    if backendWorks:
      let outside = getTempDir() / ("3code-box-leak-" & $epochTime().int64)
      let r = run(["sandbox", "restrict", boxTmp, "--", "touch", outside])
      check r.code != 0
      # macOS Seatbelt reports the blocked syscall as EPERM ("Operation
      # not permitted") where Linux Landlock reports EACCES.
      check "Permission denied" in r.o or "Operation not permitted" in r.o
      check not fileExists(outside)
    else:
      skip()

  test "sandbox --policy confines per the policy file":
    # The bash tool launches box with --policy instead of resolved paths;
    # the box process must load the policy itself. Policy: writable cwd
    # (bare +), deny everything else. A write inside the project works,
    # a write outside fails.
    if backendWorks:
      let proj = boxTmp / "proj"
      createDir(proj)
      writeFile(proj / ".sandbox", "deny /\nallow\n")
      let inside = proj / "ok.txt"
      let rIn = run(["sandbox", "--policy", proj / ".sandbox",
                     "restrict", "--", "touch", inside])
      check rIn.code == 0
      check fileExists(inside)
      let outside = getTempDir() / ("3code-box-poleak-" & $epochTime().int64)
      let rOut = run(["sandbox", "--policy", proj / ".sandbox",
                      "restrict", "--", "touch", outside])
      check rOut.code != 0
      check not fileExists(outside)
      # A fully locked policy (no writable root) is accepted: the touch
      # simply has nowhere legal to land.
      writeFile(proj / ".sandbox", "deny /\n")
      let rLock = run(["sandbox", "--policy", proj / ".sandbox",
                       "restrict", "--", "true"])
      check rLock.code == 0
    else:
      skip()

  test "sandbox --policy reloads edits between launches":
    # Two launches, policy tightened in between: the second launch must
    # enforce the new file contents without any parent-side reload.
    if backendWorks:
      let proj = boxTmp / "proj2"
      createDir(proj)
      let pol = proj / ".sandbox"
      let target = proj / "t.txt"
      writeFile(pol, "deny /\nallow\n")
      check run(["sandbox", "--policy", pol, "restrict", "--", "touch", target]).code == 0
      removeFile(target)
      writeFile(pol, "deny /\n")
      check run(["sandbox", "--policy", pol, "restrict", "--", "touch", target]).code != 0
      check not fileExists(target)
    else:
      skip()

  test "sandbox --policy keeps the policy file read-only inside":
    # The policy file is readable (box reads it to load) but never
    # writable from inside the sandbox, even under `allow /`.
    if backendWorks:
      let proj = boxTmp / "projguard"
      createDir(proj)
      let pol = proj / ".sandbox"
      writeFile(pol, "allow /\n")
      let r = run(["sandbox", "--policy", pol, "restrict", "--",
                   "sh", "-c", "echo pwned >> " & quoteShell(pol)])
      when defined(linux):
        # Landlock unions rules within a layer: a read-only rule cannot
        # subtract write from a writable root, so on Linux the append
        # succeeds (and exits 0). Seatbelt/Windows subtract; there the
        # write fails.
        skip()
      else:
        check r.code != 0
        check readFile(pol) == "allow /\n"
    else:
      skip()

  test "sandbox --policy never warns about a writable policy file":
    # The single policy file always sits under the writable project dir;
    # the old `is under a writable rule` warning was removed because the
    # implicit guard (the parent always denies the two policy file
    # paths, and box carries that deny into the kernel backends).
    if backendWorks:
      let proj = boxTmp / "proj3"
      createDir(proj / ".3code")
      writeFile(proj / ".3code" / "sandbox", "- /\n+\n")
      let r = run(["sandbox", "--policy", proj / ".3code" / "sandbox",
                   "restrict", "--", "true"])
      check r.code == 0
      check "writable rule" notin r.o
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

  test "setup is a no-op on posix":
    when defined(posix):
      let r = run(["setup"])
      check r.code == 2
      check "only available on Windows" in r.o
      let r2 = run(["unsetup"])
      check r2.code == 2
      check "only available on Windows" in r2.o

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

suite "cli provider subcommand":
  # `3code provider ...` manages the config without the TTY wizard.
  # Each test gets an isolated XDG_CONFIG_HOME so the real config is
  # never touched; the binary is the real one (binPath), matching the
  # rest of this file.
  var tmp: string

  setup:
    tmp = getTempDir() / ("3code-cli-prov-" & $getCurrentProcessId() & "deny" &
                          $epochTime().int64)
    createDir(tmp)

  teardown:
    if dirExists(tmp): removeDir(tmp)

  proc runP(args: openArray[string]): tuple[o: string, code: int] =
    let env = newStringTable({"XDG_DATA_HOME": tmp, "XDG_CONFIG_HOME": tmp})
    let cmd = binPath().quoteShell & " " & args.mapIt(it.quoteShell).join(" ")
    let (outp, code) = execCmdEx(cmd, {poStdErrToStdOut, poUsePath, poDaemon},
                                env, tmp)
    result = (outp.strip(), code)

  proc configText(): string =
    let p = tmp / "3code" / "config"
    if fileExists(p): readFile(p) else: ""

  test "list with no providers":
    let r = runP(["provider", "list"])
    check r.code == 0
    check r.o == "no providers configured"

  test "add with a catalog name and key writes the config":
    let r = runP(["provider", "add", "mistral", "--key", "k"])
    check r.code == 0
    check "added mistral" in r.o
    let cfg = configText()
    check "name = \"mistral\"" in cfg
    check "url = \"https://api.mistral.ai/v1\"" in cfg
    check "key = \"k\"" in cfg
    check "glm-5.3" in cfg  # curated default models
    check "current = \"mistral." in cfg

  test "add with --models stores exactly those models":
    let r = runP(["provider", "add", "zai", "--key", "k",
                  "--models", "glm-5.3 glm-5.3-flash"])
    check r.code == 0
    let cfg = configText()
    check "models = \"glm-5.3 glm-5.3-flash\"" in cfg

  test "add rejects unknown known-good models":
    let r = runP(["provider", "add", "zai", "--key", "k",
                  "--models", "not-a-model"])
    check r.code == 3
    check "unknown known-good model: not-a-model" in r.o
    check configText() == ""  # nothing written

  test "add rejects a duplicate provider":
    discard runP(["provider", "add", "mistral", "--key", "k"])
    let r = runP(["provider", "add", "mistral", "--key", "k2"])
    check r.code == 3
    check "already configured: mistral" in r.o

  test "add without a key errors":
    let r = runP(["provider", "add", "mistral"])
    check r.code == 3
    check "api key required (--key)" in r.o

  test "add infers the provider from an api key entry":
    let r = runP(["provider", "add", "sk-or-v1-fake"])
    check r.code == 0
    check "added openrouter" in r.o
    check "url = \"https://openrouter.ai/api/v1\"" in configText()

  test "add with a url needs --experimental":
    let r = runP(["provider", "add", "https://x.example/v1", "--key", "k"])
    check r.code == 3
    check "custom urls need --experimental" in r.o
    let r2 = runP(["-x", "provider", "add", "https://x.example/v1",
                   "--key", "k", "--models", "m"])
    check r2.code == 0
    # defaultNameFromUrl takes the second label from the right
    check "added x" in r2.o

  test "models replaces the list and repairs current":
    discard runP(["provider", "add", "zai", "--key", "k",
                  "--models", "glm-5.3 glm-5.2"])
    let r = runP(["provider", "models", "zai", "glm-5.2"])
    check r.code == 0
    check "zai: 1 models" in r.o
    let cfg = configText()
    check "models = \"glm-5.2\"" in cfg
    check "current = \"zai.glm-5.2\"" in cfg

  test "models on an unknown provider errors":
    let r = runP(["provider", "models", "nope", "glm-5.3"])
    check r.code == 3
    check "unknown provider: nope" in r.o

  test "rm removes the provider and re-points current":
    discard runP(["provider", "add", "zai", "--key", "k"])
    discard runP(["provider", "add", "mistral", "--key", "k"])
    let r = runP(["provider", "rm", "zai"])
    check r.code == 0
    check "removed zai" in r.o
    let cfg = configText()
    check "name = \"zai\"" notin cfg
    check "current = \"mistral." in cfg

  test "rm of the last provider clears current":
    discard runP(["provider", "add", "zai", "--key", "k"])
    let r = runP(["provider", "rm", "zai"])
    check r.code == 0
    check "current = \"\"" in configText()

  test "unknown subcommand prints usage":
    let r = runP(["provider", "bogus"])
    check r.code == 2
    check "usage: 3code provider" in r.o

  test "-c redirects the provider subcommand":
    let cfgPath = tmp / "other.cfg"
    let r = runP(["provider", "-c", cfgPath, "add", "mistral", "--key", "k"])
    check r.code == 0
    check fileExists(cfgPath)
    check "name = \"mistral\"" in readFile(cfgPath)

  test "a prompt mentioning provider is not hijacked":
    # `provider` must be the leading bare word to dispatch; a prompt
    # like `3code add a provider for x` still runs as a prompt (it fails
    # here on the isolated config's wizard abort, which is the point:
    # it did NOT run the provider subcommand).
    let r = runP(["add", "a", "provider", "for", "x"])
    check "usage: 3code provider" notin r.o
    check "unknown subcommand" notin r.o

  test "-h documents the subcommand":
    let r = runP(["-h"])
    check r.code == 2
    check "3code provider add" in r.o
