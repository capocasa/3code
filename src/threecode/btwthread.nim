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
## Wire policy (`btwRequest`): an aside retries exactly like a main
## request — 429, 5xx and transport failures back off power-of-two and
## go again, a 200 that produced no answer counts as one — and an
## "interrupted by user" cancels it along with the main request. The
## worker compares the process interrupt count it started under
## (`interruptsSeen`), never the flag: the flag is cleared when the next
## turn starts, so a stale one would cancel an aside asked after the
## interrupt and a cleared one would hide one that landed mid-call. A
## blocked HTTP read cannot be aborted from outside, so a cancelled
## aside's worker finishes its call unseen: the poll moves the entry to
## the retired list at once (later answers never queue behind it) and
## frees it once the worker reports `workerGone`.
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

import std/[locks, json, os, strutils, times]
import types
import api
import compact

const BtwReapWaitMs* {.intdefine.} = 5_000
  ## How long the worker waits for the spawner's reap handshake before
  ## clearing its own answer string and exiting anyway. A normal poll
  ## reaps within one input-wait tick; the bound covers an embedder that
  ## never polls (process exiting, session dropped) so the thread can
  ## still finish. An `intdefine` so tests can shrink it.

const
  BtwMaxAttempts* = 5
    ## Wire attempts per aside, failures included: the main transport's
    ## short curve (a 429/5xx blip recovers well inside it).
  BtwBackoffCapS* = 16
    ## Ceiling on one backoff step, an explicit Retry-After included: an
    ## aside is never worth a long hold.

type
  BtwJobState* = object
    lock*: Lock
    done*: bool        ## answer+usage are written; ready to copy out
    answer*: string    ## worker-owned until the spawner copies + reaps
    usage*: Usage
    cancelled*: bool   ## an interrupt dropped the aside before an answer
    reaped*: bool      ## spawner took its copy; the worker may release
    workerGone*: bool  ## set by the worker as its LAST access to the job

  BtwJob* = ptr BtwJobState

  BtwWorkerArgs* = object
    ## Plain values allocated on the spawning thread; the worker only
    ## reads them (never copies them into refs it frees).
    job*: BtwJob
    req*: MetaRequest
    interrupts: int32 ## `interruptsSeen()` when the aside was asked

  BtwEntry = object
    job*: BtwJob
    args: ptr BtwWorkerArgs
    thread: ptr Thread[ptr BtwWorkerArgs]

  BtwReply* = object
    ## One delivered aside. `cancelled` is set instead of an answer when
    ## an "interrupted by user" dropped it; `usage` is zeroed with it.
    answer*: string
    usage*: Usage
    cancelled*: bool

var
  btwJobs: seq[BtwEntry]
  btwRetired: seq[BtwEntry]
    ## Cancelled entries whose worker is still inside its HTTP call.

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

proc btwRetiredLive*(): int =
  ## Cancelled asides whose worker is still inside its HTTP call; the
  ## next poll frees each once its worker reports gone.
  btwRetired.len

proc rawCopy(src: string): string =
  ## Byte-wise copy that never touches `src`'s refcount (netthread.nim's
  ## `rawCopy`, duplicated here to keep the module self-contained).
  if src.len == 0: return ""
  result = newString(src.len)
  copyMem(result[0].addr, src[0].unsafeAddr, src.len)

proc btwCancelled(interrupts: int32): bool {.gcsafe.} =
  interruptsSeen() != interrupts

