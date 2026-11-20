## Command names resolve vim-style: an exact name wins, a shortest
## unambiguous prefix runs the full command, ambiguous or unmatched input
## is an error (did-you-mean survives). A trailing `!` is the force
## marker: `:goal!` replaces a live goal, other commands accept and
## ignore it (`:q!` quits like `:q`).
import std/[json, os, strutils, tempfiles, unittest]
import threecode/[minline, types, ui]
import threecode/api except callModel
import threecode/fatprompt
import threecode/goal

# `:goal` arms land in the directory settings store; legacy goal.md
# names only apply to sessions armed before the store existed.

proc withCommandDir(body: proc ()) =
  let dir = createTempDir("cmd-prefix-", "")
  defer: removeDir(dir)
  let old = getCurrentDir()
  setCurrentDir(dir)
  defer: setCurrentDir(old)
  body()

suite "command prefix resolution":
  var messages = %* []
  var session = Session()
  var prof = Profile()
  var editor: LineEditor

  template freshConvo() =
    # Goal state lives in the conversation now, so every goal test
    # starts from a fresh one instead of a fresh directory.
    messages = %*[{"role": "system", "content": "s"}]
    session = Session()

  template commitArm(r: CommandResult) =
    # What the controller does after a successful arm: append the
    # kickoff message. The kickoff IS the arm.
    messages.add goalKickoffMessage(r.armText)

  test "canonical names: exact, prefix, ambiguous, unknown":
    check canonicalCommandName(":goal") == (":goal", "")
    check canonicalCommandName(":g") == (":goal", "")
    # `:q` is :quit's own prefix, not a separate alias command.
    check canonicalCommandName(":q") == (":quit", "")
    check canonicalCommandName(":qu") == (":quit", "")
    check canonicalCommandName(":se") == (":se", ":sessions :session")
    check canonicalCommandName(":compact") == (":compact", "")
    check canonicalCommandName(":!ls") == (":!ls", "")

  test "unique prefix classifies and dispatches the full command":
    check classifyCommand(":g ship it") == ckMutating
    check classifyCommand(":g") == ckSafeImmediate
    withCommandDir:
      freshConvo()
      let r = handleCommandResult(":g ship it", messages, session, prof,
                                  editor)
      check r.recognized and r.ok
      check r.name == "goal"
      commitArm(r)
      check goalTextFromMessages(messages) == "ship it"

  test "ambiguous prefix is an error naming the candidates":
    check classifyCommand(":se") == ckUnknown
    let r = handleCommandResult(":se", messages, session, prof, editor)
    check r.recognized and not r.ok
    check "ambiguous" in r.body
    check ":session" in r.body and ":sessions" in r.body

  test "unknown input keeps the did-you-mean suggestion":
    let r = handleCommandResult(":goalx", messages, session, prof, editor)
    check r.recognized and not r.ok
    check "did you mean :goal?" in r.body

  test "bang forces :goal over a live goal":
    freshConvo()
    commitArm handleCommandResult(":g first", messages, session, prof,
                                  editor)
    let refuse = handleCommandResult(":g second", messages, session,
                                     prof, editor)
    check refuse.recognized and not refuse.ok
    check ":goal!" in refuse.body
    let replace = handleCommandResult(":goal! second", messages, session,
                                      prof, editor)
    check replace.recognized and replace.ok
    commitArm(replace)
    check goalTextFromMessages(messages) == "second"

  test "bare :goal! cancels the live goal":
    freshConvo()
    commitArm handleCommandResult(":g doomed", messages, session, prof,
                                  editor)
    check classifyCommand(":g!") == ckMutating
    let r = handleCommandResult(":g!", messages, session, prof, editor)
    check r.recognized and r.ok
    check "goal cancelled" in r.body
    check not goalActiveIn(messages, session.goalSteps)
    let none = handleCommandResult(":g!", messages, session, prof, editor)
    check none.recognized and not none.ok
    check "no goal active" in none.body

  test "a pasted multi-line :goal arms the whole text":
    freshConvo()
    # The empty rest of the first line after `:goal` (a newline, not a
    # space) must not leak into the command name: the verb is `:goal`
    # and every following line is the goal text.
    let cmd = ":goal\n\ngoal description\non several alines"
    check classifyCommand(cmd) == ckMutating
    let r = handleCommandResult(cmd, messages, session, prof, editor)
    check r.recognized and r.ok
    check r.name == "goal"
    check r.body == ""
    check r.armText == "goal description\non several alines"
    commitArm(r)
    check goalTextFromMessages(messages) ==
      "goal description\non several alines"

  test "bare :goal shows the live goal text":
    freshConvo()
    commitArm handleCommandResult(":goal make it so", messages, session,
                                  prof, editor)
    let r = handleCommandResult(":g", messages, session, prof, editor)
    check r.recognized and r.ok
    check "make it so" in r.body

  test "other commands accept and ignore the bang":
    check classifyCommand(":q!") == ckQuit
    check classifyCommand(":q") == ckQuit
    check classifyCommand(":sandbox!") == ckSafeImmediate

  test ":! keeps its special-case (no prefix or bang mangling)":
    check classifyCommand(":! echo hi") == ckMutating
    check classifyCommand(":!echo hi") == ckMutating

