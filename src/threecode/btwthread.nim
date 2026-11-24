## Async delivery plumbing for `:btw`: the one-shot cousin of the
## streaming NetJob in netthread.nim.
##
## A side question must never block the prompt (the dev-guidelines rule:
## a system command returns immediately; its work runs on a thread). The
## REPL's `:btw` builds the meta-request on the controller thread — the
## one place the live history is readable — then hands plain strings to a
## worker that runs the HTTP call. The worker publishes the answer and
## the call's usage into a lock-protected job; the controller polls from
## its input wait, copies the answer out byte-wise, and commits it to
## scrollback whenever it lands.
##
## Same ORC law as netthread.nim: the job and args blocks are allocated
## on the spawning thread and passed by `ptr`; their lifetime always
## encloses the worker's run. String ownership NEVER crosses threads —
## the answer is published as a worker-owned string, the spawner takes a
## byte-wise copy under the lock (the worker keeps its ref, so nothing is
## freed on the wrong thread), and the worker clears its own copy on its
## own thread after the reap handshake before it exits. The spawner joins
## and frees only after `workerGone`. The args' request strings are read
## by the worker through the pointer and freed by the spawner after the
## join, exactly like `NetWorkerArgs.bodyStr`.
##
## Registry access (start/poll/wait) is spawning-thread only — in
## practice the controller thread for the REPL and the embedder's thread
## for the library. Every field crossing threads goes through the locked
## accessors below; no lock is held while a thread joins.
##
## A `:btw` typed while a turn runs cannot build its request where it was
## typed: the input thread submits mid-turn commands, and the live history
## is readable only on the thread that owns the turn (the one the turn loop
## appends on). So the command only *posts* the question (`postBtw`, any
## thread) and the owner fires it at its next tick (`takePostedBtw`) —
## the request speaks to the conversation as it stood at that tick, and
## the history is never read from a thread that does not own it. An
## answer that lands while a turn still runs is painted at once but its
## tokens wait for the rest (`stashBtwUsage`/`takeStashedBtwUsage`): the
## running turn owns the session's counters and the token bar until it
## parks, so ledgering mid-flight would race its own usage accounting.

import std/[locks, json, os, times]
import types
import compact

const BtwReapWaitMs* {.intdefine.} = 5_000
  ## How long the worker waits for the spawner's reap handshake before
  ## clearing its own answer string and exiting anyway. A normal poll
  ## reaps within one input-wait tick; the bound covers an embedder that
  ## never polls (process exiting, session dropped) so the thread can
  ## still finish. An `intdefine` so tests can shrink it.

type
  BtwJobState* = object
    lock*: Lock
    done*: bool        ## answer+usage are written; ready to copy out
    answer*: string    ## worker-owned until the spawner copies + reaps
    usage*: Usage
    reaped*: bool      ## spawner took its copy; the worker may release
    workerGone*: bool  ## set by the worker as its LAST access to the job

  BtwJob* = ptr BtwJobState

  BtwWorkerArgs* = object
    ## Plain values allocated on the spawning thread; the worker only
    ## reads them (never copies them into refs it frees).
    job*: BtwJob
    req*: MetaRequest

  BtwEntry = object
    job*: BtwJob
    args: ptr BtwWorkerArgs
    thread: ptr Thread[ptr BtwWorkerArgs]

var btwJobs: seq[BtwEntry]

var postedAsks: seq[string]
var postedAsksLock: Lock
initLock(postedAsksLock)

var stashedUsage: seq[Usage]
  ## Controller thread only, like the job registry.

proc postBtw*(question: string) =
  ## Hand a side question to the thread that owns the live history. Never
  ## blocks, never reads the history, safe from any thread.
  acquire(postedAsksLock)
  try:
    postedAsks.add question
  finally:
    release(postedAsksLock)

proc takePostedBtw*(): seq[string] =
  ## Questions posted since the last call, in posting order.
  acquire(postedAsksLock)
  try:
    result = postedAsks
    postedAsks = @[]
  finally:
    release(postedAsksLock)

proc postedBtwLive*(): int =
  ## Questions posted but not yet fired.
  acquire(postedAsksLock)
  try:
    result = postedAsks.len
  finally:
    release(postedAsksLock)

proc stashBtwUsage*(usage: Usage) =
  ## Park a delivered aside's tokens until the session rests. Controller
  ## thread only.
  if usage.totalTokens > 0:
    stashedUsage.add usage

