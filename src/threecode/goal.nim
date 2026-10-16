## Goal mode: the file on disk is the protocol.
##
## `goal.md` in the project root keeps a session on one goal. The only
## hook is the end-call boundary in `turns.nim`: when the turn's final
## model call completes and the harness is about to hand the prompt back
## to the user, it stats `goal.md`; bare existence activates (v1 waives
## marker sniff and name-collision handling). A side-call verifier (same
## model, fresh conversation, minimal preamble, read-only roster) judges
## the goal text against harness-built evidence from the just-finished
## turn. FEEDBACK sends the agent back in; SATISFIED renames the file to
## `goal-confirmed.md` and the session idles normally. Bare `:goal!`
## cancels into `goal-cancelled.md`. No session-start
## check, no per-tool-call checks, no system-prompt changes: the
## continuation message carries everything.
##
## The side call is also the future subagent primitive, so it is kept
## separate: its own message list, no session mutation, its own roster.

import std/[json, os, strutils, tables]
import types, util, prompts, api, actions

const
  GoalFileName* = "goal.md"                 ## existence activates goal mode
  GoalConfirmedName* = "goal-confirmed.md"   ## the satisfied record
  GoalCancelledName* = "goal-cancelled.md"  ## the user-cancelled record
  GoalGivenUpName* = "goal-given-up.md"      ## reserved: nothing writes it
                                             ## yet; a failing harness retries
                                             ## instead of giving up
  MaxVerifierRounds* = 16   ## tool rounds before the side call gives up
  EvidenceCapBytes* = 6000  ## evidence summary ceiling
  EvidenceBriefCap* = 160   ## per-call argument digest ceiling
  EvidenceResultCap* = 240  ## per-call result head ceiling

type
  GoalVerdictKind* = enum
    gvkNone      ## output carried no contract line; never counts as satisfied
    gvkSatisfied
    gvkFeedback

  GoalVerdict* = object
    kind*: GoalVerdictKind
    feedback*: string  ## the text after "VERDICT: FEEDBACK:"

  GoalCheckResult* = object
    ok*: bool      ## the side call itself succeeded
    err*: string   ## failure reason when not ok
    verdict*: GoalVerdict

const VerifierPreamble* = """You are verifying progress toward a goal. You get the goal text and
an evidence summary of the agent's last turn: files written, patches
applied, commands and their results. Reconstruct what you need
yourself: read the repo, run the checks. The agent's claims are not
evidence. Read-only: read, search, and bash for checks only. Do not
fix anything. Judge whether the goal as stated is fully satisfied by
the actual state of the repo. End with exactly one line: VERDICT:
SATISFIED, or VERDICT: FEEDBACK: <what is missing or what to do
next>."""

proc goalModeActive*(dir = "."): bool =
  fileExists(dir / GoalFileName)

proc readGoalText*(dir = "."): string =
  try: readFile(dir / GoalFileName)
  except CatchableError: ""

proc parseVerdict*(text: string): GoalVerdict =
  ## The output contract: the FINAL non-empty line is exactly
  ## `VERDICT: SATISFIED` or `VERDICT: FEEDBACK: <what is missing / what
  ## to do next>`. Fixed words match case-insensitively, the shape is
  ## strict, and nothing else ever counts as satisfied: a check without a
  ## verdict line is a failed check, not a passing one.
  let lines = text.strip.splitLines
  if lines.len == 0: return
  let last = lines[^1].strip
  let up = last.toUpperAscii
  if up == "VERDICT: SATISFIED":
    result.kind = gvkSatisfied
  elif up.startsWith("VERDICT: FEEDBACK:"):
    result.kind = gvkFeedback
    result.feedback = last["VERDICT: FEEDBACK:".len ..^ 1].strip
    if result.feedback.len == 0: result.kind = gvkNone

proc goalFeedbackMessage*(feedback: string): JsonNode =
  ## The harness-autosent continuation. Marked `agentSent` exactly like
  ## flail escalations, so replay renders it as a `»` item, no provider
  ## ever sees the marker, and nothing mistakes it for user input.
  %*{"role": "user", "agentSent": true,
     "content": "Goal check: the goal in " & GoalFileName & " is not yet " &
       "satisfied. Verifier feedback:\n\n" & feedback &
       "\n\nAddress it and keep working toward the goal; the " &
       "satisfaction check runs again when this turn ends."}