suite "goal command verbs":
  var messages = %* []
  var session = Session()
  var prof = Profile()
  var editor: LineEditor

  template freshConvo() =
    # Goal state lives in the conversation, so every goal test starts
    # from a fresh one instead of a fresh directory.
    messages = %*[{"role": "system", "content": "s"}]
    session = Session()

  template commitArm(r: CommandResult) =
    # What the controller does after a successful arm: append the
    # kickoff message. The kickoff IS the arm.
    messages.add goalKickoffMessage(r.armText)

  test "modeArmWrite classifies the arm-shaped writes":
    check modeArmWrite(":goal make it so")
    check modeArmWrite(":g new other text")
    check modeArmWrite(":goal! replacement text")
    check modeArmWrite(":cyber ship the plan")
    check not modeArmWrite(":goal cancel")
    check not modeArmWrite(":goal!")
    check not modeArmWrite(":goal edit")
    check not modeArmWrite(":tokens")
    check not modeArmWrite("plain text")

  test ":cyber follows the build flag":
    withCommandDir:
      let r = handleCommandResult(":cyber ship the plan", messages, session,
                                  prof, editor)
      check r.recognized
      when cyberneticBuild:
        check r.ok and r.startGoalTurn
        check readFile(".3code" / "cybernetic").startsWith("# ship the plan")
      else:
        check not r.ok
        check "not compiled into this build" in r.body
        check not fileExists(".3code" / "cybernetic")

  test ":goal TEXT arms silently; the kickoff item is the announcement":
    freshConvo()
    let r = handleCommandResult(":goal make it so", messages, session,
                                prof, editor)
    check r.recognized and r.ok
    # An arm answers with no body: the controller commits the ⚑ kickoff
    # item (flag plus goal text alone) as the whole announcement, and a
    # receipt or echoed command would only repeat the goal text.
    check r.body == ""
    check r.startGoalTurn
    check r.armText == "make it so"
    commitArm(r)
    check goalActiveIn(messages, session.goalSteps)

  test ":goal new is the balking synonym":
    freshConvo()
    commitArm handleCommandResult(":goal new first goal", messages, session,
                                  prof, editor)
    let balk = handleCommandResult(":goal new second goal", messages,
                                   session, prof, editor)
    check balk.recognized and not balk.ok
    check ":goal!" in balk.body
    check goalTextFromMessages(messages) == "first goal"
    let usage = handleCommandResult(":goal new", messages, session, prof,
                                    editor)
    check usage.recognized and not usage.ok
    check "usage" in usage.body

  test ":goal cancel retires like bare :goal!":
    freshConvo()
    commitArm handleCommandResult(":goal doomed", messages, session, prof,
                                  editor)
    check classifyCommand(":goal cancel") == ckMutating
    let r = handleCommandResult(":goal cancel", messages, session, prof,
                                editor)
    check r.recognized and r.ok
    check "goal cancelled" in r.body
    check not goalActiveIn(messages, session.goalSteps)
    let none = handleCommandResult(":goal cancel", messages, session, prof,
                                   editor)
    check none.recognized and not none.ok
    check "no goal active" in none.body

  when defined(posix):
    test ":goal edit without a live goal edits the scratch copy":
      freshConvo()
      let src = getTempDir() / "goal_edit_new.txt"
      writeFile(src, "fresh goal\n")
      putEnv("EDITOR", "cp " & src)
      defer: delEnv("EDITOR")
      let r = handleCommandResult(":goal edit", messages, session, prof,
                                  editor)
      check r.recognized and r.ok
      check r.body == ""
      check r.armText.strip == "fresh goal"
      commitArm(r)
      check goalTextFromMessages(messages) == "fresh goal"

    test ":goal edit creating nothing arms nothing":
      freshConvo()
      putEnv("EDITOR", "true")
      defer: delEnv("EDITOR")
      let r = handleCommandResult(":goal edit", messages, session, prof,
                                  editor)
      check r.recognized and r.ok
      check "not armed" in r.body
      check not goalActiveIn(messages, session.goalSteps)

    test ":goal edit rewrites the live goal in $EDITOR":
      freshConvo()
      commitArm handleCommandResult(":goal original text", messages, session,
                                    prof, editor)
      # `cp <src>` + appended target = `cp <src> <scratch copy>`.
      let src = getTempDir() / "goal_edit_src.txt"
      writeFile(src, "edited text\n")
      putEnv("EDITOR", "cp " & src)
      defer: delEnv("EDITOR")
      let r = handleCommandResult(":goal edit", messages, session, prof,
                                  editor)
      check r.recognized and r.ok
      check r.body == ""
      commitArm(r)
      check goalTextFromMessages(messages) == "edited text"

    test ":goal edit with an emptied scratch cancels the goal":
      freshConvo()
      commitArm handleCommandResult(":goal original text", messages, session,
                                    prof, editor)
      let src = getTempDir() / "goal_edit_empty.txt"
      writeFile(src, "\n")
      putEnv("EDITOR", "cp " & src)
      defer: delEnv("EDITOR")
      let r = handleCommandResult(":goal edit", messages, session, prof,
                                  editor)
      check r.recognized and r.ok
      check "goal cleared" in r.body
      check not goalActiveIn(messages, session.goalSteps)

    test ":goal edit with unchanged text does not re-kick":
      freshConvo()
      commitArm handleCommandResult(":goal stable text", messages, session,
                                    prof, editor)
      let src = getTempDir() / "goal_edit_same.txt"
      writeFile(src, "stable text\n")
      putEnv("EDITOR", "cp " & src)
      defer: delEnv("EDITOR")
      let r = handleCommandResult(":goal edit", messages, session, prof,
                                  editor)
      check r.recognized and r.ok
      check "unchanged" in r.body
      check goalTextFromMessages(messages) == "stable text"

suite ":retry command":
  var messages = %* []
  var session = Session()
  var prof = Profile()
  var editor: LineEditor

  test "bare :retry queues an empty submit, no hint line":
    check classifyCommand(":retry") == ckSafeImmediate
    let r = handleCommandResult(":retry", messages, session, prof, editor)
    check r.recognized and r.ok
    check r.body == ""
    # The payload is the empty-submit event Enter on an empty buffer
    # queues; the controller drains it into a turn on the current state.
    check hasQueuedAutosend()
    let ev = pollInputEvent()
    check ev.kind == ieLine
    check ev.text == ""
    check pollInputEvent().kind == ieNone

  test ":retry list still shows the patient-retry setting":
    let r = handleCommandResult(":retry list", messages, session, prof,
                                editor)
    check r.recognized and r.ok
    check "patient retry" in r.body
    check pollInputEvent().kind == ieNone
