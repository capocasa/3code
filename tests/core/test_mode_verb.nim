## The mode-verb grammar (`:goal`/`:cyber` shared dispatch, modeVerbResult)
## driven headlessly: every branch of the verb with a live and absent
## mode, including the $VISUAL/$EDITOR edit path via a real editor
## script. goal mode's state is the conversation (a kickoff message
## arms it); cybernetic's is its file. The interactive
## kickoff/marker/receipt surfaces live in the tty suites; this file
## owns the verb's decision table.

import std/[json, os, strutils, tempfiles, unittest]
import threecode/goal
import threecode/types except Usage
import threecode/ui

proc withModeDir(body: proc (dir: string)) =
  let dir = createTempDir("modeverb-test-", "")
  defer: removeDir(dir)
  let old = getCurrentDir()
  setCurrentDir(dir)
  defer: setCurrentDir(old)
  body(dir)

var scratchSession: Session
  ## Shared sink for verb calls that do not care about the session
  ## state they mutate (the arm paths validate; only cancel/edit write).

proc verb(m: ModeDesc; arg: string; forced = false;
          messages: JsonNode = newJArray();
          session: var Session = scratchSession): auto =
  let parts = if arg.strip.len == 0: @[] else: arg.splitWhitespace()
  modeVerbResult(m, parts, arg, forced, session, messages)

proc armedConvo(text: string): JsonNode =
  ## A conversation with one live goal, as the controller leaves it
  ## after a `:goal` arm (the kickoff appended).
  %*[{"role": "system", "content": "s"}, goalKickoffMessage(text)]

proc shScript(body: string): string =
  result = getCurrentDir() / "editor-" & $getCurrentProcessId() & ".sh"
  writeFile(result, "#!/bin/sh\n" & body)
  let perms: set[FilePermission] = {fpUserRead, fpUserWrite, fpUserExec}
  setFilePermissions(result, perms)

template editorMk(body: string): void =
  putEnv("VISUAL", shScript(body))
  defer: delEnv("VISUAL")

