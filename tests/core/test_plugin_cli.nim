discard """
  targets: "c"
  matrix: ""
"""
## Binary-level testament for the plugin CLI surface: the real 3code
## binary with discovery redirected to the fixture plugin, driving
## subcommand dispatch, option collection and delivery, and the usage
## rendering. test_plugins.nim covers the same machinery at unit level;
## this file proves the entry point wires it into argv.

import std/[os, osproc, sequtils, strutils, unittest]
import ../plugin_helpers

const binName = when defined(windows): "3code.exe" else: "3code"

var
  root: string
  logPath: string
  built = false

proc run(args: openArray[string]): tuple[o: string; code: int] =
  # execCmdEx re-parses through a shell, so every arg is quoted (the
  # test_cli_args convention). XDG points discovery at the fixture lib;
  # TC_FIXTURE_LOG lets the fixture report what it was handed.
  let quoted = args.toSeq.mapIt(it.quoteShell).join(" ")
  when defined(windows):
    let cmd = "cmd /c set XDG_DATA_HOME=" & (root / "share") & "&& set " &
              "XDG_CONFIG_HOME=" & (root / "cfg") & "&& set TC_FIXTURE_LOG=" &
              logPath & "&& " & quoteShell(getCurrentDir() / binName) & " " &
              quoted
  else:
    let cmd = "XDG_DATA_HOME=" & (root / "share").quoteShell &
              " XDG_CONFIG_HOME=" & (root / "cfg").quoteShell &
              " TC_FIXTURE_LOG=" & logPath.quoteShell & " " &
              quoteShell(getCurrentDir() / binName) & " " & quoted
  let (outp, code) = execCmdEx(cmd)
  (outp.strip(), code)

proc logText(): string =
  if fileExists(logPath): readFile(logPath) else: ""

suite "plugin cli (binary)":
  setup:
    if not built:
      root = getTempDir() / "3code_plugin_cli_test_" & $getCurrentProcessId()
      logPath = root / "fixture.log"
      createDir(root)
      buildPluginFixtures(root / "share")
      built = true

  teardown:
    if fileExists(logPath): removeFile(logPath)

  test "leading bare subcommand dispatches with verbatim args":
    let r = run(["fixturecmd", "hello", "two words", "--flag"])
    check r.code == 0
    check "fixturecmd got: [\"hello\",\"two words\",\"--flag\"]" in r.o
    check "clicmd|[\"hello\",\"two words\",\"--flag\"]" in logText()

  test "a bare word later in the line stays prompt text":
    # Only a LEADING bare word dispatches; nothing here runs a turn
    # because the missing value fails first, proving the word "fixturecmd"
    # was not treated as a subcommand (which would have run with no args
    # and exited 0).
    let r = run(["--fixture-opt"])
    check r.code == 2
    check "option --fixture-opt requires a value" in r.o
    check "clicmd|" notin logText()

  test "plugin options before the subcommand are collected":
    let r = run(["--fixture-opt", "v", "fixturecmd", "x"])
    check r.code == 0
    check "fixturecmd got: [\"x\"]" in r.o
    check "\"fixture-opt\":\"v\"" in logText()

  test "the plugin's exit code propagates":
    putEnv("TC_FIXTURE_MODE", "failcmd")
    defer: putEnv("TC_FIXTURE_MODE", "mutate")
    let r = run(["fixturecmd"])
    check r.code == 7
    check "fixturecmd got: []" in r.o

  test "attached short value form works":
    let r = run(["-Qshort", "fixturecmd"])
    check r.code == 0
    check "\"fixture-opt\":\"short\"" in logText()

  test "options delivered on a fast-exit run":
    # -W is a flag; -l exits before any session work but AFTER delivery.
    discard run(["-W", "-l"])
    check "\"fixture-flag\":true" in logText()

  test "-h lists the plugin surface":
    let r = run(["-h"])
    check r.code == 2
    check "fixturecmd" in r.o
    check "# fixture plugin subcommand" in r.o
    check "--fixture-opt, -Q VALUE" in r.o

  test "unknown option still a usage error with plugins loaded":
    let r = run(["--nope"])
    check r.code == 2
    check "unknown option: --nope" in r.o

  test "skills still not extracted on a usage error":
    # The plugin load moved earlier than argv parsing; it must stay
    # side-effect free (no skills materialization) so usage errors keep
    # bailing cheap.
    let r = run(["--nope"])
    check r.code == 2
    check not dirExists(root / "share" / "3code" / "skills")