proc startGoal*(text: string; force = false; dir = "."): tuple[ok: bool,
    err: string] =
  ## The arming path behind `:goal`: write `goal.md` with the command-line
  ## text. A live goal refuses without `force` (`:goal!` carries the same
  ## force-past-the-guardrail meaning as `:q!`). The file is the whole
  ## protocol, bare existence arms goal mode at the next turn boundary,
  ## so there is nothing else to do here.
  if text.strip.len == 0:
    return (false, "usage: :goal <text>")
  if goalModeActive(dir) and not force:
    return (false, GoalFileName & " is already active; use :goal! to replace it")
  try:
    writeFile(dir / GoalFileName, text.strip & "\n")
    (true, "")
  except OSError, IOError:
    (false, getCurrentExceptionMsg())

proc completeGoal*(dir = "."): bool =
  ## The retirement path: `mv goal.md goal-confirmed.md`. On SATISFIED the
  ## confirmed file stays as the record; no session in this repo is in
  ## goal mode again unless a new `goal.md` appears.
  try:
    moveFile(dir / GoalFileName, dir / GoalConfirmedName)
    true
  except OSError, IOError:
    false

proc cancelGoal*(dir = "."): tuple[ok: bool, err: string] =
  ## The user exit behind bare `:goal!`: `mv goal.md goal-cancelled.md`.
  ## Interrupt only skips one satisfaction check; this ends goal mode,
  ## keeping the text as the record.
  if not goalModeActive(dir):
    return (false, "no goal active")
  try:
    moveFile(dir / GoalFileName, dir / GoalCancelledName)
    (true, "")
  except OSError, IOError:
    (false, getCurrentExceptionMsg())

# ---------- evidence ----------

proc briefFor(name: string, args: JsonNode): string =
  ## One-line digest of a tool call: the verb plus the argument that
  ## identifies the work (path, command, query). Never the full body:
  ## the verifier reads the repo itself when it needs more.
  template clip(s: string): string =
    utf8ByteCut(s, EvidenceBriefCap)
  case name
  of "bash", "shell":
    let cmd = args{"command"}.getStr("")
    result.add "bash: " & clip(cmd.splitLines[0])
  of "read":
    result.add "read: " & args{"path"}.getStr("")
    let off = args{"offset"}.getInt(0)
    if off > 0: result.add " (from line " & $off & ")"
  of "write":
    result.add "write: " & args{"path"}.getStr("") & " (" &
      $args{"body"}.getStr("").len & " bytes)"
  of "patch", "edit":
    let edits = args{"edits"}
    let n = if edits != nil and edits.kind == JArray: edits.len else: 0
    result.add "patch: " & args{"path"}.getStr("") & " (" & $n &
      (if n == 1: " edit)" else: " edits)")
  of "web_search":
    result.add "web_search: " & clip(args{"query"}.getStr(""))
  of "web_fetch":
    result.add "web_fetch: " & clip(args{"url"}.getStr(""))
  of "update_plan", "todo":
    result.add "update_plan"
  else:
    result.add name

proc resultHead(res: string): string =
  for line in res.splitLines:
    let l = line.strip
    if l.len > 0:
      return utf8ByteCut(l, EvidenceResultCap)
  "(no output)"

proc buildGoalEvidence*(messages: JsonNode): string =
  ## Harness-constructed evidence from the just-finished turn: walk the
  ## transcript's tool calls (the slice after the last user message,
  ## whoever sent it) and summarize each call's arguments and result.
  ## Assistant prose is never included — the verifier judges artifacts,
  ## not claims — and the whole summary is capped.
  if messages == nil or messages.kind != JArray: return
  var start = 0
  for i in countdown(messages.len - 1, 0):
    if messages[i].kind == JObject and
        messages[i]{"role"}.getStr == "user":
      start = i + 1
      break
  var calls: seq[tuple[id, name, brief: string]]
  var results: Table[string, string]
  for i in start ..< messages.len:
    let m = messages[i]
    if m.kind != JObject: continue
    case m{"role"}.getStr
    of "assistant":
      let tcs = m{"tool_calls"}
      if tcs == nil or tcs.kind != JArray: continue
      for tc in tcs:
        let fn = tc{"function"}
        if fn == nil or fn.kind != JObject: continue
        let name = fn{"name"}.getStr("")
        let argsStr = fn{"arguments"}.getStr("")
        let args =
          try: parseJson(if argsStr == "": "{}" else: argsStr)
          except CatchableError: newJObject()
        calls.add (tc{"id"}.getStr, name, briefFor(name, args))
    of "tool":
      results[m{"tool_call_id"}.getStr] = m{"content"}.getStr("")
    else: discard
  if calls.len == 0: return "(no tool calls this turn)"
  var shown = 0
  for c in calls:
    let item = "- " & c.brief & "\n  => " &
      resultHead(results.getOrDefault(c.id, "(no result recorded)"))
    if result.len + item.len > EvidenceCapBytes: break
    if result.len > 0: result.add "\n"
    result.add item
    inc shown
  if shown < calls.len:
    if result.len > 0: result.add "\n"
    result.add "(" & $(calls.len - shown) & " of " & $calls.len &
      " tool calls omitted, evidence cap reached)"

