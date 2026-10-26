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
## marker sniff and name-collision handling). A side-call verifier (the
## session's own model by default; a dedicated verification-class model
## when one is configured via `:verifier`, e.g. a System One decision
## model like Jev) judges the
## goal text against harness-built evidence from the just-finished
## turn plus the harness-captured working-tree diff. FEEDBACK sends
## the agent back in; SATISFIED renames the file to
## `goal-confirmed.md` and the session idles normally. Bare `:goal!`
## cancels into `goal-cancelled.md`. No per-tool-call checks, no
## system-prompt changes: the continuation message carries everything.
##
## The side call is also the future subagent primitive, so it is kept
## separate: its own message list, no session mutation, no tools.

import std/[algorithm, json, options, os, osproc, sequtils, strformat,
           strutils, tables]
import types, util, prompts, api, streamexec, config, actions

const
  GoalFileName* = "goal.md"                 ## existence activates goal mode
  GoalConfirmedName* = "goal-confirmed.md"   ## the satisfied record
  GoalCancelledName* = "goal-cancelled.md"  ## the user-cancelled record
  GoalGivenUpName* = "goal-given-up.md"      ## reserved: nothing writes it
                                             ## yet; a failing harness retries
                                             ## instead of giving up
  CyberFileName* = "cybernetic.md"           ## existence activates cybernetic mode
  CyberConfirmedName* = "cybernetic-confirmed.md"
  CyberCancelledName* = "cybernetic-cancelled.md"
  CyberGivenUpName* = "cybernetic-given-up.md"
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
    ## one: its reply minus the verdict line, whose verdict rides the
    ## step so scrollback can show it as an icon instead of the contract
    ## text. Everything the check says is scrollback material - the
    ## check must never look silent.
    prose*: string  ## the verifier's reply without its verdict line
    verdict*: GoalVerdictKind  ## gvkNone for informational notes

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

const StepTruthClause* = """The goal is a PLAN: you also get the harness-parsed task list and
the checkbox delta for this turn. Judge step truth: a checked box
must match the evidence and the diff; name the first box that lies
(checked without the work it claims, or finished work left unchecked
and unexplained). Treat newly checked boxes as claims to verify."""
  ## Prepended to the shared preamble for plan modes; the verdict
  ## contract stays the preamble's last instruction.

const CyberVerifierPreamble* = StepTruthClause & "\n\n" & VerifierPreamble

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

proc stripVerdictLine*(text: string): string =
  ## The display half of the verdict contract: the reply minus its
  ## final verdict line, so scrollback never needs to show the contract
  ## text (the verdict is an icon row instead). No verdict line means
  ## the text comes back unchanged.
  if parseVerdict(text).kind == gvkNone: return text
  let lines = text.strip.splitLines
  if lines.len <= 1: return ""
  lines[0 .. ^2].join("\n")

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

# ---------- cybernetic plan format ----------

type
  PlanTask* = object
    ## One `- [ ]`/`[x]` item in a cybernetic plan, any list depth;
    ## headings and phases are presentation, file order is the work order.
    text*: string
    checked*: bool
    depth*: int        ## list nesting (indent / 2); presentation only

  CyberPlan* = object
    ## The parsed cybernetic.md: the task list plus the presence of the
    ## Current state section. `valid` is false with a teaching `err`
    ## when the format contract is broken — validation is arm-time
    ## refusal and mid-run FEEDBACK material, never a silent mode drop.
    valid*: bool
    err*: string
    tasks*: seq[PlanTask]
    hasCurrentState*: bool

proc taskLine*(l: string): Option[PlanTask] =
  ## A markdown task item: optional indentation, a `-`/`*`/`+` bullet,
  ## then `[ ]` or `[x]`. Only inside cybernetic.md does a checkbox mean
  ## protocol — an unmarked goal.md stays plain text, no shape sniffing.
  let indent = l.len - l.strip(leading = true).len
  var s = l.strip(leading = true)
  if s.len == 0 or s[0] notin {'-', '*', '+'}: return
  s = s[1 ..^ 1].strip(leading = true)
  if s.len < 3 or s[0] != '[' or s[2] != ']' or s[1] notin {' ', 'x', 'X'}:
    return
  some PlanTask(text: s[3 ..^ 1].strip, checked: s[1] != ' ',
                depth: indent div 2)

