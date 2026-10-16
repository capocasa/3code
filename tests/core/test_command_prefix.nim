## Command names resolve vim-style: an exact name wins, a shortest
## unambiguous prefix runs the full command, ambiguous or unmatched input
## is an error (did-you-mean survives). A trailing `!` is the force
## marker: `:goal!` replaces a live goal, other commands accept and
## ignore it (`:q!` quits like `:q`).
import std/[json, os, strutils, tempfiles, unittest]
import threecode/[minline, types, ui]
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

  test "bare :goal shows the live goal text":
    withCommandDir:
      discard handleCommandResult(":goal make it so", messages, session,
                                  prof, editor)
      let r = handleCommandResult(":g", messages, session, prof, editor)
      check r.recognized and r.ok
      check "make it so" in r.body

  test "other commands accept and ignore the bang":
    check classifyCommand(":q!") == ckQuit
    check classifyCommand(":sandbox!") == ckSafeImmediate

  test ":! keeps its special-case (no prefix or bang mangling)":
    check classifyCommand(":! echo hi") == ckMutating
    check classifyCommand(":!echo hi") == ckMutating
