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
## used across the codebase. The worker only ever appends; the main thread
## drains and clears the consumed prefix under the same lock.
##
## ORC constraint (from threecode.nim:140): the worker must hold no
## closures and no refs that the main thread also mutates. The
## `NetJobState` is a MAIN-ALLOCATED heap block owned by whichever thread
## currently holds the job (the caller until it joins or retires, then
## the main-thread reaper), passed by `ptr`. Its lifetime always encloses
## the worker's run: a caller only frees the job after `workerDone`
## (workerGone) says the worker has finished touching it, and a job whose
## caller stopped waiting is handed to `reapRetiredNetJobs`, which joins
## the worker before freeing anything. Communication is plain value types
## (`string`, `int`, `bool`) plus `JsonNode`, which is a ref the worker
## builds and serializes to a string for the main thread before setting
## `phase = npDone`. No concurrent mutation of the same node.
##
## ORC constraint 2 (issue #35): freeing a block on a thread other than
## its allocating thread leaks the page (nim-lang/Nim#23361; still open
## on devel, yrc included). So string ownership NEVER crosses threads:
## the main thread takes byte-wise copies of payloads under the lock
## (`drainDeltas`, `copyOutcome`), and the worker frees its own strings
## on its own thread in `workerRelease`, gated on the reap handshake.
##
## Every field access from either thread goes through the locked
## accessors below (`phaseOf`, `outcomeReady`, `isReaped`, `workerDone`,
## `activityCount`) or a locked mutator. No direct unsynchronized reads;
## no lock is held while a callback runs or a thread joins.

import std/[locks, json, os]
import types

const NetReapWaitMs* {.intdefine.} = 5_000
  ## How long the worker waits for the main thread's reap handshake in
  ## `workerRelease` before freeing its own allocations anyway. A normal
  ## caller reaps within one 50ms poll tick. The bound exists for the
  ## retired-job path: a caller that raised or gave up may never reap, and
  ## a worker parked here forever would strand its thread and its job.
  ## An `intdefine` so tests can shrink it.

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
    activity*: int  ## Monotonic count of deltas ever fired; the caller's
                    ## liveness probe for a worker that may be wedged.
    workerGone*: bool  ## Set by the worker as its LAST access to the job.
                       ## Main may join and free the job only after this.

  NetJob* = ptr NetJobState

proc fire*(job: NetJob; delta: NetDelta) =
  ## Append a delta under the lock. Worker-only.
  {.cast(gcsafe).}:
    acquire(job.lock)
    job.deltas.add(delta)
    inc job.activity
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

proc phaseOf*(job: NetJob): NetPhase =
  ## Locked read. The caller polls this instead of touching `job.phase`.
  {.cast(gcsafe).}:
    acquire(job.lock)
    result = job.phase
    release(job.lock)

proc outcomeReady*(job: NetJob): bool =
  ## Locked read of `outcomeWritten`.
  {.cast(gcsafe).}:
    acquire(job.lock)
    result = job.outcomeWritten
    release(job.lock)

proc isReaped*(job: NetJob): bool =
  ## Locked read of `reaped`.
  {.cast(gcsafe).}:
    acquire(job.lock)
    result = job.reaped
    release(job.lock)

proc workerDone*(job: NetJob): bool =
  ## Locked read of `workerGone`: the worker has made its final job access
  ## and freed its own allocations. Main may join (and free) after this.
  {.cast(gcsafe).}:
    acquire(job.lock)
    result = job.workerGone
    release(job.lock)

proc activityCount*(job: NetJob): int =
  ## Locked read of the monotonic delta counter. The caller uses the
  ## delta between two polls as proof the worker is alive and producing;
  ## silence across a whole join budget means the worker is wedged in an
  ## operation no flag can interrupt.
  {.cast(gcsafe).}:
    acquire(job.lock)
    result = job.activity
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
  ## Worker-side cleanup after `publishOutcome`: wait (bounded) for
  ## `reap`, then free the worker-owned strings here on this thread and
  ## set `workerGone` as the job's last touch. The normal caller reaps
  ## within one poll tick; the bound covers a caller that raised or gave
  ## up without reaping (a retired job), so the worker can still exit.
  ## Replacements are allocation-free (`@[]` / `StreamOutcome()`), so the
  ## main thread's later destruction of these fields frees nothing across
  ## threads — that is what makes freeing the job on main after
  ## `workerDone` ORC-safe.
  var waited = 0
  while not isReaped(job) and waited < NetReapWaitMs:
    sleep(1)
    inc waited
  {.cast(gcsafe).}:
    acquire(job.lock)
    job.deltas = @[]
    job.outcome = StreamOutcome()
    job.workerGone = true
    release(job.lock)