proc isCurrentStateHeading*(l: string): bool =
  ## A heading (any `##`+ level) whose text is exactly "current state",
  ## case-insensitive. One matcher for the parser, the validator, and
  ## the rollover quote so the three cannot drift apart.
  let s = l.strip
  s.len > 2 and s.startsWith("##") and
    s.strip(true, true, {'#'}).strip.toLowerAscii == "current state"

proc parsePlan*(body: string): CyberPlan =
  ## Extract the plan structure: every task item in file order at any
  ## nesting depth, and whether a `## Current state` section exists.
  ## Everything else (headings, phases, prose) is presentation the
  ## parser carries no opinion about.
  for l in body.splitLines:
    if isCurrentStateHeading(l):
      result.hasCurrentState = true
    else:
      let t = taskLine(l)
      if t.isSome: result.tasks.add t.get
  result.valid = result.tasks.len > 0 and result.hasCurrentState
  if not result.valid:
    if result.tasks.len == 0:
      result.err = "a cybernetic plan needs at least one task item (a " &
        "`- [ ] text` line; " & CyberFileName & " is the plan the " &
        "harness runs, one checkbox per step)"
    else:
      result.err = "a cybernetic plan needs a ## Current state section " &
        "(what is true now, what is next)"

proc validatePlanBody*(body: string): string =
  ## The cybernetic mode's arm-time validator: "" accepts, a teaching
  ## error refuses the arm.
  parsePlan(body).err

proc nextUncheckedText*(plan: CyberPlan): string =
  ## Orientation: the first unchecked task in file order.
  for t in plan.tasks:
    if not t.checked: return t.text

proc planCountsLine*(plan: CyberPlan): string =
  ## The receipt/marker counts line, e.g. `3 tasks, 1 done`.
  if plan.tasks.len == 0: return
  let done = plan.tasks.countIt(it.checked)
  $plan.tasks.len & " task" & (if plan.tasks.len != 1: "s" else: "") &
    ", " & $done & " done"

type
  PlanDelta* = object
    ## Checkbox movement between two snapshots of cybernetic.md,
    ## matched by task text (first match consumed, so duplicated task
    ## texts still pair up).
    newlyChecked*: seq[string]
    newlyUnchecked*: seq[string]
    added*: seq[string]
    removed*: seq[string]

proc planDelta*(pre, post: string): PlanDelta =
  let a = parsePlan(pre).tasks
  let b = parsePlan(post).tasks
  var consumed = newSeq[bool](b.len)
  for t in a:
    var found = -1
    for j, u in b:
      if not consumed[j] and u.text == t.text:
        found = j
        break
    if found < 0:
      result.removed.add t.text
    else:
      consumed[found] = true
      if t.checked and not b[found].checked: result.newlyUnchecked.add t.text
      elif not t.checked and b[found].checked: result.newlyChecked.add t.text
  for j, u in b:
    if not consumed[j]: result.added.add u.text

proc planFeedSection*(pre, post: string): string =
  ## The structural half of the cybernetic verifier's feed: the parsed
  ## task list plus the per-turn checkbox delta, so the side call judges
  ## step truth (do checked boxes match evidence and diff) instead of
  ## vibes. Empty when the post state has no task list (structure loss
  ## is the guard's business, not the verifier's).
  let plan = parsePlan(post)
  if plan.tasks.len == 0: return
  result = "Plan task list (harness-parsed from " & CyberFileName & ", " &
    planCountsLine(plan) & "):"
  for t in plan.tasks:
    result.add "\n  [" & (if t.checked: "x" else: " ") & "] " & t.text
  result.add "\n\nCheckbox delta this turn:"
  if pre.strip.len == 0:
    result.add "\n  (no turn-start snapshot; delta unknown)"
    return
  let d = planDelta(pre, post)
  if d.newlyChecked.len == 0 and d.newlyUnchecked.len == 0 and
      d.added.len == 0 and d.removed.len == 0:
    result.add "\n  (no checkbox changes this turn)"
    return
  if d.newlyChecked.len > 0:
    result.add "\n  newly checked: " & d.newlyChecked.join("; ")
  if d.newlyUnchecked.len > 0:
    result.add "\n  newly unchecked: " & d.newlyUnchecked.join("; ")
  if d.added.len > 0:
    result.add "\n  tasks added: " & d.added.join("; ")
  if d.removed.len > 0:
    result.add "\n  tasks removed: " & d.removed.join("; ")

