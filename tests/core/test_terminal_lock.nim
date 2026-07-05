## Regression tests for the terminal-write lock and the join-deadlock fix.
##
## The bug class: `stopSpinner`/`stopBarTick` call `joinThread` on a background
## render thread that needs the terminal lock to finish its current frame and
## exit. If the caller of stop* already holds the terminal lock (it can, via
## `withTerminalWriteLock` on the main thread), joinThread deadlocks forever:
## the caller waits for the render thread; the render thread waits for the lock
## the caller holds. The symptom users saw: the spinner + elapsed counter keep
## painting but the program never responds to a new prompt (the main thread is
## stuck in joinThread).
##
## The fix is `withTerminalLockDroppedForJoin`: a scoped construct (like a
## `withFile` block) that fully releases the lock around the join and restores
## it afterward via try/finally, so the render thread can drain and exit.
##
## These tests prove (1) the scoped drop/restore is balanced, and (2) the
## spinner join actually completes (does not deadlock) when the caller holds
## the lock.

import std/[unittest, threadpool]
import threecode/terminal as termui

{.push checks: off.}

suite "terminal lock scoped join":
  test "withTerminalLockDroppedForJoin drops to depth 0 inside and restores after":
    # Acquire the lock on this (main) thread, then verify the scoped join
    # helper releases it fully during the join body and restores the exact
    # depth afterward.
    termui.acquireTerminalWrite()
    check termui.terminalLockDepth == 1
    var depthDuringJoin = -1
    termui.withTerminalLockDroppedForJoin:
      depthDuringJoin = termui.terminalLockDepth
    check depthDuringJoin == 0
    check termui.terminalLockDepth == 1
    termui.releaseTerminalWrite()
    check termui.terminalLockDepth == 0

  test "nested depth is restored correctly":
    # Reentrant acquire (depth 2) must round-trip through the join helper
    # and come back to 2, so the caller's two matching releases stay valid.
    termui.acquireTerminalWrite()
    termui.acquireTerminalWrite()
    check termui.terminalLockDepth == 2
    var depthDuringJoin = -1
    termui.withTerminalLockDroppedForJoin:
      depthDuringJoin = termui.terminalLockDepth
    check depthDuringJoin == 0
    check termui.terminalLockDepth == 2
    termui.releaseTerminalWrite()
    termui.releaseTerminalWrite()
    check termui.terminalLockDepth == 0

  test "no-op when caller does not hold the lock":
    # Without an outer acquire, the helper must not acquire on restore
    # (savedDepth 0), leaving the lock free.
    var depthDuringJoin = -1
    termui.withTerminalLockDroppedForJoin:
      depthDuringJoin = termui.terminalLockDepth
    check depthDuringJoin == 0
    check termui.terminalLockDepth == 0

suite "terminal lock reentrancy":
  test "depth counter balances across nested acquires/releases":
    termui.acquireTerminalWrite()
    termui.acquireTerminalWrite()
    termui.acquireTerminalWrite()
    check termui.terminalLockDepth == 3
    termui.releaseTerminalWrite()
    check termui.terminalLockDepth == 2
    termui.releaseTerminalWrite()
    check termui.terminalLockDepth == 1
    termui.releaseTerminalWrite()
    check termui.terminalLockDepth == 0