proc verifierPrompt*(goalText, evidence: string): string =
  "Goal (from " & GoalFileName & " in the repo root):\n\n" & goalText.strip &
    "\n\nEvidence from the agent's just-finished turn (harness-built from " &
    "the transcript; the agent's prose is excluded):\n\n" & evidence &
    "\n\nVerify the actual state of the repo and end with the verdict line."

# ---------- side call ----------

var goalCheckHook*: proc (p: Profile, goalText, evidence: string):
    tuple[ok: bool, text: string, err: string] = nil
  ## Test seam: when set, `runGoalCheck` sends its side call here instead
  ## of the wire. The verdict contract being a text line is what makes
  ## the loop testable without a provider.

proc runVerifierSideCall(p: Profile, goalText, evidence: string):
    tuple[ok: bool, text: string, err: string] =
  ## One-shot verifier: a fresh conversation (its own message list, the
  ## minimal preamble, the read-only roster), a bounded round of tool use,
  ## no session mutation. Same model as the agent: accepted trade. Runs in
  ## `sideCallMode` so its prose never paints as a live reply.
  sideCallMode = true
  defer: sideCallMode = false
  var convo = newJArray()
  convo.add %*{"role": "system", "content": VerifierPreamble}
  convo.add %*{"role": "user", "content": verifierPrompt(goalText, evidence)}
  let tools = verifierTools()
  var cache = newReadCache()
  var lastPrompt = 0
  for round in 1 .. MaxVerifierRounds:
    var usage: Usage
    var msg: JsonNode
    try:
      msg = callModel(p, convo, usage, lastPrompt, toolsOverride = tools)
    except ApiError as e:
      return (false, "", e.msg)
    lastPrompt = usage.promptTokens
    convo.add msg
    let tcs = msg{"tool_calls"}
    if tcs == nil or tcs.kind != JArray or tcs.len == 0:
      return (true, msg{"content"}.getStr(""), "")
    for tc in tcs:
      let id = tc{"id"}.getStr
      let fn = tc{"function"}
      let rawName = if fn != nil and fn.kind == JObject:
                      fn{"name"}.getStr("") else: ""
      let lt = rawName.find("<|")  # gpt-oss harmony channel suffix
      let name = if lt > 0: rawName[0 ..< lt] else: rawName
      let argsStr = if fn != nil and fn.kind == JObject:
                      fn{"arguments"}.getStr("") else: ""
      if name notin ["bash", "shell", "read"]:
        # The roster is the lock: an unoffered tool name (training
        # leakage, a write attempt) is refused structurally, not by
        # prompt.
        convo.add %*{"role": "tool", "tool_call_id": id,
          "content": "ERROR: not in the verifier roster; use bash " &
            "(checks and search) or read."}
        continue
      let args =
        try: parseJson(if argsStr == "": "{}" else: argsStr)
        except CatchableError: newJObject()
      let act = if name == "read": readAction(args) else: bashAction(args)
      let (outp, _, _) = runAction(act, cache)
      convo.add %*{"role": "tool", "tool_call_id": id, "content": outp}
  (false, "", "verifier exceeded " & $MaxVerifierRounds & " tool rounds")

proc runGoalCheck*(p: Profile, goalText, evidence: string): GoalCheckResult =
  ## Fire the side call and parse its verdict. `ok=false` means the call
  ## itself failed (network, provider, rounds exhausted): the caller keeps
  ## running without feedback and retries at the next boundary.
  let call = if goalCheckHook != nil: goalCheckHook else: runVerifierSideCall
  let (ok, text, err) = call(p, goalText, evidence)
  if not ok:
    return GoalCheckResult(ok: false, err: err)
  GoalCheckResult(ok: true, verdict: parseVerdict(text))