proc currentStateSection*(body: string; cap = 1500): string =
  ## The text under `## Current state`, up to the next heading, for the
  ## rollover handoff's quote. Capped so a bloated section cannot make
  ## the handoff itself a context problem.
  var inSection = false
  for l in body.splitLines:
    if inSection and l.strip.startsWith("#"): break
    if not inSection:
      if isCurrentStateHeading(l): inSection = true
      continue
    result.add l & "\n"
  if result.strip.len == 0: return ""
  if result.len > cap:
    result = utf8ByteCut(result, cap) & "\n(quoted Current state truncated)"
  else:
    result = result.strip & "\n"

proc planTitle*(body: string): string =
  ## The plan's title: the first heading if there is one, else the
  ## first non-empty line.
  for l in body.splitLines:
    let s = l.strip
    if s.len == 0: continue
    if s.startsWith("#"): return s.strip(true, false, {'#'}).strip
    return s
  CyberFileName

proc cyberSkeleton*(text: string): string =
  ## `:cyber <text>` authoring: the first line titles the plan (a `#`
  ## heading if given), bulleted or checkbox lines become task items,
  ## remaining prose lands in Current state. Prose-only input still
  ## arms — the title line doubles as the one task — because the mode
  ## must never refuse to start.
  var title = ""
  var tasks: seq[PlanTask] = @[]
  var prose: seq[string] = @[]
  for raw in text.strip.splitLines:
    let l = raw.strip
    if l.len == 0: continue
    if title.len == 0 and l.startsWith("#"):
      title = l.strip(true, false, {'#'}).strip
      continue
    let t = taskLine(l)
    if t.isSome:
      tasks.add t.get
    else:
      # A bare bullet is a task that forgot its checkbox; prose that
      # carries no bullet marker is Current state material.
      let bare = l.strip(leading = true)
      if bare.len > 1 and bare[0] in {'-', '*', '+'}:
        tasks.add PlanTask(text: bare[1 ..^ 1].strip(leading = true))
      elif title.len == 0:
        title = l
      else:
        prose.add l
  if title.len == 0: title = "Plan"
  if tasks.len == 0: tasks.add PlanTask(text: title)
  result = "# " & title & "\n\n"
  for t in tasks:
    result.add "- [" & (if t.checked: 'x' else: ' ') & "] " & t.text & "\n"
  result.add "\n## Current state\n\n"
  if prose.len > 0:
    for p in prose: result.add p & "\n"
  else:
    result.add "Not begun.\n"

proc cyberKickoffMessage*(body: string): JsonNode =
  ## The cybernetic kickoff: same shape and `agentSent` marking as the
  ## goal kickoff, but plan-aware — the counts ride the header and the
  ## orientation paragraph names the next unchecked task, so direction
  ## comes from the harness, not model vibes.
  let plan = parsePlan(body)
  let counts = planCountsLine(plan)
  let next = nextUncheckedText(plan)
  var content = GoalKickoffPrefix & CyberFileName &
    " in this repository now states the session's plan"
  if counts.len > 0: content.add " (" & counts & ")"
  content.add ":\n\n" & body.strip
  if next.len > 0:
    content.add "\n\nStart with the next unchecked task: \"" & next &
      "\" (first unchecked task in file order). Check off each task " &
      "as it completes, record what the step taught under ## Current " &
      "state, and keep working through the plan in order."
  elif plan.tasks.len > 0:
    content.add "\n\nEvery task in the plan is already checked; the " &
      "verifier confirms the work or names what still lies."
  content.add "\n\nA satisfaction check runs when each turn ends and " &
    "sends you back in with feedback until the plan is complete."
  %*{"role": "user", "agentSent": true, "content": content}

