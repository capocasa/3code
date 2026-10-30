## The mode registry substrate: one mode = one trigger file + one verb,
## goal mode is entry #1, and arming is mutually exclusive across modes.
## The goal-mode entry itself is behavior-covered by test_goal.nim; this
## suite exercises the registry walks with a second, synthetic mode so
## exclusivity is testable before cybernetic mode exists.

import std/[json, os, osproc, strutils, tempfiles, unittest]
import threecode/goal
import threecode/types except Usage
import threecode/actions

proc withModeDir(body: proc (dir: string)) =
  let dir = createTempDir("modes-test-", "")
  defer: removeDir(dir)
  let old = getCurrentDir()
  setCurrentDir(dir)
  defer: setCurrentDir(old)
  body(dir)

proc synthMode(): ModeDesc =
  ModeDesc(
    name: "synth",
    fileName: "synth.md",
    verb: ":synth",
    confirmedName: "synth-confirmed.md",
    cancelledName: "synth-cancelled.md",
    givenUpName: "synth-given-up.md",
    validate: proc (body: string): string = "",
    composeBody: proc (text: string): string = text.strip & "\n",
    feedbackMessage: proc (body, fb: string): JsonNode = newJNull(),
    taskCounts: proc (body: string): string = "")

proc withSynthMode(body: proc ()) =
  ## Register a second mode for the duration of one test; the registry
  ## is process-global, so it comes back off afterwards.
  modeRegistry.add synthMode()
  defer: discard modeRegistry.pop()
  body()

suite "cybernetic plan parser":
  test "task items at any list depth, in file order":
    let plan = parsePlan("""# Ship it

- [x] registry extracted
- [ ] parser lands
  - [ ] nested counts as a task
* [X] star bullet, capital x
+ [ ] plus bullet
prose between items is presentation

## Current state

Parser done, wiring next.
""")
    check plan.valid
    check plan.hasCurrentState
    check plan.tasks.len == 5
    check plan.tasks[0].text == "registry extracted"
    check plan.tasks[0].checked
    check plan.tasks[1] == PlanTask(text: "parser lands", checked: false,
                                     depth: 0)
    check plan.tasks[2].text == "nested counts as a task"
    check plan.tasks[2].depth == 1
    check plan.tasks[3].checked
    check plan.tasks[4].text == "plus bullet"

  test "the Current state heading is matched exactly, case-insensitively":
    template hasCS(body: string): bool = parsePlan(body).hasCurrentState
    check hasCS("- [ ] x\n\n## Current state\n\nyep")
    check hasCS("- [ ] x\n\n## current STATE\n\nyep")
    check hasCS("- [ ] x\n\n### Current state\n\nyep")
    # A heading that merely mentions it, or a trailing colon, is not the
    # section; the teaching error names the exact form.
    check not hasCS("- [ ] x\n\n## Current state:\n\nnope")
    check not hasCS("- [ ] x\n\n## The current state of things\n\nnope")
    check not hasCS("- [ ] x\n\ncurrent state in prose\n\nnope")

  test "validation teaching errors":
    let noTasks = validatePlanBody("# Only prose\n\n## Current state\n\nnothing")
    check noTasks.startsWith("a cybernetic plan needs at least one task item")
    check "`- [ ] text`" in noTasks
    let noCS = validatePlanBody("- [ ] a task\n")
    check noCS.startsWith("a cybernetic plan needs a ## Current state section")
    check validatePlanBody("- [ ] a\n\n## Current state\n\ns") == ""

  test "orientation is the first unchecked task in file order":
    let plan = parsePlan(
      "- [x] done first\n- [ ] the one to do\n- [ ] later\n\n" &
      "## Current state\n\ns")
    check nextUncheckedText(plan) == "the one to do"
    let allDone = parsePlan(
      "- [x] a\n- [x] b\n\n## Current state\n\ns")
    check nextUncheckedText(allDone) == ""

  test "counts line":
    template counts(body: string): string =
      planCountsLine(parsePlan(body))
    check counts("- [ ] one\n\n## Current state\n\ns") == "1 task, 0 done"
    check counts("- [x] a\n- [ ] b\n- [ ] c\n\n## Current state\n\ns") ==
      "3 tasks, 1 done"
    check counts("no structure at all") == ""

