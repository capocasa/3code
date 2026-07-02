import std/[os, osproc, strutils, tables, times, unittest]
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

  test "positional arg with --resume errors":
    let r = run(["--resume=does-not-exist", "ignored text"])
    check r.code == 2
    check "unexpected argument" in r.o

  test "positional arg with --interactive errors":
    let r = run(["--interactive", "ignored text"])
    check r.code == 2
    check "unexpected argument" in r.o

suite "cli --list cap and short-flag stacking":
  # Runs the real binary with an isolated XDG_DATA_HOME and a temp cwd so
  # `-l` is deterministic regardless of the developer's real sessions.
  # parseopt clusters short flags per-letter, so `-la` == `-l -a` == `-l`
  # (the all-directories meaning is disabled, but `-a` is still accepted).
  var tmp: string

  setup:
    tmp = getTempDir() / ("3code-cli-list-" & $getCurrentProcessId() & "-" &
                          $epochTime().int64)
    createDir(tmp)

  teardown:
    if dirExists(tmp): removeDir(tmp)

  proc runIn(envCwd: string; flags: string): tuple[o: string, code: int] =
    when defined(windows):
      # Use execCmdEx with env parameter (VAR=VAL prefix doesn't work in cmd.exe)
      var env = newStringTable()
      for k, v in envPairs():
        env[k] = v
      env["XDG_DATA_HOME"] = tmp
      result = execCmdEx(binPath() & " " & flags, env = env, workingDir = envCwd)
      result[0] = result[0].strip()
    else:
      let cmd = "XDG_DATA_HOME=" & tmp.quoteShell & " " &
                binPath().quoteShell & " " & flags
      result = execCmdEx(cmd, workingDir = envCwd)
      result[0] = result[0].strip()

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
    tmp = getTempDir() / ("3code-cli-noop-" & $getCurrentProcessId() & "-" &
                          $epochTime().int64)
    createDir(tmp)

  teardown:
    if dirExists(tmp): removeDir(tmp)

  proc runIn(envCwd: string; flags: string): tuple[o: string, code: int] =
    when defined(windows):
      var env = newStringTable()
      for k, v in envPairs():
        env[k] = v
      env["XDG_DATA_HOME"] = tmp
      result = execCmdEx(binPath() & " " & flags, env = env, workingDir = envCwd)
      result[0] = result[0].strip()
    else:
      let cmd = "XDG_DATA_HOME=" & tmp.quoteShell & " " &
                binPath().quoteShell & " " & flags
      result = execCmdEx(cmd, workingDir = envCwd)
      result[0] = result[0].strip()

  proc skillsDirExists(): bool = dirExists(tmp / "3code" / "skills")

  test "positional arg with --resume bails before skill extraction":
    let r = runIn(tmp, "--resume=does-not-exist extra")
    check r.code == 2
    check "unexpected argument" in r.o
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