proc takeStashedBtwUsage*(): seq[Usage] =
  ## Oldest first. Controller thread only.
  result = stashedUsage
  stashedUsage = @[]

proc btwJobsLive*(): int =
  ## Jobs spawned but not yet delivered. Lets frontends cheaply skip
  ## polling (and the library notice a pending `:btw` to drain).
  btwJobs.len

proc rawCopy(src: string): string =
  ## Byte-wise copy that never touches `src`'s refcount (netthread.nim's
  ## `rawCopy`, duplicated here to keep the module self-contained).
  if src.len == 0: return ""
  result = newString(src.len)
  copyMem(result[0].addr, src[0].unsafeAddr, src.len)

proc btwWorker(a: ptr BtwWorkerArgs) {.thread.} =
  ## Runs the side-question meta-call off the prompt thread. Publishes
  ## the reply, then holds the reap handshake: the spawner copies the
  ## answer out and signals, and only then does this thread drop its own
  ## string and make its final job access.
  {.cast(gcsafe).}:
    let reply = runMetaRequest(addr a.req, "btw")
    acquire(a.job.lock)
    a.job.answer = reply.answer
    a.job.usage = reply.usage
    a.job.done = true
    release(a.job.lock)
    var waited = 0
    while waited < BtwReapWaitMs:
      acquire(a.job.lock)
      let r = a.job.reaped
      release(a.job.lock)
      if r: break
      sleep 1
      inc waited
    acquire(a.job.lock)
    a.job.answer = ""
    a.job.workerGone = true
    release(a.job.lock)

proc startBtw*(question: string, messages: JsonNode, p: Profile): bool =
  ## Fire a side question on a worker thread; returns immediately, false
  ## when the request could not be built (no usable profile) or the
  ## thread could not spawn. The payload is a snapshot of the live
  ## history taken here, on the caller's thread — the answer speaks to
  ## the conversation as it stood when the question was asked.
  let req = buildMetaRequest(p, messages, BtwSystemPrompt, question,
                             BtwMaxTokens)
  if req.endpoint == "": return false
  let job = create(BtwJobState)
  job.lock.initLock()
  let args = create(BtwWorkerArgs)
  args[] = BtwWorkerArgs(job: job, req: req)
  let t = create(Thread[ptr BtwWorkerArgs])
  try:
    createThread(t[], btwWorker, args)
  except CatchableError:
    # Spawn failed before the worker ever touched anything: unwind here.
    job.lock.deinitLock()
    reset(job[])
    dealloc(job)
    reset(args[])
    dealloc(args)
    dealloc(t)
    return false
  btwJobs.add BtwEntry(job: job, args: args, thread: t)
  true

proc freeBtwEntry(e: var BtwEntry) =
  ## Join the (already reaped) worker and free the blocks it shared, on
  ## the thread that allocated them. No lock held while joining.
  joinThread(e.thread[])
  e.job.lock.deinitLock()
  # After the reap handshake the worker's answer field is already "" (it
  # cleared it on its own thread), so these resets free nothing across
  # threads.
  reset(e.job[])
  dealloc(e.job)
  reset(e.args[])
  dealloc(e.args)
  dealloc(e.thread)

proc pollBtw*(into: var seq[MetaReply]) =
  ## Non-blocking drain, in spawn order: every job whose worker has
  ## published is copied out (byte-wise, spawner-owned), reaped, joined,
  ## and freed. Stops at the first job still in flight so answers can
  ## never overtake each other. Spawning thread only.
  var i = 0
  while i < btwJobs.len:
    let e = addr btwJobs[i]
    acquire(e.job.lock)
    let ready = e.job.done
    release(e.job.lock)
    if not ready: break
    acquire(e.job.lock)
    into.add (rawCopy(e.job.answer), e.job.usage)
    e.job.reaped = true
    release(e.job.lock)
    freeBtwEntry(e[])
    btwJobs.delete(i)

proc waitBtw*(into: var seq[MetaReply]; timeoutMs = 130_000) =
  ## Blocking drain for frontends whose API is synchronous (the library):
  ## poll until every live job has landed, bounded well past the
  ## meta-call's own HTTP timeout so a wedged call ends in the ordinary
  ## "no answer" failure instead of a hang.
  let deadline = epochTime() + timeoutMs.float / 1000.0
  while btwJobs.len > 0 and epochTime() < deadline:
    pollBtw(into)
    if btwJobs.len == 0: break
    sleep 10
