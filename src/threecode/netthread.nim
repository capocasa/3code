## Shared state for the network worker thread (Tier 2).
##
## The worker runs the existing connect+send+SSE loop but writes its
## observable side effects (progress ticks, content deltas, reasoning,
## the final assistant message) into lock-protected shared state instead
## of calling the terminal hooks directly. The main thread polls that
## state on a ~50ms cadence and replays the deltas through the
## unchanged hook layer.
##
## Why no channels: the user explicitly forbade `Channel[T]`. We use a
## plain `seq[NetDelta]` under a `Lock`, matching the atomics + lock idiom
## used across the codebase. The worker only ever appends; the main
## thread drains and clears the consumed prefix under the same lock.
##
## ORC constraint (from threecode.nim:140): the worker must hold no
## closures and no refs that the main thread also mutates. The
## `NetJobState` is a stack `var` in `callModelThreaded` (lifetime
## encloses the worker's run), passed by `ptr`. Communication is plain
## value types (`string`, `int`, `bool`) plus `JsonNode`, which is a ref
## the worker builds and serializes to a string for the main thread
## before setting `phase = npDone`. No concurrent mutation of the same
## node.
##
## ORC constraint 2 (issue #35): freeing a block on a thread other than
## its allocating thread leaks the page (nim-lang/Nim#23361; still open
## on devel, yrc included). So string ownership NEVER crosses threads:
## the main thread takes byte-wise copies of payloads under the lock
## (`drainDeltas`, `copyOutcome`), and the worker frees its own strings
## on its own thread before exiting (`workerRelease`, gated on `reap`).

import std/[locks, json, os]
import types

type
  NetPhase* = enum
    npIdle, npConnecting, npStreaming, npDone

  NetDeltaKind* = enum
    ndkProgress
    ndkReasoning
    ndkContent
    ndkContentFinished
    ndkTrimTrailing
    ndkAfterLive
    ndkActivity

  NetDelta* = object
    case kind*: NetDeltaKind
    of ndkProgress, ndkActivity:
      slurped*: int
    of ndkReasoning:
      reasoning*: string
      reasoningSlurped*: int
    of ndkContent:
      content*: string
      contentSlurped*: int
    of ndkContentFinished:
      fullContent*: string
      finishedSlurped*: int
    of ndkTrimTrailing:
      trimFullContent*: string
      trimSlurped*: int
    of ndkAfterLive:
      afterSlurped*: int

  StreamOutcome* = object
    statusCode*: int
    retryAfter*: string
    errMsg*: string
    errBody*: string
    assistantMsg*: JsonNode
    assistantMsgJson*: string  # worker serializes; main thread parses to avoid ORC cross-thread refs
    usage*: Usage
    streamedLive*: bool
    finishReason*: string

  NetJobState* = object
    lock*: Lock
    phase*: NetPhase
    deltas*: seq[NetDelta]
    consumed*: int
    outcome*: StreamOutcome
    outcomeWritten*: bool
    reaped*: bool

  NetJob* = ptr NetJobState

proc fire*(job: NetJob; delta: NetDelta) =
  ## Append a delta under the lock. Worker-only.
  {.cast(gcsafe).}:
    acquire(job.lock)
    job.deltas.add(delta)
    release(job.lock)

proc fireProgress*(job: NetJob; slurped: int) =
  fire(job, NetDelta(kind: ndkProgress, slurped: slurped))

proc fireActivity*(job: NetJob) =
  fire(job, NetDelta(kind: ndkActivity))

proc fireReasoning*(job: NetJob; reasoning: string; slurped: int) =
  fire(job, NetDelta(kind: ndkReasoning, reasoning: reasoning,
                     reasoningSlurped: slurped))

proc fireContent*(job: NetJob; content: string; slurped: int) =
  fire(job, NetDelta(kind: ndkContent, content: content,
                     contentSlurped: slurped))

proc fireContentFinished*(job: NetJob; fullContent: string; slurped: int) =
  fire(job, NetDelta(kind: ndkContentFinished, fullContent: fullContent,
                     finishedSlurped: slurped))

proc fireTrimTrailing*(job: NetJob; fullContent: string; slurped: int) =
  fire(job, NetDelta(kind: ndkTrimTrailing, trimFullContent: fullContent,
                     trimSlurped: slurped))

