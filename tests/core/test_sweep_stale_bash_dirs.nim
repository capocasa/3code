discard """
  action: run
  disabled: "win"
"""
## sweepStaleBashDirs must remove per-run bash wrapper dirs whose owning
## 3code process is dead (a killed run leaks its `3code_bash_<pid>_<ts>`
## dir; the per-run `finally` never fires) and keep dirs of live owners,
## including its own pid and names it cannot parse.
import std/[os, osproc, strtabs, unittest]
import threecode/streamexec

suite "stale bash wrapper dir sweep":
  test "dead owner removed; live, own, and unparseable kept":
    let root = getCurrentDir() / "tests/testdata/output/core" /
        ("sweep_bash_" & $getCurrentProcessId())
    if dirExists(root): removeDir(root)
    createDir(root)
    defer: removeDir(root)

    # A dead pid: spawn, wait, and reap so kill(pid, 0) sees ESRCH.
    let gone = startProcess("/bin/sh", args = ["-c", "exit 0"],
                            options = {})
    let deadPid = gone.processID
    discard waitForExit(gone)
    close(gone)

    # A live pid: an actual sleeping process held open across the sweep.
    let live = startProcess("/bin/sleep", args = ["30"], options = {})
    let livePid = live.processID
    defer:
      kill(live)
      discard waitForExit(live)
      close(live)

    let deadDir = root / ("3code_bash_" & $deadPid & "_111")
    let liveDir = root / ("3code_bash_" & $livePid & "_222")
    let ownDir = root / ("3code_bash_" & $getCurrentProcessId() & "_333")
    let junkDir = root / "3code_bash_notalnum_444"
    for d in [deadDir, liveDir, ownDir, junkDir]:
      createDir(d)
      writeFile(d / "cmd.sh", "# stub\n")

    putEnv("TMPDIR", root)
    streamexec.sweepStaleBashDirs()

    check not dirExists(deadDir)
    check dirExists(liveDir)
    check dirExists(ownDir)
    check dirExists(junkDir)
