## Command names resolve vim-style: an exact name wins, a shortest
## unambiguous prefix runs the full command, ambiguous or unmatched input
## is an error (did-you-mean survives). A trailing `!` is the force
## marker: `:goal!` replaces a live goal, other commands accept and
## ignore it (`:q!` quits like `:q`).
import std/[json, os, strutils, tempfiles, unittest]
import threecode/[minline, types, ui]
import threecode/api except callModel
import threecode/goal

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
      let r = handleCommandResult(":g ship it", messages, session, prof,
                                  editor)
      check r.recognized and r.ok
      check r.name == "goal"
      check readFile(GoalFileName).strip == "ship it"

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
    withCommandDir:
      discard handleCommandResult(":g first", messages, session, prof,
                                  editor)
      let refuse = handleCommandResult(":g second", messages, session,
                                       prof, editor)
      check refuse.recognized and not refuse.ok
      check ":goal!" in refuse.body
      let replace = handleCommandResult(":goal! second", messages, session,
                                        prof, editor)
      check replace.recognized and replace.ok
      check readFile(GoalFileName).strip == "second"

  test "bare :goal! cancels the live goal":
    withCommandDir:
      discard handleCommandResult(":g doomed", messages, session, prof,
                                  editor)
      check classifyCommand(":g!") == ckMutating
      let r = handleCommandResult(":g!", messages, session, prof, editor)
      check r.recognized and r.ok
      check GoalCancelledName in r.body
      check not fileExists(GoalFileName)
      check readFile(GoalCancelledName).strip == "doomed"
      let none = handleCommandResult(":g!", messages, session, prof, editor)
      check none.recognized and not none.ok
      check "no goal active" in none.body

  test "bare :goal shows the live goal text":
    withCommandDir:
      discard handleCommandResult(":goal make it so", messages, session,
                                  prof, editor)
      let r = handleCommandResult(":g", messages, session, prof, editor)
      check r.recognized and r.ok
      check "make it so" in r.body
      check not r.startGoalTurn

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

  test ":goal TEXT arms quietly and flags the immediate kickoff":
    withCommandDir:
      let r = handleCommandResult(":goal make it so", messages, session,
                                  prof, editor)
      check r.recognized and r.ok
      check r.startGoalTurn
      # No response body: the `:goal make it so` echo already says it.
      check r.body == ""
      check readFile(GoalFileName).strip == "make it so"

  test ":goal new is the balking synonym":
    withCommandDir:
      let r = handleCommandResult(":goal new first goal", messages, session,
                                  prof, editor)
      check r.recognized and r.ok
      check r.startGoalTurn
      check readFile(GoalFileName).strip == "first goal"
      let balk = handleCommandResult(":goal new second goal", messages,
                                     session, prof, editor)
      check balk.recognized and not balk.ok
      check not balk.startGoalTurn
      check ":goal!" in balk.body
      check readFile(GoalFileName).strip == "first goal"
      let usage = handleCommandResult(":goal new", messages, session, prof,
                                      editor)
      check usage.recognized and not usage.ok
      check "usage" in usage.body

  test ":goal cancel retires like bare :goal!":
    withCommandDir:
      discard handleCommandResult(":goal doomed", messages, session, prof,
                                  editor)
      check classifyCommand(":goal cancel") == ckMutating
      let r = handleCommandResult(":goal cancel", messages, session, prof,
                                  editor)
      check r.recognized and r.ok
      check not r.startGoalTurn
      check GoalCancelledName in r.body
      check readFile(GoalCancelledName).strip == "doomed"
      let none = handleCommandResult(":goal cancel", messages, session, prof,
                                      editor)
      check none.recognized and not none.ok
      check "no goal active" in none.body

  test ":goal edit without a live goal is an error":
    withCommandDir:
      let r = handleCommandResult(":goal edit", messages, session, prof,
                                  editor)
      check r.recognized and not r.ok
      check "no goal active" in r.body

  when defined(posix):
    test ":goal edit rewrites the live goal in $EDITOR":
      withCommandDir:
        discard handleCommandResult(":goal original text", messages, session,
                                    prof, editor)
        # `cp <src>` + appended target = `cp <src> goal.md`.
        let src = getTempDir() / "goal_edit_src.txt"
        writeFile(src, "edited text\n")
        putEnv("EDITOR", "cp " & src)
        defer: delEnv("EDITOR")
        let r = handleCommandResult(":goal edit", messages, session, prof,
                                    editor)
        check r.recognized and r.ok
        check r.startGoalTurn
        check r.body == ""
        check readFile(GoalFileName).strip == "edited text"

    test ":goal edit with an emptied file cancels the goal":
      withCommandDir:
        discard handleCommandResult(":goal original text", messages, session,
                                    prof, editor)
        let src = getTempDir() / "goal_edit_empty.txt"
        writeFile(src, "\n")
        putEnv("EDITOR", "cp " & src)
        defer: delEnv("EDITOR")
        let r = handleCommandResult(":goal edit", messages, session, prof,
                                    editor)
        check r.recognized and r.ok
        check not r.startGoalTurn
        check GoalCancelledName in r.body
        check not fileExists(GoalFileName)

    test ":goal edit with unchanged text does not re-kick":
      withCommandDir:
        discard handleCommandResult(":goal stable text", messages, session,
                                    prof, editor)
        let src = getTempDir() / "goal_edit_same.txt"
        writeFile(src, "stable text\n")
        putEnv("EDITOR", "cp " & src)
        defer: delEnv("EDITOR")
        let r = handleCommandResult(":goal edit", messages, session, prof,
                                    editor)
        check r.recognized and r.ok
        check not r.startGoalTurn
        check "unchanged" in r.body
        check readFile(GoalFileName).strip == "stable text"

suite ":retry command":
  var messages = %* []
  var session = Session()
  var prof = Profile()
  var editor: LineEditor

  test "bare :retry is the ctrl-r command form":
    clearRetryNow()
    check classifyCommand(":retry") == ckSafeImmediate
    let r = handleCommandResult(":retry", messages, session, prof, editor)
    check r.recognized and r.ok
    check "ctrl-r" in r.body
    check isRetryNow()
    clearRetryNow()

  test ":retry list still shows the patient-retry setting":
    clearRetryNow()
    let r = handleCommandResult(":retry list", messages, session, prof,
                                editor)
    check r.recognized and r.ok
    check "patient retry" in r.body
    check not isRetryNow()