suite "cybernetic skeleton (the :cyber writer)":
  test "prose-only text arms with the title as its one task":
    let body = cyberSkeleton("ship the parser")
    check body == "# ship the parser\n\n- [ ] ship the parser\n\n" &
      "## Current state\n\nNot begun.\n"
    check validatePlanBody(body) == ""

  test "bulleted lines become tasks, prose lands in Current state":
    let body = cyberSkeleton(
      "# Parse plans\n- write parser\n- [x] design format\n" &
      "prose note for later\n")
    check "- [ ] write parser" in body
    check "- [x] design format" in body
    check "prose note for later" in body
    check body.count("## Current state") == 1
    check validatePlanBody(body) == ""

suite "cybernetic mode entry":
  test "registered as entry #2 with file, verb, retirement names":
    check modeRegistry.len >= 2
    let m = modeRegistry[1]
    check m.name == "cybernetic"
    check m.fileName == CyberFileName
    check m.verb == ":cyber"
    check m.confirmedName == CyberConfirmedName
    check m.cancelledName == CyberCancelledName

  test "startMode arms through the skeleton and validates":
    withModeDir proc (dir: string) =
      check startMode(cyberneticMode, "wire the parser").ok
      check fileExists(CyberFileName)
      check validatePlanBody(readFile(CyberFileName)) == ""
      let balk = startMode(cyberneticMode, "another")
      check not balk.ok
      check balk.err == CyberFileName &
        " is already active; use :cyber! to replace it"
      check startMode(cyberneticMode, "replaced", force = true).ok

  test "mutual exclusivity with the real registry entries":
    withModeDir proc (dir: string) =
      check startGoal("live goal").ok
      let r = startMode(cyberneticMode, "my plan")
      check not r.ok
      check "goal.md (goal mode) is already active" in r.err
      check ":goal!" in r.err
      check not fileExists(CyberFileName)
      check cancelGoal().ok
      check startMode(cyberneticMode, "my plan").ok
      let r2 = startGoal("back again")
      check not r2.ok
      check "cybernetic.md (cybernetic mode) is already active" in r2.err

  test "retirement names are per-mode":
    withModeDir proc (dir: string) =
      writeFile(CyberFileName, "- [ ] x\n\n## Current state\n\ns")
      check cancelMode(cyberneticMode).ok
      check fileExists(CyberCancelledName)
      writeFile(CyberFileName, "- [x] x\n\n## Current state\n\ns")
      check completeMode(cyberneticMode)
      check fileExists(CyberConfirmedName)
      check not fileExists(CyberFileName)

  test "feedback message orients on the plan and states the duties":
    let body = "# P\n\n- [ ] a\n\n## Current state\n\ns"
    let msg = cyberFeedbackMessage(body, "tests missing")
    check msg{"agentSent"}.getBool(false)
    let c = msg{"content"}.getStr
    check "Verifier feedback:\n\ntests missing" in c
    check "Next unchecked task: \"a\"" in c
    check "## Current state" in c
    check "when this turn ends" in c

  test "counts hook on the descriptor":
    let body = "# Parse plans\n\n- [x] a\n- [ ] b\n\n## Current state\n\ns"
    check cyberneticMode.taskCounts(body) == "2 tasks, 1 done"
    check goalMode.taskCounts("anything") == ""

  test "conflictingMode names a second file on disk":
    withModeDir proc (dir: string) =
      check noMode(conflictingMode(goalMode))
      writeFile(CyberFileName, "- [ ] x\n\n## Current state\n\ns")
      let other = conflictingMode(goalMode)
      check other.name == "cybernetic"
      let label = modeConflictLabel(goalMode, other)
      check label.startsWith(CyberFileName & " is also on disk")
      check ":goal!" in label and ":cyber" in label