proc cyberRolloverMessage*(body: string): JsonNode =
  ## The rollover handoff: after a context collapse the fresh context
  ## re-anchors at the plan file - the counts, the next unchecked task
  ## by name, and the plan's own Current state section, quoted.
  let plan = parsePlan(body)
  let counts = planCountsLine(plan)
  let next = nextUncheckedText(plan)
  var content = "Context rollover: the conversation above was just " &
    "collapsed into a summary. The plan in " & CyberFileName &
    " is the session's ground truth"
  if counts.len > 0: content.add " (" & counts & ")"
  content.add "."
  if next.len > 0:
    content.add " Next unchecked task: \"" & next & "\"."
  let cs = currentStateSection(body)
  if cs.len > 0:
    content.add "\n\nCurrent state from the plan:\n\n" & cs
  content.add "\n\nKeep working the plan; check off tasks as they " &
    "complete and keep ## Current state current."
  %*{"role": "user", "agentSent": true, "content": content}

proc cyberFeedbackMessage*(body, feedback: string): JsonNode =
  ## The cybernetic FEEDBACK continuation: the verifier's words plus the
  ## mode's own duties — check off what finished, record what the turn
  ## taught, then the next unchecked task by name.
  let next = nextUncheckedText(parsePlan(body))
  let orient =
    if next.len > 0: "Next unchecked task: \"" & next & "\". "
    else: ""
  %*{"role": "user", "agentSent": true,
     "content": "Cybernetic check: the plan in " & CyberFileName &
       " is not yet complete. Verifier feedback:\n\n" & feedback &
       "\n\n" & orient &
       "Update " & CyberFileName & " to match reality - check off " &
       "finished tasks, record what this turn taught under ## Current " &
       "state - then keep working; the satisfaction check runs again " &
       "when this turn ends."}

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
    feedbackMessage*: proc (body, fb: string): JsonNode
      ## The FEEDBACK continuation; takes the current file body so a
      ## mode can orient (name the next step) on its own structure.
    taskCounts*: proc (body: string): string
      ## Counts line for the arm receipt and the kickoff marker, e.g.
      ## `3 tasks, 1 done`; "" when the mode has no task structure.
    kickoffDisplay*: proc (body: string): string
      ## The scrollback kickoff item body under the `◎` marker.
    structureGuard*: proc (post: string): string
      ## Turn-boundary duty: mid-run structure loss returns the full
      ## restore-the-plan continuation content (no side call runs);
      ## "" lets the boundary proceed to the verifier.
    updateNote*: proc (worked: bool; pre, post: string): string
      ## Turn-boundary duty: update discipline. Work happened this turn
      ## but the mode file is byte-identical to its turn-start snapshot
      ## -> the mechanical note; "" when no note is owed.
    verifierFeed*: proc (pre, post: string): string
      ## Extra structural feed sections for the verifier prompt; "" when
      ## the mode adds none.
    judgeStepTruth*: bool
      ## Prepend `StepTruthClause` to the verifier preamble.
    rolloverNote*: proc (body: string): JsonNode
      ## Rollover duty: the re-anchoring continuation injected after a
      ## context collapse. Nil = the mode has no rollover handoff.

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
  feedbackMessage: proc (body, fb: string): JsonNode = goalFeedbackMessage(fb),
  taskCounts: proc (body: string): string = "",
  kickoffDisplay: proc (body: string): string = body.strip,
  structureGuard: proc (post: string): string = "",
  updateNote: proc (worked: bool; pre, post: string): string = "",
  verifierFeed: proc (pre, post: string): string = "",
  judgeStepTruth: false)

modeRegistry.add goalMode

