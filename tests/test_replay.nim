import std/[unittest, os, json, hashes, strutils]
import threecode

## Failure-replay harness. Loads snapshotted session JSONs from
## `.agents/archive/failures/` (gitignored) and feeds their tool_call streams
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
  repo / ".agents" / "archive" / "failures" / name

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

  test "reads alone never escalate past Strike 1":
    # Reading a file you're editing is observation, not thrash. A flood of
    # reads on one path should still fire Strike 1 (concentration signal)
    # but must not hard-trip to Strike 2 — that needs actual mutations.
    var t = initLoopTracker()
    for i in 0 ..< LoopWindowK:  # 15 reads, past 2×T
      discard trackCall(t, "read", %*{"path": "/tmp/x.nim"})
    check t.strike == 1

  test "patches+reads mix trips Strike 2 only on mutation count":
    # 5 patches + 5 reads = 10 total on one path, but only 5 mutations —
    # so Strike 1 fires (soft) and Strike 2 does NOT (hard-trip needs 10
    # mutations). Then 5 more patches push mutations to 10 → Strike 2.
    var t = initLoopTracker()
    for i in 0 ..< LoopTripT:
      discard trackCall(t, "patch", %*{"path": "/tmp/x.nim"})
    for i in 0 ..< LoopTripT:
      discard trackCall(t, "read", %*{"path": "/tmp/x.nim"})
    check t.strike == 1
    for i in 0 ..< LoopTripT:
      discard trackCall(t, "patch", %*{"path": "/tmp/x.nim"})
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

## Full-pipeline replay harness. Unlike the narrow `trackCall`-only suite
## above (which feeds tool_call args into the loop tracker only), this
## suite walks each failure session turn by turn and replays tool calls
## through the real `runAction` — redirecting every filesystem path into
## a per-test sandbox — and runs `supersedeCompact` / `compactHistory`
## between turns. Assertions exercise bugs that would not surface at the
## unit-call level:
##
## - no literal `~` subdirectory appears in the sandbox (regression guard
##   for the tilde-expansion bug fixed in commit 320b134)
## - no assistant tool_call body in the final `messages` array has
##   `[superseded]` as its entire content (regression guard for the
##   body-marker bug fixed in 557f23a — the superseder now writes a
##   longer, unmistakable "body elided" notice)
## - the loop guard trips at the same point as the narrow harness
##
## `bash` is NOT executed; it returns a stub result. We can't faithfully
## reproduce the original environment anyway (nim version, files, etc.)
## and the point of the harness is the runAction + supersede pipeline,
## not command execution.

type
  FullReplayResult = object
    sandbox: string
    finalMessages: JsonNode
    tripOverall: int
    tripped: bool
    preBareSuperseded: int   # bare [superseded] bodies already in the fixture

proc sandboxPathFor(realPath: string, sandbox: string): string =
  ## Maps a session's recorded path into a per-test sandbox so real
  ## filesystem state and the user's $HOME are irrelevant. Uses the
  ## hash of the canonical path as the sandboxed filename so distinct
  ## original paths stay distinct and collisions only happen on
  ## intentional re-accesses of the same path.
  let canon = resolvePath(realPath)
  sandbox / ("p_" & $(hash(canon)) & "_" & extractFilename(realPath))

proc rewritePath(args: JsonNode, sandbox: string): JsonNode =
  ## Deep copy of the args JSON with `path` rewritten into the sandbox.
  result = copy(args)
  if result.kind != JObject: return
  let p = result{"path"}.getStr("")
  if p == "": return
  result["path"] = %sandboxPathFor(p, sandbox)

proc countBareSupersededBodies(messages: JsonNode): int =
  if messages == nil or messages.kind != JArray: return 0
  for m in messages:
    if m.kind != JObject: continue
    if m{"role"}.getStr != "assistant": continue
    let tcs = m{"tool_calls"}
    if tcs == nil or tcs.kind != JArray: continue
    for tc in tcs:
      let fn = tc{"function"}
      if fn == nil: continue
      let argsStr = fn{"arguments"}.getStr("")
      let args = try: parseJson(if argsStr == "": "{}" else: argsStr)
                 except CatchableError: continue
      if args{"body"}.getStr("").strip == "[superseded]": inc result