suite "mode registry":
  test "goal mode is entry #1; activeMode walks the registry":
    check modeRegistry.len >= 1
    check modeRegistry[0].fileName == GoalFileName
    withModeDir proc (dir: string) =
      check noMode(activeMode())
      writeFile(GoalFileName, "the goal\n")
      let m = activeMode()
      check not noMode(m)
      check m.name == "goal"
      check m.fileName == GoalFileName
      check m.verb == ":goal"
      check m.confirmedName == GoalConfirmedName
      check m.cancelledName == GoalCancelledName

  test "a second registry entry is discovered by the walk":
    withModeDir proc (dir: string) =
      withSynthMode proc () =
        writeFile("synth.md", "the synth plan\n")
        let m = activeMode()
        check m.name == "synth"
        # readModeText reads the descriptor's own file.
        check readModeText(m) == "the synth plan\n"

  test "startMode composes through the descriptor":
    withModeDir proc (dir: string) =
      withSynthMode proc () =
        check startMode(synthMode(), "  padded  ").ok
        check readFile("synth.md") == "padded\n"

  test "mutual exclusivity: arming a second mode is refused":
    withModeDir proc (dir: string) =
      withSynthMode proc () =
        discard startGoal("first things first")
        let r = startMode(synthMode(), "mine now")
        check not r.ok
        # The teaching error names the live mode's file and its exit.
        check GoalFileName in r.err
        check ":goal!" in r.err
        check not fileExists("synth.md")

  test "exclusivity is not forceable in either direction":
    withModeDir proc (dir: string) =
      withSynthMode proc () =
        discard startGoal("live")
        # Force replaces a mode's own live file, never another mode's.
        let r = startMode(synthMode(), "force it", force = true)
        check not r.ok
        check "mutually exclusive" in r.err
        writeFile("synth.md", "synth live\n")
        let r2 = startGoal("steal it back", force = true)
        check not r2.ok
        check "synth.md" in r2.err
        check readFile(GoalFileName).strip == "live"

  test "cancelMode and completeMode retire through the descriptor":
    withModeDir proc (dir: string) =
      withSynthMode proc () =
        writeFile("synth.md", "the synth plan\n")
        check cancelMode(synthMode()).ok
        check readFile("synth-cancelled.md") == "the synth plan\n"
        check noMode(activeMode())
        writeFile("synth.md", "again\n")
        check completeMode(synthMode())
        check readFile("synth-confirmed.md") == "again\n"
        let r = cancelMode(synthMode())
        check not r.ok
        check r.err == "no synth active"

  test "startMode's own-live balk and usage errors are per-verb":
    withModeDir proc (dir: string) =
      withSynthMode proc () =
        let usage = startMode(synthMode(), "   ")
        check not usage.ok
        check usage.err == "usage: :synth <text>"
        discard startMode(synthMode(), "live")
        let balk = startMode(synthMode(), "again")
        check not balk.ok
        check balk.err == "synth.md is already active; use :synth! to replace it"
        check startMode(synthMode(), "again", force = true).ok
        check readFile("synth.md").strip == "again"

