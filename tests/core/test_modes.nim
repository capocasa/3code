## The mode registry substrate: one mode = one trigger file + one verb,
## goal mode is entry #1, and arming is mutually exclusive across modes.
## The goal-mode entry itself is behavior-covered by test_goal.nim; this
## suite exercises the registry walks with a second, synthetic mode so
## exclusivity is testable before cybernetic mode exists.

import std/[json, os, strutils, tempfiles, unittest]
import threecode/goal

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
    kickoffMessage: proc (body: string): JsonNode = newJNull(),
    feedbackMessage: proc (body, fb: string): JsonNode = newJNull(),
    taskCounts: proc (body: string): string = "",
    kickoffDisplay: proc (body: string): string = body.strip)

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

  test "a heading title is honored; text without one uses the first line":
    check planTitle(cyberSkeleton("# T\n- [ ] t")) == "T"
    check planTitle("# First heading\n\n- [ ] x") == "First heading"
    check planTitle("No heading at all\n\n- [ ] x") == "No heading at all"

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

  test "kickoff message carries counts and names the next task":
    let body = "# P\n\n- [x] a\n- [ ] b\n- [ ] c\n\n## Current state\n\ns"
    let msg = cyberKickoffMessage(body)
    check msg{"role"}.getStr == "user"
    check msg{"agentSent"}.getBool(false)
    let c = msg{"content"}.getStr
    check c.startsWith(GoalKickoffPrefix & CyberFileName)
    check "(3 tasks, 1 done)" in c
    check body in c
    check "next unchecked task: \"b\"" in c
    # The shared kickoff prefix is what replay matches to the `◎` item;
    # its rendering is covered by the goal kickoff tests.

  test "feedback message orients on the plan and states the duties":
    let body = "# P\n\n- [ ] a\n\n## Current state\n\ns"
    let msg = cyberFeedbackMessage(body, "tests missing")
    check msg{"agentSent"}.getBool(false)
    let c = msg{"content"}.getStr
    check "Verifier feedback:\n\ntests missing" in c
    check "Next unchecked task: \"a\"" in c
    check "## Current state" in c
    check "when this turn ends" in c

  test "counts and display hooks on the descriptor":
    let body = "# Parse plans\n\n- [x] a\n- [ ] b\n\n## Current state\n\ns"
    check cyberneticMode.taskCounts(body) == "2 tasks, 1 done"
    check cyberneticMode.kickoffDisplay(body) ==
      "Parse plans - 2 tasks, 1 done; next: b"
    check goalMode.taskCounts("anything") == ""
    check goalMode.kickoffDisplay("  the goal text  ") == "the goal text"

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
