## tty test stress runner.
##
## Compiles a tty test file once (compilation dominates wall time at ~45s,
## so we must not recompile per iteration), then runs the resulting binary
## `--times` in a loop, counting non-zero exits as failures. This is the
## measurement layer for the flakiness work: a test can look green in one
## run and fail 1-in-50, and without a repeat harness there is no signal
## that a conversion actually reduced flakiness.
##
## `--under-load` spawns CPU hogs so iterations compete for cores,
## reproducing the parallel-testament condition that surfaced the
## original tty flakiness.
##
## Usage:
##   nim c -r tools/stress.nim tests/tty/test_429_typing_during_backoff.nim --times:30
##   nim c -r tools/stress.nim tests/tty/test_tty_functional.nim --times:20 --under-load
##   # isolate a subtest of test_tty_functional via THREECODE_TTY_ONLY:
##   THREECODE_TTY_ONLY=resume_full_scrollback nim c -r tools/stress.nim \
##     tests/tty/test_tty_functional.nim --times:30
import std/[os, strutils, strformat, times as timeslib, osproc, parseopt, terminal]

const stubHelperDeps = ["unicodedb", "streamhttp", "ttty", "tinotify"]

proc depPaths(): seq[string] =
  for pkg in stubHelperDeps:
    let (outp, code) = execCmdEx("nimble path " & pkg)
    if code == 0:
      let first = outp.strip.splitLines()
      if first.len > 0 and first[0].len > 0:
        result.add "--path:" & first[0]

proc parseArgs(): tuple[testFile: string, n: int, underLoad: bool] =
  result.n = 20
  var p = initOptParser(commandLineParams())
  for kind, key, val in p.getopt():
    case kind
    of cmdArgument:
      if result.testFile.len == 0:
        result.testFile = key
    of cmdLongOption, cmdShortOption:
      case key.normalize
      of "times", "n": result.n = parseInt(val)
      of "under-load", "load": result.underLoad = true
    else: discard

proc buildTestBinary(testFile, outBin: string) =
  var cmd = "nim c --path:src --path:tests -d:ssl -d:testPlainHttp -o:" & outBin
  for p in depPaths(): cmd.add ' ' & p
  cmd.add ' ' & testFile
  let (outp, code) = execCmdEx(cmd)
  if code != 0:
    stderr.writeLine "stress: compile failed:\n" & outp
    quit 1

var loadPids: seq[Process]

proc startLoad() =
  # A handful of CPU-bound loops pinning all cores. Nice'd low so they
  # yield to the test under a real scheduler but still steal time under
  # contention. /usr/bin/nice is used explicitly because osproc doesn't
  # resolve bare names when poUsePath is off and some envs lack PATH.
  for i in 0 ..< countProcessors():
    loadPids.add startProcess("/usr/bin/nice", args = ["-n", "19", "sh", "-c",
      "while true; do true; done"])

proc stopLoad() =
  for p in loadPids: p.kill()
  for p in loadPids: p.close()

when isMainModule:
  let (testFile, n, underLoad) = parseArgs()
  if testFile.len == 0:
    stderr.writeLine "usage: stress <testfile.nim> [--times:N] [--under-load]"
    quit 2

  let outBin = "build" / "stress_" & testFile.extractFilename.changeFileExt("")
  createDir("build")
  echo &"stress: compiling {testFile} -> {outBin}"
  buildTestBinary(testFile, outBin)

  if underLoad:
    echo "stress: starting CPU load (" & $countProcessors() & " cores)"
    startLoad()

  echo &"stress: {n} iterations, under-load={underLoad}"
  var fails = 0
  let t0 = timeslib.epochTime()
  for i in 1 .. n:
    let (outp, r) = execCmdEx(outBin)
    let tag = if r == 0: "ok" else: "FAIL"
    let color = if r == 0: fgGreen else: fgRed
    styledEcho(color, &"  [{i}/{n}] {tag} (exit {r})", resetStyle)
    if r != 0:
      inc fails
      let dump = "build/stress_fail_" & testFile.extractFilename & "_" & $i & ".log"
      writeFile(dump, outp)
      echo "    (output saved to " & dump & ")"
  let elapsed = timeslib.epochTime() - t0

  stopLoad()
  echo ""
  echo &"stress: {n - fails}/{n} passed, {fails} failed " &
    &"in {elapsed:.1f}s ({elapsed/float(n):.2f}s/iter)"
  if fails > 0:
    echo &"stress: FLAKY — {fails}/{n} non-deterministic failures detected"
    quit 1
  echo "stress: no flakiness detected"