proc fireAfterLive*(job: NetJob; slurped: int) =
  fire(job, NetDelta(kind: ndkAfterLive, afterSlurped: slurped))

proc publishOutcome*(job: NetJob; outcome: StreamOutcome) =
  ## Write the final outcome and mark the job done. Worker-only, called
  ## once at the end. Strict order: outcome first, then phase=npDone, so
  ## the main loop never sees npDone without a complete outcome.
  {.cast(gcsafe).}:
    acquire(job.lock)
    job.outcome = outcome
    job.outcomeWritten = true
    job.phase = npDone
    release(job.lock)

proc setPhase*(job: NetJob; phase: NetPhase) =
  {.cast(gcsafe).}:
    acquire(job.lock)
    job.phase = phase
    release(job.lock)

proc rawCopy(src: string): string =
  ## Byte-wise copy that never touches `src`'s refcount, so the source
  ## stays owned (and is freed) by whichever thread allocated it.
  if src.len == 0: return ""
  result = newString(src.len)
  copyMem(result[0].addr, src[0].unsafeAddr, src.len)

proc drainDeltas*(job: NetJob; into: var seq[NetDelta]) =
  ## Copy all unconsumed deltas into `into` and advance `consumed`. Main
  ## thread only. The caller replays the copied deltas after the lock is
  ## released. Payloads are deep-copied byte-wise into main-owned strings:
  ## a ref copy would hand the main thread strings the worker must free
  ## (see the ORC constraint 2 note above). Reading the worker's bytes
  ## under the lock is race-free; the worker only appends.
  {.cast(gcsafe).}:
    acquire(job.lock)
    into.setLen(0)
    for i in job.consumed ..< job.deltas.len:
      into.add(job.deltas[i])
      let d = addr into[^1]
      # Swap each payload for a main-owned copy. The assignment drops the
      # borrowed worker ref (a refcount the worker still holds, so nothing
      # is freed here) and stores fresh memory this thread will free
      # itself. All under the lock, so the worker's appends are serialized
      # against these reads.
      case d.kind
      of ndkReasoning: d.reasoning = rawCopy(d.reasoning)
      of ndkContent: d.content = rawCopy(d.content)
      of ndkContentFinished: d.fullContent = rawCopy(d.fullContent)
      of ndkTrimTrailing: d.trimFullContent = rawCopy(d.trimFullContent)
      of ndkProgress, ndkActivity, ndkAfterLive: discard
    job.consumed = job.deltas.len
    release(job.lock)

proc copyOutcome*(job: NetJob): StreamOutcome =
  ## Main-thread copy of the outcome. Ints/bools copy directly; every
  ## string is byte-wise copied into main-owned memory so no worker
  ## allocation ends up freed on the main thread. `assistantMsg` is nil
  ## on this path (the worker serializes it to `assistantMsgJson`).
  {.cast(gcsafe).}:
    acquire(job.lock)
    if job.outcomeWritten:
      result = job.outcome
      result.retryAfter = rawCopy(job.outcome.retryAfter)
      result.errMsg = rawCopy(job.outcome.errMsg)
      result.errBody = rawCopy(job.outcome.errBody)
      result.assistantMsgJson = rawCopy(job.outcome.assistantMsgJson)
      result.finishReason = rawCopy(job.outcome.finishReason)
      result.assistantMsg = nil
    release(job.lock)

proc reap*(job: NetJob) =
  ## Main signals: all copies taken, the worker may free its own
  ## allocations now. Called once, after the final `drainDeltas` and
  ## `copyOutcome`, before joining the worker.
  {.cast(gcsafe).}:
    acquire(job.lock)
    job.reaped = true
    release(job.lock)

proc workerRelease*(job: NetJob) =
  ## Worker-side cleanup after `publishOutcome`: wait for `reap`, then
  ## free the worker-owned strings here on this thread. The wait is
  ## bounded by main's poll cadence plus one drain.
  while not job.reaped:
    sleep(1)
  {.cast(gcsafe).}:
    acquire(job.lock)
    # @[] / StreamOutcome() are allocation-free replacements, so main's
    # later destruction of these fields frees nothing across threads.
    job.deltas = @[]
    job.outcome = StreamOutcome()
    release(job.lock)
