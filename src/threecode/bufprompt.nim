## Buffered prompt state.
##
## The feature is currently not wired into the REPL, but the small shared
## buffer API is kept tested so it can be re-enabled without rebuilding this
## concurrency boundary.

import std/[atomics, locks, strutils]

var
  bufLock*: Lock
  bufferedInput: string
  bufferLineReady*: Atomic[bool]

bufLock.initLock()

proc hasCompleteLine(): bool =
  '\n' in bufferedInput

proc feedBuffer*(text: string) =
  ## Append raw input bytes captured while the prompt is unavailable.
  {.cast(gcsafe).}:
    acquire(bufLock)
    bufferedInput.add text
    let ready = hasCompleteLine()
    release(bufLock)
    bufferLineReady.store(ready, moRelease)

proc drainBufferedLine*(): string =
  ## Return the next complete buffered line, without its trailing newline.
  ## If no complete line is available, leave the buffer untouched.
  {.cast(gcsafe).}:
    acquire(bufLock)
    let nl = bufferedInput.find('\n')
    if nl >= 0:
      result = bufferedInput[0 ..< nl]
      bufferedInput = bufferedInput[nl + 1 .. ^1]
    let ready = hasCompleteLine()
    release(bufLock)
    bufferLineReady.store(ready, moRelease)

proc clearBuffer*() =
  ## Drop all queued input and reset the readiness flag.
  {.cast(gcsafe).}:
    acquire(bufLock)
    bufferedInput.setLen(0)
    release(bufLock)
    bufferLineReady.store(false, moRelease)
