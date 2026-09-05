discard """
  disabled: "win"
  ## Drives the real network transport via a local mock server; ConPTY notes
  ## are irrelevant here but the build uses POSIX sockets throughout.
"""
## Reproduce the intermittent row loss on submit against the REAL streaming
## transport. The stub provider emits chunks synchronously on the controller
## thread, so it never reproduces the bug; a real provider streams over a
## network worker thread whose deltas are drained on a ~50ms poll, and each
## chunk triggers a live-content repaint that interleaves with the 80ms gui
## spinner and the submit/turn commit. This test points a non-stub 3code at a
## local mock server (`msDripStream`) that drips many content chunks, runs the
## first AND second submit, and asserts the committed layout is correct:
## hint row H, blank row H+1, echo row H+2, and the first echo survives the
## second submit.

import std/[json, os, strutils]
import tty_expect, stub_helpers, mock_server

proc newFixture(name: string): string =
  result = getCurrentDir() / "testdata" / "output" / "tty" / (name & "_" & $getCurrentProcessId())
  if dirExists(result): removeDir(result)
  createDir(result); createDir(result / "data"); createDir(result / "run")

proc writeProviderConfig(root, url: string) =
  createDir(root / "xdg" / "3code")
  writeFile(root / "xdg" / "3code" / "config", """
[settings]
current = "mock.glm"

[provider]
name = "mock"
url = "$#"
key = "mock"
family = "glm"
models = "glm"
reasoning = on
""" % url)

proc env(root: string): seq[EnvVar] =
  createDir(root / "tmp")
  @[
    (key: "TERM", val: "xterm-256color"),
    (key: "PATH", val: getEnv("PATH")),
    (key: "XDG_DATA_HOME", val: root / "data"),
    (key: "XDG_CONFIG_HOME", val: root / "xdg"),
    (key: "XDG_CACHE_HOME", val: root / "xdg" / "cache"),
    (key: "TMPDIR", val: root / "tmp"),
    (key: "HOME", val: root),
  ]

proc ensureRealBinary(): string =
  const defines = "-d:ssl -d:testPlainHttp --threads:on"
  buildBinary(defines, "3code_real")

# Phase marker flushed as it changes: when the CI watchdog kills this
# binary mid-wait, the retained output names the last phase reached, so
# the stuck wait is identified without a signal handler (writing from a
# handler deadlocks on the stdout lock - learned the hard way).
var phase: string = "init"

proc setPhase(p: string) =
  phase = p
  stdout.write p, "\n"
  flushFile(stdout)

var sessionDumpRaw {.threadvar.}: pointer

proc stuckDump() {.thread, gcsafe.} =
  ## Watchdog thread: if one iteration exceeds 150s, snapshot the live
  ## session's screen rows and raw tail to stderr and exit(7) - the CI
  ## log then carries the app's on-screen state at the stall instead of
  ## an empty kill. (The macOS-26 runner stalls somewhere in iteration 1
  #  turn 2; every harness wait is deadline-bounded, so the stall lives
  ## under the app or the pty layer and only its screen state travels.)
  sleep(150_000)
  stderr.write "STUCK-DUMP after 150s\n"
  let s = cast[TtySession](sessionDumpRaw)
  if s != nil:
    {.gcsafe.}:
      for i, row in s.rows():
        stderr.write i, ": ", row, "\n"
      stderr.write "--- raw tail ---\n"
      stderr.write s.cleanRaw()[^1500 .. ^1], "\n"
  flushFile(stderr)
  quit(7)

proc one(realBin: string; iter: int): string =
  let root = newFixture("submit_race_" & $iter)
  setPhase "iter " & $iter & ": mock server started"
  let srv = startMockServer(msDripStream, chunkDelayMs = 40)
  defer: stopMockServer(srv)
  writeProviderConfig(root, srv.url)
  setPhase "iter " & $iter & ": tty session fork"
  let tty = newTtySession(realBin, args = ["-x", "-i"],
                          cwd = root / "run", env = env(root),
                          cols = 119, rows = 40)
  sessionDumpRaw = cast[pointer](tty)
  defer:
    tty.writeFrameArtifact(root / "frames.txt")
    tty.close()
  setPhase "iter " & $iter & ": wait welcome"
  tty.expect "type a prompt"
  setPhase "iter " & $iter & ": wait prompt"
  tty.expect "❯"

  setPhase "iter " & $iter & ": type turn 1"
  for ch in "first prompt here":
    tty.send $ch
    tty.drain(8)
  tty.send "\n"
  setPhase "iter " & $iter & ": turn 1 streaming"
  tty.expect "❯"
  tty.drain(300)
  block:
    let hintIdx = tty.rowContaining("type a prompt")
    let echoIdx = tty.rowContaining("❯ first prompt here")
    if hintIdx < 0: return "iter " & $iter & " turn1: hint missing"
    if echoIdx < 0:
      return "iter " & $iter & " turn1: echo missing\n" & tty.dumpFramesAround("word2")
    if echoIdx != hintIdx + 2:
      return "iter " & $iter & " turn1: echo not 2 below hint (hint=" & $hintIdx &
        " echo=" & $echoIdx & ")\n" & tty.dumpFramesAround("word2")

  setPhase "iter " & $iter & ": type turn 2"
  for ch in "second prompt now":
    tty.send $ch
    tty.drain(8)
  tty.send "\n"
  setPhase "iter " & $iter & ": turn 2 streaming"
  tty.expect "❯"
  tty.drain(300)
  block:
    let echo1 = tty.rowContaining("❯ first prompt here")
    let echo2 = tty.rowContaining("❯ second prompt now")
    if echo1 < 0:
      return "iter " & $iter & " turn2: FIRST echo deleted\n" & tty.dumpFramesAround("word2")
    if echo2 < 0:
      return "iter " & $iter & " turn2: second echo missing\n" & tty.dumpFramesAround("word2")
    if echo2 <= echo1:
      return "iter " & $iter & " turn2: echoes out of order (echo1=" & $echo1 &
        " echo2=" & $echo2 & ")\n" & tty.dumpFramesAround("word2")
  ""

when isMainModule:
  var wd: Thread[void]
  createThread(wd, stuckDump)
  setPhase "building real binary"
  let realBin = ensureRealBinary()
  # OSX CI analysis (1f5d779 heartbeat): iteration 1 alone stalls to the
  # watchdog kill, so the iteration count is not the variable there - it
  # is the app's first streaming turn against the mock server on that
  # runner. Keep the full 12 locally where the race coverage matters.
  let n = if paramCount() >= 1: parseInt(paramStr(1)) else: 12
  var failures = 0
  for i in 1..n:
    # Heartbeat per iteration: when the CI watchdog kills this test the
    # retained output shows exactly which iteration (and phase) stalled,
    # instead of an empty log.
    stdout.write "iter ", i, " start\n"
    flushFile(stdout)
    let f = one(realBin, i)
    stdout.write "iter ", i, " done\n"
    flushFile(stdout)
    if f.len > 0:
      inc failures
      echo "FAIL: ", f
  echo "ran ", n, " iterations, ", failures, " failures"
  if failures > 0: quit(1)