suite "plan delta and verifier feed":
  test "delta: newly checked, unchecked, added, removed":
    let pre = """# P

- [ ] a
- [x] b
- [ ] dup
- [ ] gone
- [ ] c

## Current state

s
"""
    let post = """# P

- [x] a
- [ ] b
- [ ] dup
- [x] c
- [ ] fresh

## Current state

s
"""
    let d = planDelta(pre, post)
    check d.newlyChecked == @["a", "c"]
    check d.newlyUnchecked == @["b"]
    check d.added == @["fresh"]
    check d.removed == @["gone"]

  test "delta: duplicate task texts pair up one-to-one":
    let d = planDelta("- [ ] x\n- [ ] x\n\n## Current state\n\ns",
                      "- [x] x\n- [ ] x\n\n## Current state\n\ns")
    check d.newlyChecked == @["x"]
    check d.added.len == 0
    check d.removed.len == 0

  test "feed section: task list plus delta lines":
    let pre = "- [ ] a\n- [ ] b\n\n## Current state\n\ns"
    let post = "- [x] a\n- [ ] b\n- [ ] c\n\n## Current state\n\ns"
    let f = planFeedSection(pre, post)
    check "Plan task list (harness-parsed from cybernetic.md, 3 tasks, 1 done):" in f
    check "[x] a" in f
    check "[ ] b" in f
    check "[ ] c" in f
    check "newly checked: a" in f
    check "tasks added: c" in f
    check "no checkbox changes" notin f

  test "feed section: no snapshot says unknown; no changes says so; broken plan is empty":
    let body = "- [ ] a\n\n## Current state\n\ns"
    check "(no turn-start snapshot; delta unknown)" in planFeedSection("", body)
    check "(no checkbox changes this turn)" in planFeedSection(body, body)
    check planFeedSection(body, "# prose only") == ""

  test "turnHadToolActions: the last user message bounds the turn":
    let withCalls = %*[
      {"role": "user", "content": "go"},
      {"role": "assistant", "content": newJNull(),
       "tool_calls": [{"id": "c1", "type": "function",
         "function": {"name": "bash", "arguments": "{\"command\":\"ls\"}"}}]},
      {"role": "tool", "tool_call_id": "c1", "content": "x"}]
    check turnHadToolActions(withCalls)
    let proseOnly = %*[
      {"role": "user", "content": "go"},
      {"role": "assistant", "content": "just words"}]
    check not turnHadToolActions(proseOnly)
    # Calls before the last user message belong to an earlier turn.
    let stale = %*[
      {"role": "user", "content": "earlier"},
      {"role": "assistant", "content": newJNull(),
       "tool_calls": [{"id": "c0", "type": "function",
         "function": {"name": "bash", "arguments": "{}"}}]},
      {"role": "user", "content": "now"}]
    check not turnHadToolActions(stale)

  test "structureGuard fires on a broken plan with restore instructions":
    let ok = "- [ ] a\n\n## Current state\n\ns"
    check cyberneticMode.structureGuard(ok) == ""
    let lost = cyberneticMode.structureGuard("# all prose now")
    check lost.startsWith("Plan structure lost:")
    check "at least one task item" in lost
    check "mode stays armed" in lost
    # Current state gone, tasks still there: also guarded.
    check "Current state section" in
      cyberneticMode.structureGuard("- [ ] a\n")
    # goal mode has no guard.
    check goalMode.structureGuard("anything at all") == ""

  test "updateNote: only when work happened and the file is byte-identical":
    const body = "- [ ] a\n\n## Current state\n\ns"
    let note = cyberneticMode.updateNote(true, body, body)
    check note.startsWith("Work happened this turn but cybernetic.md is unchanged")
    check "## Current state" in note
    check cyberneticMode.updateNote(false, body, body) == ""
    check cyberneticMode.updateNote(true, body, body & "x") == ""
    check cyberneticMode.updateNote(true, "", "") == ""
    check goalMode.updateNote(true, body, body) == ""

  test "cybernetic runGoalCheck composes step-truth preamble and plan feed":
    let prof = Profile(name: "stub", family: "glm", model: "stub-model")
    goalCheckHook = proc (p: Profile, preamble, prompt: string):
        tuple[ok: bool, text: string, err: string] =
      check preamble == CyberVerifierPreamble
      check "name the first box that lies" in preamble
      # The verdict contract is still the preamble's final instruction.
      check preamble.strip.endsWith("what to do\nnext>.")
      check CyberFileName in prompt
      check "Plan task list (harness-parsed" in prompt
      check "newly checked: a" in prompt
      check "evidence line" in prompt
      (true, "VERDICT: SATISFIED", "")
    defer: goalCheckHook = nil
    # A hermetic cwd: buildGoalDiff captures the working tree, and this
    # repo's own diff would leak into the content assertions.
    withModeDir proc (dir: string) =
      let pre = "- [ ] a\n\n## Current state\n\ns"
      let post = "- [x] a\n\n## Current state\n\ns"
      let r = runGoalCheck(prof, cyberneticMode, post, "evidence line", pre)
      check r.ok
      check r.verdict.kind == gvkSatisfied

  test "goal mode runGoalCheck keeps the plain preamble, no feed":
    let prof = Profile(name: "stub", family: "glm", model: "stub-model")
    goalCheckHook = proc (p: Profile, preamble, prompt: string):
        tuple[ok: bool, text: string, err: string] =
      check preamble == VerifierPreamble
      check "PLAN" notin preamble
      check "Plan task list" notin prompt
      (true, "VERDICT: SATISFIED", "")
    defer: goalCheckHook = nil
    withModeDir proc (dir: string) =
      let r = runGoalCheck(prof, goalMode, "ship it", "evidence", "")
      check r.ok

