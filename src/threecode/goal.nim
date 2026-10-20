## Harness modes: the file on disk is the protocol.
##
## A harness mode is one entry in the mode registry (`ModeDesc`): a
## trigger filename, a `:` verb, an arm-time validator, the two
## retirement names, and the mode's kickoff/feedback continuation
## builders. The substrate below — startup scan, kickoff/FEEDBACK
## plumbing, receipts, the rename protocol, the verifier side call —
## walks the registry and never names a mode itself. goal mode is
## entry #1; `cybernetic.md` is entry #2. One mode, one file, one verb.
##
## `goal.md` in the project root keeps a session on one goal. Arming is
## immediate: every `:goal` write path (TEXT, `new`, `edit`, force
## replace) appends a harness-autosent kickoff prompt and runs the turn
## at once instead of waiting for the next turn boundary — and a
## `goal.md` already on disk when the session opens is armed the same
## way: startup detection sends the same kickoff turn before the first
## prompt. The only other
## hook is the end-call boundary in `turns.nim`: when the turn's final
## model call completes and the harness is about to hand the prompt back
## to the user, it stats `goal.md`; bare existence activates (v1 waives
## marker sniff and name-collision handling). A side-call verifier (same
## model, fresh conversation, minimal preamble, no tools) judges the
## goal text against harness-built evidence from the just-finished
## turn plus the harness-captured working-tree diff. FEEDBACK sends
## the agent back in; SATISFIED renames the file to
## `goal-confirmed.md` and the session idles normally. Bare `:goal!`
## cancels into `goal-cancelled.md`. No per-tool-call checks, no
## system-prompt changes: the continuation message carries everything.
##
## The side call is also the future subagent primitive, so it is kept
## separate: its own message list, no session mutation, no tools.

import std/[json, os, osproc, strutils, tables]
import types, util, prompts, api, streamexec

const
  GoalFileName* = "goal.md"                 ## existence activates goal mode
  GoalConfirmedName* = "goal-confirmed.md"   ## the satisfied record
  GoalCancelledName* = "goal-cancelled.md"  ## the user-cancelled record
  GoalGivenUpName* = "goal-given-up.md"      ## reserved: nothing writes it
                                             ## yet; a failing harness retries
                                             ## instead of giving up
  EvidenceCapBytes* = 6000  ## evidence summary ceiling
  EvidenceBriefCap* = 160   ## per-call argument digest ceiling
  EvidenceResultCap* = 240  ## per-call result head ceiling
  GoalDiffCapBytes* = 8000  ## working-tree diff feed ceiling
  GoalDiffMaxUntracked* = 24  ## untracked files diffed before the elision note
  GoalKickoffPrefix* = "Goal armed: "  ## opens the kickoff message; replay
                                        ## matches it to pick the `◎` marker

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

  GoalStep* = object
    ## One visible verifier step. The toolless verifier produces exactly
    ## one: its reply, whose final line is the verdict. Everything the
    ## check says is scrollback material - the check must never look
    ## silent.
    prose*: string  ## the verifier's reply

