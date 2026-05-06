import std/[json, strutils, tables]
import types, util, shell

const
  LoopWindowK* = 25
  LoopTripT* = 8
  LoopHardTripT* = 16  # 2×T — same path mutated past the nudge
  TurnCallBudget* = 60  # hard cap on tracked (mutation/web) calls per turn

proc initLoopTracker*(): LoopTracker =
  result.ring = @[]
  result.mutCounts = initCountTable[string]()
  result.strike = 0
  result.trippedPaths = @[]
  result.turnCalls = 0

proc resetLoopTracker*(t: var LoopTracker) =
  t.ring.setLen 0
  t.mutCounts.clear()
  t.strike = 0
  t.trippedPaths.setLen 0
  t.recoveryCmd = ""
  t.turnCalls = 0

proc shellCmd(args: JsonNode): string =
  ## Extract the command line from a gpt-oss `shell` call. Mirrors
  ## `dispatchGptOss` in actions.nim — argv array, last element wins.
  let argv = args{"cmd"}.getElems
  if argv.len > 0: argv[^1].getStr else: ""

proc bashCmd(args: JsonNode): string =
  ## Extract the command line for a `bash` tool call.
  ## Supports both the canonical `{command: "..."}` shape and the
  ## legacy `{cmd: ["bash", "-lc", "..."]}` shape used by gpt‑oss.
  let cmdStr = args{"command"}.getStr
  if cmdStr.len > 0:
    return cmdStr
  let argv = args{"cmd"}.getElems
  if argv.len > 0:
    return argv[^1].getStr
  return ""

proc fingerprint*(name: string, args: JsonNode): string =
  ## Returns "" when the call should NOT be tracked. Only mutations and
  ## web calls are tracked — reads are observation and don't indicate
  ## looping. `bash`/`shell` are tracked only when they look like file
  ## mutations (`bashMutationPath`). `web_search` is tracked by query
  ## and `web_fetch` by URL so repetitive search loops are caught.
  case name
  of "bash", "shell":
    let cmd = if name == "bash": bashCmd(args)
              else: shellCmd(args)
    let mp = bashMutationPath(cmd)
    if mp != "": return resolvePath(mp)
    ""
  of "write", "patch":
    let path = args{"path"}.getStr
    if path == "": "" else: resolvePath(path)
  of "read":
    ""  # reads are observation, never tracked
  of "apply_patch":
    let body = args{"input"}.getStr
    var path = ""
    for line in body.splitLines:
      for marker in ["*** Update File: ", "*** Add File: ", "*** Delete File: "]:
        if line.startsWith(marker):
          path = line[marker.len .. ^1]
          break
      if path != "": break
    if path == "": "" else: resolvePath(path)
  of "web_search":
    let q = args{"query"}.getStr
    if q == "": "" else: "ws:" & q
  of "web_fetch":
    let u = args{"url"}.getStr
    if u == "": "" else: "wf:" & u
  else:
    ""

proc isMutationCall*(name: string, args: JsonNode): bool =
  ## Whether a tracked tool call counts as a mutation for the hard-trip
  ## threshold. Reads and web calls do not.
  case name
  of "write", "patch", "apply_patch": true
  of "bash":
    bashMutationPath(args{"command"}.getStr) != ""
  of "shell":
    bashMutationPath(shellCmd(args)) != ""
  else: false

proc trackCall*(t: var LoopTracker, name: string, args: JsonNode): int =
  ## Feed a tool call through the detector. Returns the strike level AFTER
  ## this call (0 = no trip, 1 = mutation saturation first seen for this
  ## path, 2 = second distinct mutation trip OR a working-tree-wiping git
  ## command → outer loop should halt further tool calls).
  ##
  ## Reads are excluded from tracking entirely — they are observation, not
  ## action, and were the primary source of false positives. Only mutations
  ## (write, patch, sed -i, redirects, etc.) and web calls (web_search,
  ## web_fetch) are tracked. Web calls count as non-mutations: they
  ## contribute to Strike 1 (concentration signal) but not Strike 2.
  # Hard short-circuit: any `git checkout <path>` / `git restore` /
  # `git reset --hard` / `git stash` / `git clean -f` is treated as
  # immediate Strike 2. These wipe the working-tree state the model's
  # plan was based on; further autonomous turns make things worse.
  if name == "bash" or name == "shell":
    let cmd = if name == "bash": bashCmd(args)
              else: shellCmd(args)
    let recovery = bashIsRecovery(cmd)
    if recovery != "" and t.strike < 2:
      t.strike = 2
      t.recoveryCmd = recovery
      return 2
  let fp = fingerprint(name, args)
  if fp == "": return t.strike  # reads/plans don't count toward budget
  inc t.turnCalls  # only tracked calls (mutations + web) count
  let isMut = isMutationCall(name, args)
  if t.ring.len >= LoopWindowK:
    let ev = t.ring[0]
    t.ring.delete(0)
    if ev.mut:
      let mc = t.mutCounts.getOrDefault(ev.fp) - 1
      if mc <= 0: t.mutCounts.del ev.fp
      else: t.mutCounts[ev.fp] = mc
  t.ring.add (fp, isMut)
  if isMut: t.mutCounts.inc fp
  let mc = t.mutCounts.getOrDefault(fp)
  # Hard trip: same path MUTATED ≥HardTripT in the window → Strike 2.
  # Only mutations can force a halt. A path that has already tripped
  # Strike 1 and continues to be mutated escalates to Strike 2.
  if mc >= LoopHardTripT and t.strike < 2:
    t.strike = 2
    if fp notin t.trippedPaths: t.trippedPaths.add fp
  elif mc >= LoopTripT and fp notin t.trippedPaths:
    # Strike 1: mutation concentration signal. Only mutations trigger
    # this — reads and web calls don't. Two different paths each
    # tripping Strike 1 does NOT escalate to Strike 2; Strike 2
    # requires a single path hitting the hard-trip threshold.
    t.trippedPaths.add fp
    if t.strike < 1: t.strike = 1
  t.strike
