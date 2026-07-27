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
## the worker builds and hands to the main thread once, under the lock,
## before setting `phase = npDone`. No concurrent mutation of the same
## node.

import std/[locks, json]
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

proc drainDeltas*(job: NetJob; into: var seq[NetDelta]) =
  ## Copy all unconsumed deltas into `into` and advance `consumed`. Main
  ## thread only. The caller replays the copied deltas after the lock is
  ## released.
  {.cast(gcsafe).}:
    acquire(job.lock)
    into = job.deltas[job.consumed ..< job.deltas.len]
    job.consumed = job.deltas.len
    release(job.lock)