let cyberneticMode* = ModeDesc(
  name: "cybernetic",
  fileName: CyberFileName,
  verb: ":cyber",
  confirmedName: CyberConfirmedName,
  cancelledName: CyberCancelledName,
  givenUpName: CyberGivenUpName,
  validate: validatePlanBody,
  composeBody: cyberSkeleton,
  kickoffMessage: cyberKickoffMessage,
  feedbackMessage: cyberFeedbackMessage,
  taskCounts: proc (body: string): string = planCountsLine(parsePlan(body)),
  kickoffDisplay: (proc (body: string): string =
    let plan = parsePlan(body)
    let counts = planCountsLine(plan)
    result = planTitle(body)
    if counts.len > 0: result.add " - " & counts
    let next = nextUncheckedText(plan)
    if next.len > 0: result.add "; next: " & next),
  structureGuard: (proc (post: string): string =
    let err = validatePlanBody(post)
    if err.len == 0: return ""
    result = "Plan structure lost: " & err & ". Restore the plan file now - " &
      "the task list and the ## Current state section, keeping every " &
      "box already earned. The mode stays armed; the next satisfaction " &
      "check judges the restored plan."),
  updateNote: (proc (worked: bool; pre, post: string): string =
    if worked and post.len > 0 and pre == post:
      result = "Work happened this turn but " & CyberFileName &
        " is unchanged. Update the plan to match reality: check off the " &
        "tasks this turn finished, and record what the step taught " &
        "under ## Current state."),
  verifierFeed: planFeedSection,
  judgeStepTruth: true,
  rolloverNote: cyberRolloverMessage)

modeRegistry.add cyberneticMode

proc harnessNote*(content: string): JsonNode =
  ## A harness-autosent continuation carrying fully-formed content (the
  ## structure-guard's restore note): same `agentSent` marking as every
  ## other autosend, so replay renders it as a `»` item and no provider
  ## ever sees the marker.
  %*{"role": "user", "agentSent": true, "content": content}

proc conflictingMode*(m: ModeDesc; dir = "."): ModeDesc =
  ## The first OTHER registry mode whose trigger file also sits in `dir`
  ## while `m` is the active one: a second file on disk is a refused
  ## arming, and the refusal must reach the prompt, never pass silently.
  for other in modeRegistry:
    if other.name != m.name and fileExists(dir / other.fileName): return other

proc modeConflictLabel*(m, other: ModeDesc): string =
  ## The one-line receipt for that refusal, shared by the startup scan
  ## and the turn-boundary detection so the two cannot drift apart.
  other.fileName & " is also on disk but " & m.name & " mode is active; " &
    "harness modes are mutually exclusive (" & m.verb & "! cancels " &
    m.name & " mode, then " & other.verb & " arms the plan)"

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

proc lastTurnStart*(messages: JsonNode): int =
  ## Index one past the last user message, whoever sent it: the slice
  ## of the transcript that belongs to the just-finished turn. Shared
  ## by the evidence builder and the tool-action probe so the two can
  ## never disagree about where a turn begins.
  if messages == nil or messages.kind != JArray: return 0
  for i in countdown(messages.len - 1, 0):
    if messages[i].kind == JObject and
        messages[i]{"role"}.getStr == "user":
      return i + 1
  0

proc turnHadToolActions*(messages: JsonNode): bool =
  ## Did the just-finished turn run any tool call? The cybernetic
  ## update-discipline heuristic: work happened = at least one tool
  ## action in the turn's slice (v1 is tool actions only).
  if messages == nil or messages.kind != JArray: return false
  for i in lastTurnStart(messages) ..< messages.len:
    let tcs = messages[i]{"tool_calls"}
    if messages[i].kind == JObject and
        messages[i]{"role"}.getStr == "assistant" and
        tcs != nil and tcs.kind == JArray and tcs.len > 0:
      return true
  false

proc turnDidWork*(messages: JsonNode; cache: ReadCache;
                   baseline: int): bool =
  ## Work happened, content-aware: the session change log grew past its
  ## turn-start baseline (a real mutation, not just reads). Falls back
  ## to any tool action when there is no log yet (nil cache).
  if cache != nil: cache.changes.len != baseline
  else: turnHadToolActions(messages)