suite "rollover handoff":
  test "currentStateSection extracts under the heading, stops at the next":
    let body = "# P\n\n- [ ] a\n\n## Current state\n\nLine one.\n\nLine two.\n\n## Next\n\nother section\n"
    let cs = currentStateSection(body)
    check cs == "Line one.\n\nLine two.\n"
    check currentStateSection("- [ ] a\n\n## Current state\n") == ""
    check currentStateSection("- [ ] a\n") == ""
    check currentStateSection(
      "- [ ] a\n\n## current STATE\n\nmixed case works\n") ==
      "mixed case works\n"

  test "currentStateSection caps a bloated section":
    let big = "- [ ] a\n\n## Current state\n\n" & "x".repeat(4000) & "\n"
    let cs = currentStateSection(big, cap = 500)
    check cs.len < 700
    check "truncated" in cs

  test "rollover message re-anchors at the plan":
    let body = """# Ship it

- [x] registry done
- [ ] rollover lands

## Current state

Phase 3 merged. Rollover next.
"""
    let msg = cyberRolloverMessage(body)
    check msg{"agentSent"}.getBool(false)
    let c = msg{"content"}.getStr
    check c.startsWith("Context rollover:")
    check "collapsed into a summary" in c
    check CyberFileName in c
    check "ground truth (2 tasks, 1 done)" in c
    check "Next unchecked task: \"rollover lands\"" in c
    check "Current state from the plan:" in c
    check "Phase 3 merged. Rollover next." in c
    check "keep ## Current state current" in c

  test "rollover wiring: cybernetic yes, goal nil":
    check cyberneticMode.rolloverNote != nil
    check goalMode.rolloverNote == nil

suite "verifier meets the session change log":
  test "the session diff is the primary feed; git becomes the complement":
    let prof = Profile(name: "stub", family: "glm", model: "stub-model")
    goalCheckHook = proc (p: Profile, preamble, prompt: string):
        tuple[ok: bool, text: string, err: string] =
      check "Changes this session (harness change log" in prompt
      check "+SESSION_LOG_LINE" in prompt
      # The git section is demoted, not dropped, and labeled as the
      # complement.
      check "complement; what git reports now" in prompt
      (true, "VERDICT: SATISFIED", "")
    defer: goalCheckHook = nil
    withModeDir proc (dir: string) =
      doAssert execCmdEx("git init -q .").exitCode == 0
      doAssert execCmdEx(
        "git -c user.email=t@t -c user.name=t commit -q --allow-empty -m b").exitCode == 0
      writeFile("base.txt", "base\n")
      let cache = newReadCache()
      discard runAction(Action(kind: akWrite, path: "log.txt",
        body: "SESSION_LOG_LINE\n"), cache)
      # A git-tracked change too, so both sections are present.
      writeFile("base.txt", "changed\n")
      let r = runGoalCheck(prof, cyberneticMode,
        "- [ ] a\n\n## Current state\n\ns", "evidence", "", cache)
      check r.ok
