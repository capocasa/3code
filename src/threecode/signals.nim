## Process signal state shared by terminal/input and transport code.
##
## SIGWINCH is process-wide, so its pending state must not live in a
## thread-local editor module. The handler only stores a sig_atomic_t flag and
## uses SA_RESTART so resize does not tear down blocking socket reads.

when defined(posix):
  import posix
  import std/termios
  import util

  type SigAtomic {.importc: "sig_atomic_t", header: "<signal.h>", pure.} = cint

  var resizePendingFlag {.volatile.}: SigAtomic
  var SIGWINCH {.importc, header: "<signal.h>".}: cint

  var savedRawMode: Termios
  var savedRawModeValid = false

  proc winchHandler(sig: cint) {.noconv.} =
    resizePendingFlag = 1

  proc contHandler(sig: cint) {.noconv.} =
    if savedRawModeValid:
      discard tcsetattr(getFileHandle(stdin), TCSANOW, unsafeAddr savedRawMode)

  proc installResizeHandler*() =
    var sa: Sigaction
    discard sigemptyset(sa.sa_mask)
    sa.sa_handler = winchHandler
    sa.sa_flags = SA_RESTART
    let rc = sigaction(SIGWINCH, sa, nil)
    if rc != 0:
      debugOut "sigaction(SIGWINCH) failed: " & $rc
    # Install SIGCONT handler to restore raw mode when resumed from
    # external SIGTSTP (e.g. kill -TSTP from another terminal).
    var sc: Sigaction
    discard sigemptyset(sc.sa_mask)
    sc.sa_handler = contHandler
    discard sigaction(SIGCONT, sc, nil)

  proc storeRawMode*() =
    if getFileHandle(stdin).tcGetAttr(addr savedRawMode) == 0:
      savedRawModeValid = true

  proc applyRawMode*() =
    if savedRawModeValid:
      discard getFileHandle(stdin).tcSetAttr(TCSANOW, addr savedRawMode)

  proc clearRawMode*() =
    savedRawModeValid = false

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

  proc storeRawMode*() = discard
  proc applyRawMode*() = discard
  proc clearRawMode*() = discard