proc btwRequest(req: ptr MetaRequest; interrupts: int32): BtwReply =
  ## The aside's wire policy: the main transport's, in miniature. Every
  ## failure the main loop retries (429, 5xx, a transport error with no
  ## response) backs off power-of-two off the attempt number and goes
  ## again, an explicit Retry-After winning; so does a 200 that carried
  ## no answer, the main loop's empty-reply resend. Anything else (a 4xx,
  ## an error object) is final: retrying cannot change the request.
  ## An interrupt seen at any check ends the aside as cancelled.
  for attempt in 1 .. BtwMaxAttempts:
    if btwCancelled(interrupts): return BtwReply(cancelled: true)
    let a = metaRequestAttempt(req, "btw")
    if btwCancelled(interrupts): return BtwReply(cancelled: true)
    if a.status == 200 and a.reply.answer.strip.len > 0:
      return BtwReply(answer: a.reply.answer, usage: a.reply.usage)
    if attempt >= BtwMaxAttempts: break
    let category =
      if a.status == 200: "server"
      else: retryCategory(a.err, nil, a.status)
    if category == "": break
    var backoff = min(1 shl (attempt - 1), BtwBackoffCapS)
    let retryAfter = try: parseInt(a.retryAfter) except CatchableError: 0
    if retryAfter > 0: backoff = min(retryAfter, BtwBackoffCapS)
    var remaining = backoff * 1000
    while remaining > 0:
      if btwCancelled(interrupts): return BtwReply(cancelled: true)
      let step = min(100, remaining)
      sleep(step)
      remaining -= step
  BtwReply()

proc btwWorker(a: ptr BtwWorkerArgs) {.thread.} =
  ## Runs the side-question meta-call off the prompt thread. Publishes
  ## the reply, then holds the reap handshake: the spawner copies the
  ## answer out and signals, and only then does this thread drop its own
  ## string and make its final job access.
  {.cast(gcsafe).}:
    let reply = btwRequest(addr a.req, a.interrupts)
    acquire(a.job.lock)
    a.job.answer = reply.answer
    a.job.usage = reply.usage
    a.job.cancelled = reply.cancelled
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
  let req = buildMetaRequest(p, btwContext(messages), BtwSystemPrompt,
                             question, BtwMaxTokens)
  if req.endpoint == "": return false
  let job = create(BtwJobState)
  job.lock.initLock()
  let args = create(BtwWorkerArgs)
  args[] = BtwWorkerArgs(job: job, req: req,
                         interrupts: interruptsSeen())
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

proc pollBtw*(into: var seq[BtwReply]) =
  ## Non-blocking drain, in spawn order: every job whose worker has
  ## published is copied out (byte-wise, spawner-owned), reaped, joined,
  ## and freed. Stops at the first job still in flight so answers can
  ## never overtake each other — except an aside an interrupt cancelled:
  ## its reply is delivered at once (the worker's call runs out unseen
  ## on the retired list) so later answers never wait behind it. Retired
  ## entries are freed here once their worker reports `workerGone`.
  ## Spawning thread only.
  var i = 0
  while i < btwJobs.len:
    let e = addr btwJobs[i]
    acquire(e.job.lock)
    let ready = e.job.done
    release(e.job.lock)
    if not ready:
      if btwCancelled(e.args.interrupts):
        into.add BtwReply(cancelled: true)
        btwRetired.add btwJobs[i]
        btwJobs.delete(i)
        continue
      break
    acquire(e.job.lock)
    into.add BtwReply(answer: rawCopy(e.job.answer), usage: e.job.usage,
                      cancelled: e.job.cancelled)
    e.job.reaped = true
    release(e.job.lock)
    freeBtwEntry(e[])
    btwJobs.delete(i)
  var j = 0
  while j < btwRetired.len:
    acquire(btwRetired[j].job.lock)
    let gone = btwRetired[j].job.workerGone
    release(btwRetired[j].job.lock)
    if gone:
      var e = btwRetired[j]
      freeBtwEntry(e)
      btwRetired.delete(j)
    else:
      inc j

proc waitBtw*(into: var seq[BtwReply]; timeoutMs = 130_000) =
  ## Blocking drain for frontends whose API is synchronous (the library):
  ## poll until every live job has landed, bounded well past the
  ## meta-call's own HTTP timeout and retry curve so a wedged call ends
  ## in the ordinary "no answer" failure instead of a hang.
  let deadline = epochTime() + timeoutMs.float / 1000.0
  while btwJobs.len > 0 and epochTime() < deadline:
    pollBtw(into)
    if btwJobs.len == 0: break
    sleep 10
