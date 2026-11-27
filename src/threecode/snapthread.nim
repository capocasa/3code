## Threaded goal-mode snapshot arming: the one-shot cousin of
## btwthread.nim's worker.
##
## Arming used to run inline in the turn loop, so a big tree froze the
## UI for the whole walk+copy: the prompt kept typing but nothing else
## got done. The arm now runs on its own thread at a niced priority
## (medium nice on Linux, where nice is per-thread) while the
## controller polls the job from its loop, keeping interrupts live:
## Ctrl-C/ESC cancel the snapshot (the worker compares the process
## interrupt count it started under, exactly like the `:btw` worker)
## and take the turn down, taking precedence over whatever else is in
## flight.
##
## Same ORC law as btwthread.nim: the job and args blocks are allocated
## on the spawning thread and passed by `ptr`; scalars cross under the
## job lock. The one GC'd pointer is the session's ReadCache — the
## controller parks (poll-and-sleep, touching nothing) until the job
## finishes and is reaped, so worker and controller never touch the
## cache concurrently; the ref rides inside the args block the spawner
## allocates, so no pointer to it crosses a thread boundary, and the
## worker touches it only inside its `cast(gcsafe)` body. The spawner
## joins and frees after the worker reports a terminal state.
##
## Registry access (start/poll/reap) is spawning-thread only, and one
## arm is in flight at a time: the goal kickoff is the only caller.

import std/[locks, os]
when defined(linux):
  import std/posix
import types
import api
import snap

type
  SnapArmState* = enum
    saRunning,   ## worker still walking/copying
    saArmed,     ## store materialized
    saRefused,   ## tree over the limits; `outcome` says which cap
    saCancelled  ## interrupt landed before the arm finished

  SnapArmJob = object
    lock: Lock
    state: SnapArmState
    outcome: SnapshotOutcome
    warn: bool       ## walked set over SnapshotWarnBytes
    startedSeen: int32

  SnapArmArgs = object
    job: ptr SnapArmJob
    cache: ReadCache  ## the ref itself, held by the args block the
                      ## spawner allocates and frees after the join
    root: string

var
  snapArmThread: Thread[ptr SnapArmArgs]
  snapArmJob: ptr SnapArmJob
  snapArmArgs: ptr SnapArmArgs

proc snapArmWorker(args: ptr SnapArmArgs) {.thread.} =
  ## The arm on its own thread. Medium nice: snapshotting is background
  ## work by definition — the interactive session keeps its share.
  when defined(linux):
    try: discard nice(5)
    except CatchableError: discard
  var outcome: SnapshotOutcome
  var warn: bool
  {.cast(gcsafe).}:
    let cancelled = proc (): bool {.gcsafe.} =
      interruptsSeen() != args.job.startedSeen
    let ok = armManifestEx(args.cache, args.root, outcome, warn, cancelled)
  acquire(args.job.lock)
  if ok:
    args.job.state = saArmed
  elif outcome == soCancelled:
    args.job.state = saCancelled
  else:
    args.job.state = saRefused
  args.job.outcome = outcome
  args.job.warn = warn
  release(args.job.lock)

proc startSnapArm*(cache: ReadCache; root: string) =
  ## Spawn the arming worker. Controller-thread only, one at a time.
  let job = create(SnapArmJob)
  initLock(job.lock)
  job.state = saRunning
  job.outcome = soArmed
  job.warn = false
  job.startedSeen = interruptsSeen()
  snapArmJob = job
  let args = create(SnapArmArgs)
  args.job = job
  args.cache = cache
  args.root = root
  snapArmArgs = args
  createThread(snapArmThread, snapArmWorker, args)

proc pollSnapArm*(): tuple[state: SnapArmState; outcome: SnapshotOutcome;
                           warn: bool] =
  ## Non-blocking job read. Controller-thread only.
  {.cast(gcsafe).}:
    acquire(snapArmJob.lock)
    result = (snapArmJob.state, snapArmJob.outcome, snapArmJob.warn)
    release(snapArmJob.lock)

proc reapSnapArm*() =
  ## Join the worker and free the blocks. Controller-thread only, after
  ## a poll returned a terminal state. The worker reads only its args
  ## and the job before publishing, and the join fences that.
  {.cast(gcsafe).}:
    joinThread(snapArmThread)
    deinitLock(snapArmJob.lock)
    dealloc(snapArmJob)
    dealloc(snapArmArgs)
    snapArmJob = nil
    snapArmArgs = nil