proc buildGoalEvidence*(messages: JsonNode): string =
  ## Harness-constructed evidence from the just-finished turn: walk the
  ## transcript's tool calls (the slice after the last user message,
  ## whoever sent it) and summarize each call's arguments and result.
  ## Assistant prose is never included — the verifier judges artifacts,
  ## not claims — and the whole summary is capped.
  if messages == nil or messages.kind != JArray: return
  let start = lastTurnStart(messages)
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

const SessionDiffPerPathCap* = 4000
  ## One path's rendered net diff ceiling inside the session change log
  ## feed; past it the path degrades to a name-only line.

proc buildSessionDiff*(cache: ReadCache): string =
  ## The session change log rendered as one net diff per mutated path,
  ## path-sorted and capped: what the agent's own tool actions changed
  ## this session, git or no git. Binary and oversize paths degrade to
  ## name-only lines - silent omission is the only unforgivable mode.
  if cache == nil or cache.changes.len == 0: return
  var paths = toSeq(cache.changes.keys)
  paths.sort
  for p in paths:
    let (before, after) = cache.changes[p]
    if before == after: continue  # touched but net-identical
    if isBinaryContent(before) or isBinaryContent(after):
      result.add "changed (binary, content not shown): " & p & "\n"
      continue
    let d = computeDiff(before, after, p)
    if d.len > SessionDiffPerPathCap:
      result.add "changed (diff over " & $SessionDiffPerPathCap &
        " bytes, not shown): " & p & "\n"
      continue
    if result.len + d.len > GoalDiffCapBytes:
      result.add "(session diff truncated at " & $GoalDiffCapBytes &
        " bytes; remaining changed paths omitted)\n"
      break
    result.add d
    if not result.endsWith("\n"): result.add "\n"
  result = result.strip(chars = {'\n'})

proc verifierPrompt*(goalText, evidence: string; diff = "";
                    sourceFile = GoalFileName; planFeed = "";
                    sessionDiff = ""): string =
  result = "Goal (from " & sourceFile & " in the repo root):\n\n" &
    goalText.strip &
    "\n\nEvidence from the agent's just-finished turn (harness-built from " &
    "the transcript; the agent's prose is excluded):\n\n" & evidence
  if sessionDiff.strip.len > 0:
    # The session change log is the primary record: the agent's own tool
    # actions, net per path, git or no git.
    result.add "\n\nChanges this session (harness change log, net per " &
      "mutated path):\n\n" & sessionDiff.strip
  if diff.strip.len > 0:
    result.add "\n\nWorking-tree diff vs HEAD captured by the harness " &
      "(complement; what git reports now):\n\n" & diff.strip
  if planFeed.strip.len > 0:
    result.add "\n\n" & planFeed.strip
  result.add "\n\nJudge from these inputs and end with the verdict line."

# ---------- side call ----------

var goalCheckHook*: proc (p: Profile, preamble, prompt: string):
    tuple[ok: bool, text: string, err: string] = nil
  ## Test seam: when set, `runGoalCheck` sends its side call here with
  ## exactly what would go on the wire (judge preamble + opening
  ## prompt). The verdict contract being a text line is what makes
  ## the loop testable without a provider.

var goalStepHook*: proc (step: GoalStep) = nil
  ## Scrollback seam: the interactive controller installs this to commit
  ## verifier steps as they happen (a `⌕` item rendered through the
  ## regular response path, with the verdict as a colored icon row). Nil
  ## in tests and headless use, so a step is data, never a paint
  ## obligation.

proc stepProse(text: string; verdict = gvkNone) =
  ## Emit a verifier step. A bare verdict with no prose still emits (an
  ## icon-only check is legible); an informational note with neither
  ## prose nor verdict is nothing at all.
  if goalStepHook != nil and (text.strip.len > 0 or verdict != gvkNone):
    goalStepHook(GoalStep(prose: text, verdict: verdict))