proc fullReplay(path, sandbox: string): FullReplayResult =
  result.sandbox = sandbox
  createDir(sandbox)
  let doc = parseJson(readFile(path))
  let messages = doc{"messages"}
  if messages == nil or messages.kind != JArray: return
  # Some older fixtures were recorded while the "bare [superseded]"
  # body marker bug was still live. Count those up front so the
  # assertion measures only what our current pipeline adds.
  result.preBareSuperseded = countBareSupersededBodies(messages)
  var live = newJArray()
  var tracker = initLoopTracker()
  var overall = 0
  for m in messages:
    if m.kind != JObject: continue
    case m{"role"}.getStr
    of "system", "user":
      live.add copy(m)
    of "assistant":
      # Build the assistant message we forward; rewrite any path args to
      # point into the sandbox so runAction lands there.
      let rewritten = copy(m)
      let tcs = rewritten{"tool_calls"}
      if tcs != nil and tcs.kind == JArray:
        for tc in tcs:
          let fn = tc{"function"}
          if fn == nil or fn.kind != JObject: continue
          let argsStr = fn{"arguments"}.getStr("")
          let args = try: parseJson(if argsStr == "": "{}" else: argsStr)
                     except CatchableError: newJObject()
          let newArgs = rewritePath(args, sandbox)
          fn["arguments"] = %( $newArgs )
      live.add rewritten
      if tcs == nil or tcs.kind != JArray: continue
      for tc in tcs:
        inc overall
        let id = tc{"id"}.getStr
        let fn = tc{"function"}
        let name = if fn != nil: fn{"name"}.getStr else: ""
        let argsStr = if fn != nil: fn{"arguments"}.getStr("") else: ""
        let args = try: parseJson(if argsStr == "": "{}" else: argsStr)
                   except CatchableError: newJObject()
        let priorStrike = tracker.strike
        let strike = trackCall(tracker, name, args)
        if strike > priorStrike and not result.tripped:
          result.tripped = true
          result.tripOverall = overall
        var toolContent: string
        if name == "bash":
          # Deliberate stub: see module comment.
          toolContent = "[stderr] [replay-stub]\n[exit 0]"
        else:
          let sboxArgs = rewritePath(args, sandbox)
          let act = toolCallToAction(name, sboxArgs)
          let (r, _, _) = runAction(act)
          toolContent = r
        live.add %*{"role": "tool", "tool_call_id": id, "content": toolContent}
      # Between model "turns" run the compaction passes that the live
      # dispatcher runs — this is what exercises the superseded-body
      # marker code path.
      discard supersedeCompact(live)
      discard compactHistory(live)
    of "tool":
      discard  # we synthesized our own tool response above
    else:
      discard
  result.finalMessages = live

proc mkSandbox(tag: string): string =
  result = getTempDir() / ("3code_fullreplay_" & $getCurrentProcessId() & "_" & tag)
  removeDir(result)
  createDir(result)

proc hasLiteralTildeDir(root: string): bool =
  ## Walk the sandbox looking for any path component literally equal to
  ## "~". If the tilde-expansion bug regressed, runAction would create
  ## such a directory under the sandbox.
  for p in walkDirRec(root, yieldFilter = {pcDir, pcFile, pcLinkToDir, pcLinkToFile}):
    for part in p.split(DirSep):
      if part == "~": return true
  false

proc countBareSuperseded(messages: JsonNode): int {.inline.} =
  countBareSupersededBodies(messages)

suite "failure replay — full pipeline":
  test "qwen-010747 full replay: no tilde dir, no bare superseded, trip at 8":
    let p = failurePath("qwen-010747.json")
    if not fileExists(p):
      skip()
    else:
      let sb = mkSandbox("qwen10747")
      let r = fullReplay(p, sb)
      check r.tripped
      check r.tripOverall == 8
      check not hasLiteralTildeDir(sb)
      # Our pipeline must not introduce any NEW bare `[superseded]` body
      # markers. Fixture qwen-010747 was recorded while the old marker
      # bug was live, so its pre-count is >0; we just assert no growth.
      check countBareSuperseded(r.finalMessages) <= r.preBareSuperseded
      removeDir(sb)

  test "qwen-002805 full replay: no tilde dir, no bare superseded, trip at 9":
    let p = failurePath("qwen-002805.json")
    if not fileExists(p):
      skip()
    else:
      let sb = mkSandbox("qwen2805")
      let r = fullReplay(p, sb)
      check r.tripped
      check r.tripOverall == 9
      check not hasLiteralTildeDir(sb)
      check countBareSuperseded(r.finalMessages) <= r.preBareSuperseded
      removeDir(sb)

  test "minimax-000457 full replay: no tilde dir, no bare superseded, trip at 31":
    let p = failurePath("minimax-000457.json")
    if not fileExists(p):
      skip()
    else:
      let sb = mkSandbox("minimax457")
      let r = fullReplay(p, sb)
      check r.tripped
      check r.tripOverall == 31
      check not hasLiteralTildeDir(sb)
      check countBareSuperseded(r.finalMessages) <= r.preBareSuperseded
      removeDir(sb)
