## Integration regression test for the spinner-join deadlock.
##
## Bug: `stopSpinner` joins the spinner thread, which needs the terminal lock
## to finish its current render frame and exit. If `stopSpinner` is called
## while the calling thread holds the terminal lock (a real code path via
## `withTerminalWriteLock` on the main thread), joinThread deadlocks forever:
## the caller waits for the spinner; the spinner waits for the lock. The user
## symptom: spinner + counter keep painting but the program freezes and never
## responds to a new prompt.
##
## This test reproduces the exact deadlock condition (hold the lock, then
## stopSpinner) and asserts it completes within a deadline. Before the fix it
## hangs indefinitely; after the fix (withTerminalLockDroppedForJoin in
## stopSpinner) the join releases the lock so the spinner can exit.
##
## Must run in its own process (it touches real global spinner state and
## spawns a real render thread), which is why it lives here rather than
## alongside the lock-primitive unit tests in test_terminal_lock.nim.

import std/[unittest, os, times]
import threecode/[fatprompt, terminal as termui]

{.push checks: off.}

suite "spinner join deadlock":
  test "stopSpinner completes when called while holding the terminal lock":
    # Start the real spinner. It paints to stdout (ANSI codes; harmless when
    # stdout is redirected, which it is under the test runner).
    startSpinner("test")
    # Give the render thread a moment to enter its loop so the join has a
    # thread mid-render to contend with.
    sleep 150
    # Hold the terminal lock on THIS thread, then stop the spinner. Without
    # the fix, joinThread inside stopSpinner blocks forever here.
    termui.acquireTerminalWrite()
    check termui.terminalLockDepth == 1
    let t0 = epochTime()
    stopSpinner(clearLiveFooter = false)
    let elapsed = epochTime() - t0
    termui.releaseTerminalWrite()
    check termui.terminalLockDepth == 0
    # The join should complete in well under a second (one spinner frame is
    # ~80ms). A hang would blow past the test runner's process timeout.
    # 5s is a generous ceiling that still fails fast on a true deadlock.
    check elapsed < 5.0

  test "stopBarTick completes when called while holding the terminal lock":
    # Same hazard: barTickLoop paints via renderFooter, which needs the lock.
    discard startBarTick("tool")
    sleep 150
    termui.acquireTerminalWrite()
    check termui.terminalLockDepth == 1
    let t0 = epochTime()
    discard stopBarTick()
    let elapsed = epochTime() - t0
    termui.releaseTerminalWrite()
    check termui.terminalLockDepth == 0
    check elapsed < 5.0