proc runVerifierSideCall(p: Profile, preamble, prompt: string):
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
  convo.add %*{"role": "system", "content": preamble}
  convo.add %*{"role": "user", "content": prompt}
  var usage: Usage
  var msg: JsonNode
  try:
    msg = callModel(p, convo, usage, 0, toolsOverride = newJArray())
  except ApiError as e:
    return (false, "", e.msg)
  let text = msg{"content"}.getStr("")
  stepProse(stripVerdictLine(text), parseVerdict(text).kind)
  (true, text, "")

# ---------- decision verifier (System One) ----------

const DecisionSatisfiedP* = 0.75
  ## A `satisfied` noul probability at or above this confirms the goal.
  ## Asymmetric by design: a wrong SATISFIED retires the goal file and
  ## ends the loop, while a wrong FEEDBACK only costs one more turn, so
  ## the bar sits well above a coin flip.

const DecisionGapLabels*: seq[tuple[key, label: string]] = @[
  ("implementation", "working code for some requirement is missing or incomplete"),
  ("tests", "tests for the goal are missing or not shown passing"),
  ("evidence", "claims are made but nothing recorded demonstrates them"),
  ("docs", "documentation or changelog the goal asks for is missing"),
  ("other", "something else the goal asks for is missing"),
  ("nothing", "nothing: the goal is met"),
]
  ## The `gap` choice options, in wire order. The labels are what the
  ## agent actually sees: decision models return probabilities, never
  ## prose, so the feedback line is harness-composed from these.

proc decisionQuestions*(): JsonNode =
  ## The question set the decision verifier answers per check. Two
  ## questions, one forward pass: the verdict itself (`satisfied`, a
  ## noul) and the next thing to do (`gap`, a choice) so an unsatisfied
  ## verdict still sends the agent back in with a direction instead of
  ## a bare "no".
  var criteria = newJObject()
  for (k, label) in DecisionGapLabels:
    criteria[k] = %label
  %*{
    "satisfied": {"type": "noul",
      "instructions": "Every requirement of the goal in this state, " &
        "taken as written and as a whole, is already met by the work " &
        "and the recorded evidence shown in this state. Recorded tool " &
        "results count; the agent's own claims do not."},
    "gap": {"type": "choice", "instructions":
      "The single most important thing still missing for the goal",
      "criteria": criteria}}

func decisionSatisfiedP*(answers: JsonNode): float =
  ## The `satisfied` noul probability, -1 when the answer is absent or
  ## not a number (a broken check, not a failed one). Integers count:
  ## a whole `1` or `0` is valid JSON for a probability at the rails.
  let n = answers{"satisfied", "noul"}
  case (if n == nil: JNull else: n.kind)
  of JFloat: n.getFloat
  of JInt: n.getInt.float
  else: -1.0

proc decisionGap*(answers: JsonNode): string =
  ## The label for the `gap` choice the verifier picked (highest
  ## probability), "" when absent. Labels, not keys: this text goes
  ## straight into the agent-facing feedback.
  let c = answers{"gap"}
  if c == nil: return
  let probs = c{"probabilities"}
  if probs != nil and probs.kind == JObject and probs.len > 0:
    var bestK = ""
    var bestP = -1.0
    for k, v in probs:
      if v.kind == JFloat and v.getFloat > bestP:
        bestP = v.getFloat
        bestK = k
    if bestK != "":
      for (key, label) in DecisionGapLabels:
        if key == bestK: return label
      return bestK
  let picked = c{"choice"}
  if picked != nil and picked.kind == JString:
    for (key, label) in DecisionGapLabels:
      if key == picked.getStr: return label
    return picked.getStr

proc decisionSummaryLine*(answers: JsonNode): string =
  ## One scrollback line for the verifier item body: what the decision
  ## model answered, in its own numbers.
  let p = decisionSatisfiedP(answers)
  let gap = decisionGap(answers)
  if p < 0: return
  &"verifier decision: p(satisfied)={p.formatFloat(ffDecimal, 2)}" &
    (if gap.len > 0: "; gap: " & gap else: "")