const VerifierPreamble* = """You are verifying progress toward a goal. You get the goal text, an
evidence summary of the agent's last turn (harness-built from the
transcript's tool calls and their recorded results; the agent's prose
is excluded), and the harness-captured working-tree diff. You have no
tools and exactly one reply: judge from these inputs alone, briefly.
The recorded results are real harness captures, but they can be stale
if the agent changed things after the check they show. The agent's
claims are never evidence. If the goal requires runtime behavior
these inputs cannot confirm (tests passing, a build succeeding), do
not infer it: name the unconfirmed check in your feedback.
Sufficiency is relative to these inputs: when the diff is consistent
with the goal and a recorded result shows the goal's own verification
commands (tests, build) ran and passed, that counts as confirmation.
Accept SATISFIED then; do not demand proof these inputs cannot
contain. Judge whether the goal as stated is fully satisfied by what
the inputs actually show. Report exactly what you verified and how; never
overstate how deeply you verified. End with exactly one line: VERDICT:
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

proc goalKickoffMessage*(goalText: string): JsonNode =
  ## The harness-autosent prompt that starts goal achievement immediately
  ## after `goal.md` is written, instead of waiting for the next turn
  ## boundary. Same `agentSent` marking as the feedback continuation, so
  ## replay renders it as a `◎` item and no provider sees the marker.
  %*{"role": "user", "agentSent": true,
     "content": GoalKickoffPrefix & GoalFileName & " in this repository now " &
       "states the session's goal:\n\n" & goalText.strip &
       "\n\nStart working toward it now. A satisfaction check runs when " &
       "each turn ends and sends you back in with feedback until the " &
       "goal is met."}

# ---------- mode registry ----------

# Defined after the goal kickoff/feedback builders so the entry can
# reference them; the registry itself is a var so tests (and later
# embedders) can extend it.
type
  ModeDesc* = object
    ## One harness mode: the trigger file that arms it, the `:` verb
    ## that writes that file, the retirement names, and the mode's
    ## kickoff/feedback continuation builders. Modes are mutually
    ## exclusive — one mode, one file, one verb.
    name*: string          ## short name for receipts and the profile row
    fileName*: string      ## the trigger file; bare existence arms
    verb*: string          ## the `:` command that arms it
    confirmedName*: string  ## rename target on a SATISFIED verdict
    cancelledName*: string  ## rename target on user cancel
    givenUpName*: string    ## reserved retirement name
    validate*: proc (body: string): string
      ## Arm-time format contract: "" accepts the body, anything else is
      ## a teaching error that refuses the arm.
    composeBody*: proc (text: string): string
      ## `:<verb> <text>` -> the file body to write.
    kickoffMessage*: proc (body: string): JsonNode
    feedbackMessage*: proc (fb: string): JsonNode

var modeRegistry* = newSeq[ModeDesc]()
  ## The mode table. goal mode is entry #1, registered at module init;
  ## the shared substrate walks this and never names a mode itself.

template noMode*(m: ModeDesc): bool =
  m.name.len == 0

proc activeMode*(dir = "."): ModeDesc =
  ## The mode whose trigger file sits in `dir`, first registry hit; a
  ## zero `ModeDesc` (`noMode`) when none is armed.
  for m in modeRegistry:
    if fileExists(dir / m.fileName): return m

proc readModeText*(m: ModeDesc; dir = "."): string =
  try: readFile(dir / m.fileName)
  except CatchableError: ""

proc startMode*(m: ModeDesc; text: string; force = false;
                dir = "."): tuple[ok: bool, err: string] =
  ## The arming path behind every mode's verb: compose the file body
  ## from the command-line text, check the mode's format contract, and
  ## write it. A live file of the same mode refuses without `force`
  ## (`:goal!` carries the same force-past-the-guardrail meaning as
  ## `:q!`). A live file of any OTHER mode refuses outright: modes are
  ## mutually exclusive, and force replaces a mode's own file, never
  ## another mode's session.
  if text.strip.len == 0:
    return (false, "usage: " & m.verb & " <text>")
  for other in modeRegistry:
    if other.name != m.name and fileExists(dir / other.fileName):
      return (false, other.fileName & " (" & other.name & " mode) is " &
        "already active; harness modes are mutually exclusive - cancel " &
        "it first with " & other.verb & "!")
  if fileExists(dir / m.fileName) and not force:
    return (false, m.fileName & " is already active; use " & m.verb &
      "! to replace it")
  let body = m.composeBody(text)
  let verr = m.validate(body)
  if verr.len > 0:
    return (false, verr)
  try:
    writeFile(dir / m.fileName, body)
    (true, "")
  except OSError, IOError:
    (false, getCurrentExceptionMsg())

proc completeMode*(m: ModeDesc; dir = "."): bool =
  ## The retirement path on SATISFIED: `mv <file> <confirmedName>`. The
  ## confirmed file stays as the record; the mode is off until a new
  ## trigger file appears.
  try:
    moveFile(dir / m.fileName, dir / m.confirmedName)
    true
  except OSError, IOError:
    false

proc cancelMode*(m: ModeDesc; dir = "."): tuple[ok: bool, err: string] =
  ## The user exit behind bare `:<verb>!`: `mv <file> <cancelledName>`.
  ## Interrupt only skips one satisfaction check; this ends the mode,
  ## keeping the text as the record.
  if not fileExists(dir / m.fileName):
    return (false, "no " & m.name & " active")
  try:
    moveFile(dir / m.fileName, dir / m.cancelledName)
    (true, "")
  except OSError, IOError:
    (false, getCurrentExceptionMsg())

let goalMode* = ModeDesc(
  name: "goal",
  fileName: GoalFileName,
  verb: ":goal",
  confirmedName: GoalConfirmedName,
  cancelledName: GoalCancelledName,
  givenUpName: GoalGivenUpName,
  validate: proc (body: string): string = "",
  composeBody: proc (text: string): string = text.strip & "\n",
  kickoffMessage: goalKickoffMessage,
  feedbackMessage: goalFeedbackMessage)

modeRegistry.add goalMode

# The goal-mode entry points: the registry walk for entry #1.

proc startGoal*(text: string; force = false; dir = "."): tuple[ok: bool,
    err: string] =
  ## The arming path behind `:goal`: write `goal.md` with the command-line
  ## text. A live goal refuses without `force`; the file is the whole
  ## protocol, bare existence arms goal mode at the next turn boundary,
  ## so there is nothing else to do here.
  startMode(goalMode, text, force, dir)

proc completeGoal*(dir = "."): bool =
  ## The retirement path: `mv goal.md goal-confirmed.md`.
  completeMode(goalMode, dir)

proc cancelGoal*(dir = "."): tuple[ok: bool, err: string] =
  ## The user exit behind bare `:goal!`: `mv goal.md goal-cancelled.md`.
  cancelMode(goalMode, dir)

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
  ## First and LAST non-empty lines: command verdicts (test summaries,
  ## failures, "N of N green") land at the end of output, so a head-only
  ## digest hides exactly the lines that decide runtime goals.
  var first = ""
  var last = ""
  for line in res.splitLines:
    let l = line.strip
    if l.len == 0: continue
    if first.len == 0: first = utf8ByteCut(l, EvidenceResultCap)
    last = utf8ByteCut(l, EvidenceResultCap)
  if first.len == 0: return "(no output)"
  if last == first: return first
  first & "\n  ... " & last

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

proc buildGoalDiff*(dir = "."): string =
  ## Harness-captured working-tree delta fed to the verifier: porcelain
  ## status, the tracked changes (`git diff HEAD`), and the untracked
  ## files that diff cannot see, appended as new-file diffs. Capped hard:
  ## this is orientation so the verifier's tool rounds go into checking
  ## the work instead of discovering it. Empty outside a git repo.
  let git = "git -C " & quoteShell(dir) & " --no-optional-locks "
  let (status, code) = execCmdEx(git & "status --porcelain")
  if code != 0: return ""
  # Trailing-only trim: porcelain's leading column is meaningful
  # (" M" is worktree-dirty, "M " is staged).
  var parts = @[status.strip(leading = false)]
  # Exit code matters: a repo with no commits yet fails `diff HEAD`
  # with a fatal message that must not become feed content.
  let (tracked, tcode) = execCmdEx(git & "diff HEAD")
  if tcode == 0 and tracked.strip.len > 0: parts.add tracked.strip
  # Line list, not -z: execCmdEx is line-based (it re-appends the
  # newline per line), which would corrupt NUL-terminated output and
  # invent a phantom "\n" path. Newline-split is faithful here; git
  # C-quotes exotic names so they stay on one line.
  let (others, _) = execCmdEx(
    git & "ls-files --others --exclude-standard")
  var shown = 0
  for path in others.splitLines:
    if path.strip.len == 0: continue
    if shown >= GoalDiffMaxUntracked:
      parts.add "(" & $shown & " untracked files shown, more omitted)"
      break
    inc shown
    let (d, dcode) = execCmdEx(git & "diff --no-index -- /dev/null " &
      quoteShell(path))
    # Exit 1 is "files differ"; above that (missing file, a platform
    # refusing /dev/null) the header alone still names the file.
    if dcode > 1:
      parts.add "new file: " & path
    else:
      parts.add "new file: " & path & "\n" & d.strip
  result = parts.join("\n")
  if result.len > GoalDiffCapBytes:
    result = utf8ByteCut(result, GoalDiffCapBytes) &
      "\n(diff truncated at " & $GoalDiffCapBytes &
      " bytes; run git yourself for the rest)"

proc verifierPrompt*(goalText, evidence: string; diff = ""): string =
  result = "Goal (from " & GoalFileName & " in the repo root):\n\n" &
    goalText.strip &
    "\n\nEvidence from the agent's just-finished turn (harness-built from " &
    "the transcript; the agent's prose is excluded):\n\n" & evidence
  if diff.strip.len > 0:
    result.add "\n\nWorking-tree diff vs HEAD captured by the harness " &
      "(tracked changes plus untracked files, capped):\n\n" & diff.strip
  result.add "\n\nJudge from these inputs and end with the verdict line."

# ---------- side call ----------

var goalCheckHook*: proc (p: Profile, goalText, evidence: string):
    tuple[ok: bool, text: string, err: string] = nil
  ## Test seam: when set, `runGoalCheck` sends its side call here instead
  ## of the wire. The verdict contract being a text line is what makes
  ## the loop testable without a provider.

var goalStepHook*: proc (step: GoalStep) = nil
  ## Scrollback seam: the interactive controller installs this to commit
  ## verifier steps as they happen (dim, indented, clearly not the
  ## agent's work). Nil in tests and headless use, so a step is data,
  ## never a paint obligation.

proc stepProse(text: string) =
  if goalStepHook != nil and text.strip.len > 0:
    goalStepHook(GoalStep(prose: text))

proc runVerifierSideCall(p: Profile, goalText, evidence: string):
    tuple[ok: bool, text: string, err: string] =
  ## Toolless verifier: a fresh conversation (its own message list, the
  ## judge preamble, an empty roster so the provider offers nothing),
  ## one model call, no session mutation. Orientation is the harness's
  ## job - the goal text, the evidence digest, and the check-time diff
  ## are all in the opening message - so there are no tool rounds to
  ## bound or go astray in. Runs in `sideCallMode` so its prose never
  ## paints as a live reply.
  sideCallMode = true
  defer: sideCallMode = false
  var convo = newJArray()
  convo.add %*{"role": "system", "content": VerifierPreamble}
  # The diff is captured here, at check time, so it reflects exactly the
  # state the verdict is about.
  convo.add %*{"role": "user",
    "content": verifierPrompt(goalText, evidence, buildGoalDiff())}
  var usage: Usage
  var msg: JsonNode
  try:
    msg = callModel(p, convo, usage, 0, toolsOverride = newJArray())
  except ApiError as e:
    return (false, "", e.msg)
  let text = msg{"content"}.getStr("")
  stepProse(text)
  (true, text, "")

proc runGoalCheck*(p: Profile, goalText, evidence: string): GoalCheckResult =
  ## Fire the side call and parse its verdict. `ok=false` means the call
  ## itself failed (network, provider): the caller keeps running without
  ## feedback and retries at the next boundary.
  let call = if goalCheckHook != nil: goalCheckHook else: runVerifierSideCall
  let (ok, text, err) = call(p, goalText, evidence)
  if not ok:
    return GoalCheckResult(ok: false, err: err)
  GoalCheckResult(ok: true, verdict: parseVerdict(text))
