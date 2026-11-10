discard """
  targets: "c"
  matrix: ""
"""
## Binary-level testament for the headless frontends: the real 3code
## binary (stub-provider build) driven as `--headless` and `--gui`.
## The contract under test is silence: a headless run writes nothing to
## stdout or stderr on success AND failure, exit codes carry the
## outcome, and `--gui` hands the process to a plugin frontend that
## drives the in-process agent services through the full C ABI.

import std/[algorithm, json, os, osproc, sequtils, strutils, unittest]
import ../plugin_helpers
import ../stub_helpers

var
  root: string
  logPath: string
  bin: string
  built = false

proc runIn(rootDir: string; args: openArray[string]): tuple[o: string; code: int] =
  # execCmdEx defaults to poStdErrToStdOut, so `o` is EVERYTHING the
  # process printed on any stream — exactly what a silence contract
  # wants to check.
  let quoted = args.toSeq.mapIt(it.quoteShell).join(" ")
  # The binary runs with cwd = <root>/run: a clean directory. The
  # project checkout itself carries a .3code goal store, and goal mode
  # would arm a kickoff turn (extra model calls the stub replies do not
  # cover) — the headless contract must be tested outside any of that.
  createDir(rootDir / "run")
  when defined(windows):
    let cmd = "cmd /c cd /d " & (rootDir / "run") & "&& set XDG_DATA_HOME=" &
      (rootDir / "share") & "&& set " &
      "XDG_CONFIG_HOME=" & (rootDir / "cfg") & "&& set TMPDIR=" & (rootDir / "tmp") &
      "&& set TC_FIXTURE_LOG=" & logPath & "&& set " &
      "THREECODE_STUB_RESPONSES=" & (root / "stub_responses.json") &
      "&& " & quoteShell(bin) & " " & quoted
  else:
    let cmd = "cd " & (rootDir / "run").quoteShell & " && XDG_DATA_HOME=" &
      (rootDir / "share").quoteShell &
      " XDG_CONFIG_HOME=" & (rootDir / "cfg").quoteShell &
      " TMPDIR=" & (rootDir / "tmp").quoteShell &
      " TC_FIXTURE_LOG=" & logPath.quoteShell &
      " THREECODE_STUB_RESPONSES=" & (root / "stub_responses.json").quoteShell &
      " " & quoteShell(bin) & " " & quoted
  let (outp, code) = execCmdEx(cmd)
  (outp, code)

proc run(args: openArray[string]): tuple[o: string; code: int] =
  runIn(root, args)

proc writeProvider() =
  createDir(root / "cfg" / "3code")
  writeFile(root / "cfg" / "3code" / "config", """
[settings]
current = "stub.stub-model"

[provider]
name = "stub"
url = "stub://provider"
key = "stub"
family = "glm"
models = "stub-model"
""")

proc stubReplies() =
  # one entry per model call across the whole suite, consumed in order
  var arr = newJArray()
  for r in ["headless reply", "gui reply"]: arr.add %*{"content": r}
  writeFile(root / "stub_responses.json", $arr)

proc logText(): string =
  if fileExists(logPath): readFile(logPath) else: ""

suite "headless cli (binary)":
  setup:
    if not built:
      root = getTempDir() / "3code_headless_cli_test_" & $getCurrentProcessId()
      logPath = root / "fixture.log"
      createDir(root)
      createDir(root / "tmp")
      createDir(root / "share")
      createDir(root / "cfg")
      writeProvider()
      stubReplies()
      buildPluginFixtures(root / "share")
      bin = ensureStubBinary()
      built = true

  teardown:
    if fileExists(logPath): removeFile(logPath)

  test "--headless runs a turn with zero output":
    let r = run(["--headless", "say something"])
    check r.code == 0
    check r.o.len == 0
    # the turn really ran: a session transcript exists with the reply
    var logs: seq[string]
    for f in walkFiles(root / "share" / "3code" / "sessions" / "*.3log"):
      logs.add f
    check logs.len == 1
    check "headless reply" in readFile(logs[0])

  test "--headless with no prompt is a silent usage error":
    let r = run(["--headless"])
    check r.code == 2
    check r.o.len == 0

  test "--headless with no provider is a silent config error":
    let r = run(["--headless", "-c", root / "cfg" / "3code" / "nope", "hi"])
    check r.code == 3
    check r.o.len == 0

  test "--gui hands the process to the plugin frontend":
    # the fixture frontend (default mode) opens the agent, polls, closes
    let r = run(["--gui"])
    check r.code == 0
    check r.o.len == 0
    let text = logText()
    check "frontend|" in text
    check "argv=" in text
    check "agent|busy=0" in text
    check "open|0 " in text   # the stub provider resolves in-process
    check "poll|0" in text
    check "frontend-done" in text
    # the frontend's agentOpen created a session; agentClose persisted it
    var logs: seq[string]
    for f in walkFiles(root / "share" / "3code" / "sessions" / "*.3log"):
      logs.add f
    check logs.len == 2  # one per test that ran a session

  test "--gui: a plugin frontend runs a whole turn in-process":
    # frontend-turn mode: the plugin opens the agent, kicks a turn on
    # the host worker, polls streaming events to done, closes — the
    # minimal-GUI round trip, all inside the one process, zero output.
    putEnv("TC_FIXTURE_MODE", "frontend-turn")
    defer: putEnv("TC_FIXTURE_MODE", "mutate")
    # a fresh process restarts the stub's response index at 0, so this
    # run's first (and only) model call gets its own reply
    var arr = newJArray()
    arr.add %*{"content": "gui reply"}
    writeFile(root / "stub_responses.json", $arr)
    let r = run(["--gui"])
    check r.code == 0
    check r.o.len == 0
    let text = logText()
    check "turn-start|0" in text
    check "turn-delta|" in text
    check "turn-error|" notin text
    check text.contains("turn-done|")
    check "turn-close|0" in text
    # the turn's transcript persisted: the reply is in the newest log
    var logs: seq[string]
    for f in walkFiles(root / "share" / "3code" / "sessions" / "*.3log"):
      logs.add f
    check logs.len == 3
    var persisted = false
    for f in logs:
      if "gui reply" in readFile(f): persisted = true
    check persisted
    stubReplies()  # restore the file for any later run

  test "--gui without a frontend plugin is a silent config error":
    let bare = getTempDir() / "3code_headless_cli_bare_" & $getCurrentProcessId()
    createDir(bare / "share")
    createDir(bare / "cfg" / "3code")
    copyFile(root / "cfg" / "3code" / "config", bare / "cfg" / "3code" / "config")
    let r = runIn(bare, ["--gui"])
    check r.code == 3
    check r.o.len == 0
