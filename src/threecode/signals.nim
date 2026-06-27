## Process signal state shared by terminal/input and transport code.
##
## SIGWINCH is process-wide, so its pending state must not live in a
## thread-local editor module. The handler only stores a sig_atomic_t flag and
## uses SA_RESTART so resize does not tear down blocking socket reads.

when defined(posix):
  import posix
  import util

  type SigAtomic {.importc: "sig_atomic_t", header: "<signal.h>", pure.} = cint

  var resizePendingFlag {.volatile.}: SigAtomic
  var SIGWINCH {.importc, header: "<signal.h>".}: cint

  proc winchHandler(sig: cint) {.noconv.} =
    resizePendingFlag = 1

  proc installResizeHandler*() =
    var sa: Sigaction
    discard sigemptyset(sa.sa_mask)
    sa.sa_handler = winchHandler
    sa.sa_flags = SA_RESTART
    let rc = sigaction(SIGWINCH, sa, nil)
    if rc != 0:
      debugOut "sigaction(SIGWINCH) failed: " & $rc

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
