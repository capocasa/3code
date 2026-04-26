import std/[json, tables]
import types, util, shell

const
  LoopWindowK* = 15
  LoopTripT* = 5
  LoopHardTripT* = 10  # 2×T — same path ignored the Strike 1 nudge

proc initLoopTracker*(): LoopTracker =
  result.ring = @[]
  result.counts = initCountTable[string]()
  result.mutCounts = initCountTable[string]()
  result.strike = 0
  result.trippedPaths = @[]

proc resetLoopTracker*(t: var LoopTracker) =
  t.ring.setLen 0
  t.counts.clear()
  t.mutCounts.clear()
  t.strike = 0
  t.trippedPaths.setLen 0
  t.recoveryCmd = ""

proc fingerprint*(name: string, args: JsonNode): string =
  ## Returns "" when the call should NOT be tracked. `bash` is normally
  ## untracked, but commands matching `bashMutationPath` (sed -i, redirects,
  ## git checkout, etc.) are folded back in as patch-equivalent mutations,
  ## and pure single-file reads via `bashReadPath` (`cat`, `sed -n`, `head`,
  ## `tail`) are tracked as reads — both so models can't slip past the loop
  ## guard via the shell now that the dedicated `read` tool is gone.
  case name
  of "bash":
    let cmd = if args != nil and args.kind == JObject: args{"command"}.getStr else: ""
    let mp = bashMutationPath(cmd)
    if mp != "": return resolvePath(mp)
    let (rp, _) = bashReadPath(cmd)
    if rp != "": return resolvePath(rp)
    ""
  of "write", "patch", "read":
    let path = if args != nil and args.kind == JObject: args{"path"}.getStr else: ""
    if path == "": "" else: resolvePath(path)
  else: ""

proc isMutationCall*(name: string, args: JsonNode): bool =
  ## Whether a tracked tool call counts as a mutation for the Strike-2
  ## hard-trip threshold. `read` and read-shaped `bash` reads do not.
  case name
  of "write", "patch": true
  of "read": false
  of "bash":
    let cmd = if args != nil and args.kind == JObject: args{"command"}.getStr else: ""
    bashMutationPath(cmd) != ""
  else: false

proc trackCall*(t: var LoopTracker, name: string, args: JsonNode): int =
  ## Feed a tool call through the detector. Returns the strike level AFTER
  ## this call (0 = no trip, 1 = saturation first seen for this path,
  ## 2 = second distinct trip OR a working-tree-wiping git command →
  ## outer loop should halt further tool calls).
  ## Untracked calls (most `bash`, anything missing a path) return the
  ## current strike unchanged.
  # Hard short-circuit: any `git checkout <path>` / `git restore` /
  # `git reset --hard` / `git stash` / `git clean -f` is treated as
  # immediate Strike 2. These wipe the working-tree state the model's
  # plan was based on; further autonomous turns make things worse.
  # Costs one keystroke on a legit branch switch (which doesn't trigger);
  # saves the next 30 turns when the model is genuinely lost.
  if name == "bash":
    let cmd = if args != nil and args.kind == JObject: args{"command"}.getStr else: ""
    let recovery = bashIsRecovery(cmd)
    if recovery != "" and t.strike < 2:
      t.strike = 2
      t.recoveryCmd = recovery
      return 2
  let fp = fingerprint(name, args)
  if fp == "": return t.strike
  # `bash` can be either a mutation (sed -i, redirects, git mutations) or a
  # read (cat, sed -n, head, tail) — both fingerprint, but only mutations
  # count toward the Strike-2 hard trip.
  let isMut = isMutationCall(name, args)
  if t.ring.len >= LoopWindowK:
    let ev = t.ring[0]
    t.ring.delete(0)
    let c = t.counts.getOrDefault(ev.fp) - 1
    if c <= 0: t.counts.del ev.fp
    else: t.counts[ev.fp] = c
    if ev.mut:
      let mc = t.mutCounts.getOrDefault(ev.fp) - 1
      if mc <= 0: t.mutCounts.del ev.fp
      else: t.mutCounts[ev.fp] = mc
  t.ring.add (fp, isMut)
  t.counts.inc fp
  if isMut: t.mutCounts.inc fp
  let c = t.counts[fp]
  let mc = t.mutCounts.getOrDefault(fp)
  # Hard trip: same path MUTATED ≥2×T in the window → Strike 2. Reads are
  # observation, not mutation — they contribute to the Strike-1 soft warning
  # (concentration is still a signal) but don't force a halt on their own.
  if mc >= LoopHardTripT and t.strike < 2:
    t.strike = 2
    if fp notin t.trippedPaths: t.trippedPaths.add fp
  elif c >= LoopTripT and fp notin t.trippedPaths:
    t.trippedPaths.add fp
    inc t.strike
  t.strike