suite "mode verb (:goal grammar, both modes)":
  test "bare verb shows the live goal or teaches how to arm":
    check verb(goalMode, "") == (false,
      "no goal active; arm one with :goal <text>", false, "")
    when cyberneticBuild:
      check verb(cyberneticMode, "") == (false,
        "no cybernetic active; arm one with :cyber <text>", false, "")
    check verb(goalMode, "", messages = armedConvo("the goal text")) ==
      (true, "the goal text", false, "")
    var session: Session
    check retireGoalCancelled(session, armedConvo("the goal text"))
    check verb(goalMode, "") == (false,
      "no goal active; arm one with :goal <text>", false, "")
    when cyberneticBuild:
      discard startMode(cyberneticMode, "the plan")
      check verb(cyberneticMode, "") == (true,
        "# the plan\n\n- [ ] the plan\n\n## Current state\n\nNot begun.",
        false, "")

  test "cancel retires; extra words are usage errors":
    check verb(goalMode, "cancel now") == (false,
      ":goal cancel takes no argument (cancel retires the whole goal)",
      false, "")
    var session: Session
    let live = armedConvo("doomed")
    check verb(goalMode, "cancel", messages = live, session = session) ==
      (true, "goal cancelled", false, "")
    check not goalActiveIn(live, session.goalSteps)
    when cyberneticBuild:
      discard startMode(cyberneticMode, "the plan")
      check verb(cyberneticMode, "cancel") == (true,
        "cybernetic cancelled (.3code/cybernetic renamed to " &
          "cybernetic-cancelled)", false, "")
      check fileExists(".3code" / "cybernetic-cancelled")
    check verb(goalMode, "", forced = true) == (false,
      "no goal active", false, "")

  when cyberneticBuild:
    test "new TEXT balks at a live mode; bare TEXT is the same arm":
      withModeDir proc (dir: string) =
        check verb(cyberneticMode, "new") == (false,
          "usage: :cyber new <text>", false, "")
        # A successful arm answers with no line of the verb's own: the
        # controller's arm receipt is the announcement.
        check verb(cyberneticMode, "new first plan") == (true, "", true, "")
        check verb(cyberneticMode, "new second plan") == (false,
          ".3code/cybernetic is already active; use :cyber! to replace it",
          false, "")
        check verb(cyberneticMode, "new third plan", forced = true) ==
          (true, "", true, "")
        # One mode at a time: with cybernetic live the goal arm refuses,
        # and after cancelling it the plain-text goal arm goes through
        # (the arm text rides out for the kickoff) - and then it is
        # :cyber's turn to balk.
        var session: Session
        var convo = newJArray()
        check verb(goalMode, "plain text arm", messages = convo,
                   session = session) == (false,
          ".3code/cybernetic (cybernetic mode) is already active; harness " &
          "modes are mutually exclusive - cancel it first with :cyber!",
          false, "")
        check verb(cyberneticMode, "cancel").ok
        check verb(goalMode, "plain text arm", messages = convo,
                   session = session) == (true, "", true,
                                         "plain text arm")
        convo.add goalKickoffMessage("plain text arm")
        check verb(cyberneticMode, "mine", messages = convo,
                   session = session) == (false,
          "goal mode is already active; harness modes are " &
          "mutually exclusive - cancel it first with :goal!", false, "")

  when cyberneticBuild:
    test "edit re-arms on change, reports unchanged, and validates structure":
      withModeDir proc (dir: string) =
        discard startMode(cyberneticMode, "the plan")
        editorMk("""printf '%s\n' '- [x] did it' >> $1""")
        let r = verb(cyberneticMode, "edit")
        check r == (true, "", true, "")
        check "- [x] did it" in readFile(".3code" / "cybernetic")
        # An editor that changes nothing leaves the mode un-kicked.
        editorMk("true")
        check verb(cyberneticMode, "edit") == (true,
          ".3code/cybernetic unchanged", false, "")
        # An editor that destroys the format contract refuses the re-arm
        # with the teaching error; the file keeps the broken edit and the
        # structure-loss guard at the next boundary owns the recovery.
        editorMk("""printf '%s\n' '# all structure gone' > $1""")
        let broken = verb(cyberneticMode, "edit")
        check not broken.ok
        check broken.line.startsWith(
          "a cybernetic plan needs at least one task item")
        check not broken.armed

  test "edit round-trips the goal text through a scratch file":
    # An editor that writes nothing leaves no trace: no arm, no
    # retirement record for a goal never armed.
    editorMk("true")
    check verb(goalMode, "edit") == (true,
      "goal not armed (nothing written)", false, "")
    # An editor that removes the scratch file is the same no-op.
    editorMk("""rm $1""")
    check verb(goalMode, "edit") == (true,
      "goal not armed (nothing written)", false, "")
    # A writing editor arms straight from the edited text.
    editorMk("""printf '%s\n' 'from scratch' > $1""")
    check verb(goalMode, "edit") == (true, "", true, "from scratch\n")
    # With a live goal: an unchanged text is a no-op, an emptied one
    # retires, a changed one re-arms.
    let live = armedConvo("the live goal")
    editorMk("""printf '%s' 'the live goal' > $1""")
    check verb(goalMode, "edit", messages = live) == (true,
      "goal unchanged", false, "")
    editorMk(": > $1")
    var session: Session
    check verb(goalMode, "edit", messages = live, session = session) ==
      (true, "goal cleared", false, "")
    check not goalActiveIn(live, session.goalSteps)
    editorMk("""printf '%s\n' 'a better goal' > $1""")
    check verb(goalMode, "edit", messages = live, session = session) ==
      (true, "", true, "a better goal\n")
    when cyberneticBuild:
      # The scratch write is still an arm: a live OTHER mode refuses it
      # before the editor ever runs.
      withModeDir proc (dir: string) =
        discard startMode(cyberneticMode, "the plan")
        editorMk("""printf '%s\n' 'nope' > $1""")
        check verb(goalMode, "edit") == (false,
          "cybernetic mode is already active; harness " &
            "modes are mutually exclusive - cancel it first with :cyber!",
          false, "")

  when cyberneticBuild:
    test "edit removing the file cancels; emptying it clears":
      withModeDir proc (dir: string) =
        discard startMode(cyberneticMode, "the plan")
        editorMk("""rm $1""")
        check verb(cyberneticMode, "edit") == (true,
          "cybernetic cancelled (.3code/cybernetic removed in the editor)",
          false, "")
        check not fileExists(CyberFileName)
        check not fileExists(".3code" / "cybernetic")
        discard startMode(cyberneticMode, "again")
        editorMk(""": > $1""")
        check verb(cyberneticMode, "edit") == (true,
          "cybernetic cleared (.3code/cybernetic renamed to " &
            "cybernetic-cancelled)", false, "")
