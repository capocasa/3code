## Process signal state shared by terminal/input and transport code.
##
## SIGWINCH is process-wide, so its pending state must not live in a
## thread-local editor module. The handler only stores a sig_atomic_t flag and
## uses SA_RESTART so resize does not tear down blocking socket reads.
##
## Suspend/resume (Ctrl-Z / SIGTSTP / SIGCONT) is also process-wide and lives
## here. ``requestBackground`` restores cooked mode, sends SIGTSTP, and blocks
## until the process has been stopped and then resumed via SIGCONT.
##
## SIGCONT handling: the signal is blocked process-wide and waited for
## synchronously with ``sigwait`` inside ``requestBackground``. This avoids
## the multithreading pitfall where ``pause``/``sigsuspend`` (thread-local)
## never wake because SIGCONT (process-directed) was delivered to a different
## thread. ``sigwait`` dequeues the pending signal regardless of which thread
## the kernel targeted.
##
## ``kill`` returns before the kernel stops the process, so callers must NOT
## repaint before ``requestBackground`` returns: anything painted between
## ``kill`` and the actual stop is overwritten by the parent shell's
## job-control output on ``fg`` and never repainted.

when defined(posix):
  import posix
  import std/termios
  import util

  type SigAtomic {.importc: "sig_atomic_t", header: "<signal.h>", pure.} = cint

  var resizePendingFlag {.volatile.}: SigAtomic
  var SIGWINCH {.importc, header: "<signal.h>".}: cint
  var SIGCONT {.importc, header: "<signal.h>".}: cint

  var cookedMode: Termios
  var cookedModeValid = false
  var rawMode: Termios
  var rawModeValid = false
  var contBlocked = false

  proc winchHandler(sig: cint) {.noconv.} =
    resizePendingFlag = 1

  proc contHandler(sig: cint) {.noconv.} =
    # Reached only for an *external* suspend (kill -TSTP from another
    # terminal), where no Ctrl-Z keyhandler is on the stack to restore raw
    # mode. SIGCONT is normally blocked and waited for synchronously in
    # requestBackground; this handler covers the case where the signal
    # arrives while no keyhandler is suspended.
    if rawModeValid:
      discard tcsetattr(getFileHandle(stdin), TCSANOW, unsafeAddr rawMode)

  proc installResizeHandler*() =
    var sa: Sigaction
    discard sigemptyset(sa.sa_mask)
    sa.sa_handler = winchHandler
    sa.sa_flags = SA_RESTART
    let rc = sigaction(SIGWINCH, sa, nil)
    if rc != 0:
      debugOut "sigaction(SIGWINCH) failed: " & $rc
    var sc: Sigaction
    discard sigemptyset(sc.sa_mask)
    sc.sa_handler = contHandler
    discard sigaction(SIGCONT, sc, nil)
    # Block SIGCONT process-wide so it is never delivered as an async
    # interrupt; requestBackground dequeues it synchronously via sigwait.
    # (Installed before blocking so the handler is registered for the
    # external-suspend fallback above.)
    var blockSet: Sigset
    var oldSet: Sigset
    discard sigemptyset(blockSet)
    discard sigaddset(blockSet, SIGCONT)
    discard pthread_sigmask(SIG_BLOCK, blockSet, oldSet)
    contBlocked = true

  proc recordCookedMode*() =
    ## Capture the terminal's original (pre-raw) termios, restored to the
    ## parent shell on suspend. Call once, before entering raw mode.
    if not cookedModeValid and
        getFileHandle(stdin).tcGetAttr(addr cookedMode) == 0:
      cookedModeValid = true

  proc recordRawMode*() =
    ## Snapshot the current stdin termios as the raw mode to restore on
    ## resume from a background suspend. Both raw-mode entry points call this
    ## so resume restores the right mode regardless of which path is active.
    if getFileHandle(stdin).tcGetAttr(addr rawMode) == 0:
      rawModeValid = true

  proc restoreCookedMode*() =
    ## Hand the terminal back to the parent shell in cooked mode before
    ## suspending, so the shell can read job-control commands (fg, bg).
    if cookedModeValid:
      discard getFileHandle(stdin).tcSetAttr(TCSANOW, addr cookedMode)

  proc clearRawMode*() =
    rawModeValid = false

  proc requestBackground*() =
    ## Restore cooked mode, send SIGTSTP, and block until the process has
    ## been stopped and then resumed (SIGCONT). Raw mode is restored before
    ## returning. Callers repaint *after* this returns: ``kill`` returns
    ## before the kernel stops the process, so anything painted before the
    ## stop is clobbered by the shell's job-control output on ``fg``.
    restoreCookedMode()
    discard posix.kill(posix.getpid(), posix.SIGTSTP)
    # Wait synchronously for SIGCONT. The signal is blocked process-wide, so
    # the kernel queues it rather than delivering it to a handler; sigwait
    # dequeues it from this thread regardless of which thread the kernel
    # targeted. This sidesteps the pause()/sigsuspend() thread-affinity hole.
    var waitSet: Sigset
    discard sigemptyset(waitSet)
    discard sigaddset(waitSet, SIGCONT)
    var sig: cint = 0
    discard sigwait(waitSet, sig)
    if rawModeValid:
      discard getFileHandle(stdin).tcSetAttr(TCSANOW, addr rawMode)

  proc markResizePending*() =
    resizePendingFlag = 1

  proc consumeResizePending*(): bool =
    if resizePendingFlag != 0:
      resizePendingFlag = 0
      return true

else:
  var resizePendingFlag: bool

  proc installResizeHandler*() = discard

  proc markResizePending*() =
    resizePendingFlag = true

  proc consumeResizePending*(): bool =
    if resizePendingFlag:
      resizePendingFlag = false
      return true

  proc recordCookedMode*() = discard
  proc recordRawMode*() = discard
  proc restoreCookedMode*() = discard
  proc clearRawMode*() = discard
  proc requestBackground*() = discard