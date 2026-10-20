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
    feedbackMessage: proc (fb: string): JsonNode = newJNull())

proc withSynthMode(body: proc ()) =
  ## Register a second mode for the duration of one test; the registry
  ## is process-global, so it comes back off afterwards.
  modeRegistry.add synthMode()
  defer: discard modeRegistry.pop()
  body()

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
