## The mode-verb grammar (`:goal`/`:cyber` shared dispatch, modeVerbResult)
## driven headlessly: every branch of the verb with a live and absent
## mode file, including the $VISUAL/$EDITOR edit path via a real editor
## script. The interactive kickoff/marker/receipt surfaces live in the
## tty suites; this file owns the verb's decision table.

import std/[os, strutils, tempfiles, unittest]
import threecode/goal
import threecode/ui

proc withModeDir(body: proc (dir: string)) =
  let dir = createTempDir("modeverb-test-", "")
  defer: removeDir(dir)
  let old = getCurrentDir()
  setCurrentDir(dir)
  defer: setCurrentDir(old)
  body(dir)

proc verb(m: ModeDesc; arg: string; forced = false): auto =
  let parts = if arg.strip.len == 0: @[] else: arg.splitWhitespace()
  modeVerbResult(m, parts, arg, forced)

proc shScript(body: string): string =
  result = getCurrentDir() / "editor-" & $getCurrentProcessId() & ".sh"
  writeFile(result, "#!/bin/sh\n" & body)
  let perms: set[FilePermission] = {fpUserRead, fpUserWrite, fpUserExec}
  setFilePermissions(result, perms)

template editorMk(body: string): void =
  putEnv("VISUAL", shScript(body))
  defer: delEnv("VISUAL")

suite "mode verb (:goal grammar, both modes)":
  test "bare verb shows the live mode file or teaches how to arm":
    withModeDir proc (dir: string) =
      check verb(goalMode, "") == (false,
        "no goal active; arm one with :goal <text>", false)
      check verb(cyberneticMode, "") == (false,
        "no cybernetic active; arm one with :cyber <text>", false)
      discard startGoal("the goal text")
      check verb(goalMode, "") == (true, "the goal text", false)
      check cancelGoal().ok
      discard startMode(cyberneticMode, "the plan")
      check verb(cyberneticMode, "") == (true,
        "# the plan\n\n- [ ] the plan\n\n## Current state\n\nNot begun.",
        false)

  test "cancel retires through the descriptor; extra words are usage errors":
    withModeDir proc (dir: string) =
      check verb(goalMode, "cancel now") == (false,
        ":goal cancel takes no argument (cancel retires the whole goal.md)",
        false)
      discard startMode(cyberneticMode, "the plan")
      check verb(cyberneticMode, "cancel") == (true,
        "cybernetic cancelled (cybernetic.md renamed to " &
          CyberCancelledName & ")", false)
      check fileExists(CyberCancelledName)
      check verb(goalMode, "", forced = true) == (false,
        "no goal active", false)

  test "new TEXT balks at a live mode; bare TEXT is the same arm":
    withModeDir proc (dir: string) =
      check verb(cyberneticMode, "new") == (false,
        "usage: :cyber new <text>", false)
      # A successful arm answers with no line: the command echo already
      # says it and the kickoff turn follows at once.
      check verb(cyberneticMode, "new first plan") == (true, "", true)
      check verb(cyberneticMode, "new second plan") == (false,
        "cybernetic.md is already active; use :cyber! to replace it",
        false)
      check verb(cyberneticMode, "new third plan", forced = true) ==
        (true, "", true)
      # One mode at a time: with cybernetic live the goal arm refuses,
      # and after cancelling it the plain-text goal arm goes through —
      # and then it is :cyber's turn to balk.
      check verb(goalMode, "plain text arm") == (false,
        "cybernetic.md (cybernetic mode) is already active; harness " &
        "modes are mutually exclusive - cancel it first with :cyber!",
        false)
      check verb(cyberneticMode, "cancel").ok
      check verb(goalMode, "plain text arm") == (true, "", true)
      check verb(cyberneticMode, "mine") == (false,
        "goal.md (goal mode) is already active; harness modes are " &
        "mutually exclusive - cancel it first with :goal!", false)

  test "edit re-arms on change, reports unchanged, and validates structure":
    withModeDir proc (dir: string) =
      discard startMode(cyberneticMode, "the plan")
      editorMk("""printf '%s\n' '- [x] did it' >> $1""")
      let r = verb(cyberneticMode, "edit")
      check r == (true, "", true)
      check "- [x] did it" in readFile(CyberFileName)
      # An editor that changes nothing leaves the mode un-kicked.
      editorMk("true")
      check verb(cyberneticMode, "edit") == (true,
        "cybernetic.md unchanged", false)
      # An editor that destroys the format contract refuses the re-arm
      # with the teaching error; the file keeps the broken edit and the
      # structure-loss guard at the next boundary owns the recovery.
      editorMk("""printf '%s\n' '# all structure gone' > $1""")
      let broken = verb(cyberneticMode, "edit")
      check not broken.ok
      check broken.line.startsWith(
        "a cybernetic plan needs at least one task item")
      check not broken.armed

  test "edit with no mode file creates it (arm or clean no-op)":
    withModeDir proc (dir: string) =
      # An editor that writes nothing leaves no trace: no arm, no stray
      # empty file, no cancelled-record rename for a mode never armed.
      editorMk("true")
      check verb(goalMode, "edit") == (true,
        "goal not armed (nothing written to goal.md)", false)
      check not fileExists(GoalFileName)
      check not fileExists(GoalCancelledName)
      # An editor that removes the created file is the same no-op.
      editorMk("""rm $1""")
      check verb(goalMode, "edit") == (true,
        "goal not armed (nothing written to goal.md)", false)
      check not fileExists(GoalFileName)
      # A writing editor arms straight from the created file.
      editorMk("""printf '%s\n' 'from scratch' > $1""")
      check verb(goalMode, "edit") == (true, "", true)
      check readFile(GoalFileName).strip == "from scratch"
      check cancelGoal().ok
      # The created-file write is still an arm: a live OTHER mode
      # refuses it before the editor ever runs.
      discard startMode(cyberneticMode, "the plan")
      editorMk("""printf '%s\n' 'nope' > $1""")
      check verb(goalMode, "edit") == (false,
        "cybernetic.md (cybernetic mode) is already active; harness " &
          "modes are mutually exclusive - cancel it first with :cyber!",
        false)
      check not fileExists(GoalFileName)

  test "edit removing the file cancels; emptying it clears":
    withModeDir proc (dir: string) =
      discard startMode(cyberneticMode, "the plan")
      editorMk("""rm $1""")
      check verb(cyberneticMode, "edit") == (true,
        "cybernetic cancelled (cybernetic.md removed in the editor)", false)
      check not fileExists(CyberFileName)
      discard startMode(cyberneticMode, "again")
      editorMk(""": > $1""")
      check verb(cyberneticMode, "edit") == (true,
        "cybernetic cleared (cybernetic.md renamed to " &
          CyberCancelledName & ")", false)