proc verdictFromDecision*(answers: JsonNode): GoalVerdict =
  ## Decision answers -> goal verdict. `gvkNone` for a missing
  ## `satisfied` answer: a check without a readable verdict is a failed
  ## check, never a passing one (same rule as `parseVerdict`).
  let p = decisionSatisfiedP(answers)
  if p < 0: return
  if p >= DecisionSatisfiedP:
    result.kind = gvkSatisfied
  else:
    result.kind = gvkFeedback
    let gap = decisionGap(answers)
    result.feedback =
      "the decision verifier puts p(satisfied)=" &
      p.formatFloat(ffDecimal, 2) &
      (if gap.len > 0: "; most important gap: " & gap else: "")

proc runDecisionCheck(p: Profile; m: ModeDesc; modeText, evidence,
                      preSnapshot: string; cache: ReadCache):
    GoalCheckResult =
  ## The System One check: one decision request carrying the same
  ## orientation the chat verifier gets (goal text, evidence digest,
  ## check-time diff, structural feed) as the `state`, no preamble
  ## needed - the instructions live in the questions. Failure is
  ## `ok=false`, exactly like a failed chat side call: the goal stays
  ## armed and the next turn boundary retries.
  sideCallMode = true
  defer: sideCallMode = false
  var usage: Usage
  try:
    let resp = callSystemOne(p, verifierPrompt(modeText, evidence,
      buildGoalDiff(), m.fileName, m.verifierFeed(preSnapshot, modeText),
      buildSessionDiff(cache)), decisionQuestions(), usage)
    let answers = resp{"answers"}
    let v = verdictFromDecision(answers)
    stepProse(decisionSummaryLine(answers), v.kind)
    GoalCheckResult(ok: true, verdict: v)
  except ApiError as e:
    GoalCheckResult(ok: false, err: e.msg)

proc verifierProfileFor*(p: Profile): Profile =
  ## The profile the check actually runs on: the configured verifier
  ## model when one is enabled and resolvable, else the session's own
  ## model — the behavior goal mode had before verifier models existed.
  ## An enabled verifier that no longer resolves (provider section gone,
  ## key removed) falls back with a visible note instead of silently
  ## skipping the check or killing the turn.
  if not verifierEnabled or verifierModelSpec == "": return p
  let (cand, err) = buildVerifierProfile(verifierModelSpec, activeProviders)
  if err != "":
    stepProse("verifier " & verifierModelSpec & " unavailable (" & err &
      "), checking with the session model")
    return p
  if privateMode and not privateAllowed(cand):
    # The check ships the goal text and the working-tree diff, so it is
    # exactly the data private mode exists to fence: an untrusted
    # verifier never sees it. The session model (already allow-private,
    # or it would not be running) takes the check instead.
    stepProse("verifier " & verifierModelSpec & " is not allow-private, " &
      "checking with the session model")
    return p
  cand

proc runGoalCheck*(p: Profile; m: ModeDesc; modeText, evidence,
                   preSnapshot: string; cache: ReadCache = nil):
    GoalCheckResult =
  ## Compose the side call from the mode descriptor — the preamble
  ## (step-truth judging for plan modes), the mode text, the evidence,
  ## the check-time diff, and the structural feed — then fire it and
  ## parse the verdict. A decision-model verifier (System One) answers
  ## typed questions in one request; everything else gets the chat side
  ## call. `ok=false` means the call itself failed (network, provider):
  ## the caller keeps running without feedback and retries at the next
  ## boundary.
  let vp = verifierProfileFor(p)
  if goalCheckHook == nil and verifierDialect(vp.model) == "systemone":
    return runDecisionCheck(vp, m, modeText, evidence, preSnapshot, cache)
  let preamble =
    if m.judgeStepTruth: CyberVerifierPreamble else: VerifierPreamble
  let prompt = verifierPrompt(modeText, evidence, buildGoalDiff(),
                              m.fileName, m.verifierFeed(preSnapshot, modeText),
                              buildSessionDiff(cache))
  let call = if goalCheckHook != nil: goalCheckHook else: runVerifierSideCall
  let (ok, text, err) = call(vp, preamble, prompt)
  if not ok:
    return GoalCheckResult(ok: false, err: err)
  GoalCheckResult(ok: true, verdict: parseVerdict(text))
