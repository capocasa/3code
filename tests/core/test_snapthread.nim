## The threaded goal-mode snapshot arm: threading, cancellation via the
## interrupt count, the refuse/warn thresholds, the nice level, and the
## ephemeral status line's geometry round-trip. The arm runs on the real
## worker (`snapthread.nim`) against real trees on disk; the UI commit
## paths run with the engine's paint gate off (headless), so the tests
## assert the state machine and the geometry models, not terminal bytes.

import std/[json, os, strutils, tables, tempfiles, times, unittest]
import threecode/[api, types, snap, snapthread, util]
import threecode/engine as termengine
import threecode/turns except Usage

when defined(linux):
  proc baseNice: int =
    ## This thread's own nice, so the check is the worker's delta (+5,
    ## medium), not an absolute value that inherits from the harness.
    let stat = readFile("/proc/self/stat")
    let close = stat.rfind(')')
    let fields = stat[close + 1 .. ^1].split(' ')
    fields[17].parseInt

proc withTree(body: proc (dir: string)) =
  let dir = createTempDir("snaparm-test-", "")
  defer: removeDir(dir)
  body(dir)

proc makeFiles(dir: string; count: int; size = 1) =
  createDir(dir / "many")
  let blob = "x".repeat(size)
  for i in 0 ..< count:
    writeFile(dir / "many" / "f" & $i, blob)

when defined(linux):
  proc threadNice: seq[int] =
    ## The nice value of every live thread of this process, straight
    ## from /proc: the ground truth the worker's nice(5) lands in.
    for dir in walkDir("/proc/self/task", checkDir = false):
      let stat = readFile(dir.path / "stat")
      let close = stat.rfind(')')
      let fields = stat[close + 1 .. ^1].split(' ')
      # After "pid (comm)" the split starts with the blank before the
      # state, so fields[1] is stat field 3; nice (stat field 19) is
      # fields[17].
      if fields.len > 17:
        result.add fields[17].parseInt

suite "threaded snapshot arm":
  test "arm runs on a worker thread and the store materializes":
    withTree proc (dir: string) =
      makeFiles(dir, 20)
      let cache = ReadCache(state: initTable[string, (Time, int)]())
      startSnapArm(cache, dir)
      var terminal = false
      for i in 0 ..< 200:
        let (state, outcome, warn) = pollSnapArm()
        if state != saRunning:
          check state == saArmed
          check outcome == soArmed
          check not warn
          terminal = true
          break
        os.sleep(10)
      check terminal
      reapSnapArm()
      check dirExists(dir / ".3code" / "snapshot" / "many")
      check cache.manifestArmed

  test "worker thread runs niced (medium nice)":
    withTree proc (dir: string) =
      # Enough bytes that the copy loop keeps the worker alive while we
      # read the thread table.
      makeFiles(dir, 60, size = 200_000)
      let cache = ReadCache(state: initTable[string, (Time, int)]())
      startSnapArm(cache, dir)
      var seenNice = false
      var sawRunning = false
      var terminal = false
      for i in 0 ..< 600:
        let (state, _, _) = pollSnapArm()
        if state == saRunning:
          sawRunning = true
          when defined(linux):
            if baseNice() + 5 in threadNice(): seenNice = true
        else:
          terminal = true
          break
        os.sleep(10)
      check terminal
      check sawRunning
      when defined(linux):
        check seenNice
      reapSnapArm()

  test "interrupt cancels the arm and deletes the partial store":
    withTree proc (dir: string) =
      # Big enough that the per-file cancel probe has work to interrupt.
      makeFiles(dir, 200, size = 200_000)
      let cache = ReadCache(state: initTable[string, (Time, int)]())
      let seen = interruptsSeen()
      startSnapArm(cache, dir)
      # Takes precedence: the interrupt lands while the arm is in
      # flight, and the worker aborts on its next probe.
      setInterrupted(true)
      var terminal = false
      for i in 0 ..< 600:
        let (state, _, _) = pollSnapArm()
        if state != saRunning:
          check state == saCancelled
          terminal = true
          break
        os.sleep(10)
      check terminal
      reapSnapArm()
      clearInterrupted()
      check interruptsSeen() == seen + 1
      check not dirExists(dir / ".3code" / "snapshot")
      check not cache.manifestArmed

  test "a tree over the file-count cap refuses and latches":
    withTree proc (dir: string) =
      makeFiles(dir, ManifestMaxEntries + 10)
      let cache = ReadCache(state: initTable[string, (Time, int)]())
      startSnapArm(cache, dir)
      var terminal = false
      for i in 0 ..< 1200:
        let (state, outcome, warn) = pollSnapArm()
        if state != saRunning:
          check state == saRefused
          check outcome == soTooManyFiles
          terminal = true
          break
        os.sleep(10)
      check terminal
      reapSnapArm()
      check cache.snapshotRefused
      check not cache.manifestArmed
      check not dirExists(dir / ".3code" / "snapshot")
      # The latch holds: an immediate re-arm refuses without re-walking
      # (the outcome comes back without touching the tree again).
      var outcome: SnapshotOutcome
      var warn: bool
      check not armManifestEx(cache, dir, outcome, warn)
      check outcome == soTooManyBytes

suite "ephemeral status line":
  test "bytes are system-grey and carry the label":
    let bytes = ephemeralStatusBytes("Snapshotting...")
    check bytes.startsWith(GreyFg)
    check bytes.contains("Snapshotting...")
    check bytes.endsWith(Reset & "\r\n")
    let warnBytes = ephemeralStatusBytes(
      "Snapshotting... this might take a while")
    check warnBytes.contains("might take a while")

  test "arm completes headless and the geometry models round-trip":
    # Paint gate off: nothing reaches stdout; the journal procs below
    # are print-free, so they run with the gate on to exercise the real
    # note/drop paths.
    let wasEnabled = termengine.engineOutputEnabled
    termengine.engineOutputEnabled = false
    withTree proc (dir: string) =
      makeFiles(dir, 5)
      clearInterrupted()
      let cache = ReadCache(state: initTable[string, (Time, int)]())
      var messages = %*[]
      let outcome = armSnapshotInteractive(cache, dir, messages)
      check outcome == soArmed
      check cache.manifestArmed
    termengine.engineOutputEnabled = true
    termengine.noteNonMessageTail(ephemeralStatusBytes("Snapshotting..."), 3)
    termengine.noteCommittedRows(ephemeralStatusBytes("Snapshotting..."))
    check termengine.tailJournalSnapshot().len == 1
    termengine.dropTailRecords(3)
    check termengine.tailJournalSnapshot().len == 0
    termengine.unnoteCommittedRows(2)
    termengine.engineOutputEnabled = wasEnabled
