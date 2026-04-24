import std/[unittest, os, json]
import threecode

## Failure-replay harness. Loads snapshotted session JSONs from
## `.agent/failures/` (gitignored) and feeds their tool_call streams
## through the production LoopTracker. Asserts the Strike-1 trip point
## matches the hand-verified expectation, and that it does not trip
## earlier. If a snapshot is missing (e.g. on a CI checkout), the
## specific sub-test is skipped rather than failing.
##
## Note on indexing: the spec in NEXT.md talks about "call 8 / call 8 /
## call 32" but per its own caveat ("if your exclusion rule makes the
## indexing differ, adjust — but document why"), the trip points
## asserted here are the overall 1-based tool-call index into the
## session's tool_calls stream, counting bash (which is the natural
## number the user sees in a `[Tn]` banner). With K=15/T=5 and
## bash excluded from the ring: qwen-010747 trips at overall call 8,
## qwen-002805 at call 9, minimax-000457 at call 31.

type
  ReplayResult = object
    tripped: bool
    overallCallAt: int   # 1-based overall tool-call index when Strike 1 fired
    trackedCallAt: int   # 1-based index of tracked (non-bash) tool calls

proc replay(path: string): ReplayResult =
  let doc = parseJson(readFile(path))
  let messages = doc{"messages"}
  if messages == nil or messages.kind != JArray:
    return
  var tracker = initLoopTracker()
  var overall = 0
  var tracked = 0
  for m in messages:
    if m.kind != JObject: continue
    if m{"role"}.getStr != "assistant": continue
    let tcs = m{"tool_calls"}
    if tcs == nil or tcs.kind != JArray: continue
    for tc in tcs:
      inc overall
      let fn = tc{"function"}
      let name = if fn != nil: fn{"name"}.getStr else: ""
      let argsStr = if fn != nil: fn{"arguments"}.getStr("") else: ""
      let args =
        try: parseJson(if argsStr == "": "{}" else: argsStr)
        except CatchableError: newJObject()
      if name != "bash": inc tracked
      let priorStrike = tracker.strike
      let strike = trackCall(tracker, name, args)
      if strike > priorStrike and not result.tripped:
        result.tripped = true
        result.overallCallAt = overall
        result.trackedCallAt = tracked
        return

proc failurePath(name: string): string =
  let repo = currentSourcePath().parentDir.parentDir
  repo / ".agent" / "failures" / name

suite "failure replay — loop tracker":
  test "qwen-010747 trips at overall call 8":
    let p = failurePath("qwen-010747.json")
    if not fileExists(p):
      skip()
    else:
      let r = replay(p)
      check r.tripped
      check r.overallCallAt == 8

  test "qwen-002805 trips at overall call 9":
    let p = failurePath("qwen-002805.json")
    if not fileExists(p):
      skip()
    else:
      let r = replay(p)
      check r.tripped
      # Spec table says "call 8"; empirically the 5th write (where count
      # hits T=5 for creaturizer.nim) is the 9th overall tool call. See
      # module docstring.
      check r.overallCallAt == 9

  test "minimax-000457 trips at overall call 31":
    let p = failurePath("minimax-000457.json")
    if not fileExists(p):
      skip()
    else:
      let r = replay(p)
      check r.tripped
      # Spec table says "call 32"; empirically roll.nim saturates at
      # overall call 31 (the 5th touch: write/read/read/read/write).
      check r.overallCallAt == 31

  test "tracker does not trip on short, varied traffic":
    var t = initLoopTracker()
    check trackCall(t, "read", %*{"path": "/a"}) == 0
    check trackCall(t, "read", %*{"path": "/b"}) == 0
    check trackCall(t, "write", %*{"path": "/c"}) == 0
    check trackCall(t, "bash", %*{"command": "ls"}) == 0
    check t.strike == 0

  test "bash calls do not enter the ring":
    var t = initLoopTracker()
    for i in 0 ..< 20:
      check trackCall(t, "bash", %*{"command": "ls"}) == 0
    check t.ring.len == 0
    check t.strike == 0

  test "saturation trips after T touches on same canonicalized path":
    var t = initLoopTracker()
    for i in 0 ..< (LoopTripT - 1):
      discard trackCall(t, "write", %*{"path": "/tmp/x.nim"})
    check t.strike == 0
    let s = trackCall(t, "write", %*{"path": "/tmp/x.nim"})
    check s == 1
    check t.strike == 1

  test "same path does not re-trigger Strike 1 on continued saturation":
    var t = initLoopTracker()
    for i in 0 ..< LoopTripT:
      discard trackCall(t, "write", %*{"path": "/tmp/x.nim"})
    check t.strike == 1
    # One extra touch past the trip is still only Strike 1 — needs to reach
    # the hard-trip threshold (2×T) before escalating.
    discard trackCall(t, "write", %*{"path": "/tmp/x.nim"})
    check t.strike == 1

  test "same path escalates to Strike 2 at 2×T (hard trip)":
    var t = initLoopTracker()
    for i in 0 ..< LoopHardTripT:
      discard trackCall(t, "write", %*{"path": "/tmp/x.nim"})
    check t.strike == 2
    # The guard holds at 2 even if further calls on the same path roll in.
    discard trackCall(t, "write", %*{"path": "/tmp/x.nim"})
    check t.strike == 2

  test "different path can escalate to Strike 2":
    var t = initLoopTracker()
    for i in 0 ..< LoopTripT:
      discard trackCall(t, "write", %*{"path": "/tmp/a.nim"})
    check t.strike == 1
    for i in 0 ..< LoopTripT:
      discard trackCall(t, "write", %*{"path": "/tmp/b.nim"})
    check t.strike == 2

  test "reset clears state":
    var t = initLoopTracker()
    for i in 0 ..< LoopTripT:
      discard trackCall(t, "write", %*{"path": "/tmp/x.nim"})
    check t.strike == 1
    resetLoopTracker(t)
    check t.strike == 0
    check t.ring.len == 0
    check t.trippedPaths.len == 0

  test "tilde and absolute paths canonicalize to the same fingerprint":
    var t = initLoopTracker()
    let home = getHomeDir()
    for i in 0 ..< (LoopTripT - 1):
      discard trackCall(t, "write", %*{"path": "~/foo.nim"})
    let s = trackCall(t, "write", %*{"path": home / "foo.nim"})
    check s == 1
