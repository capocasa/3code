## `/help` is hardcoded as a synonym for `:help` for new users: the slash
## form classifies and dispatches like the colon form (args ignored, same as
## `:help`), while lookalike text stays a model prompt.
import std/[json, strutils, unittest]
import threecode/[minline, types, ui, util]

suite "/help synonym":
  var messages = %* []
  var session = Session()
  var prof = Profile()
  var editor: LineEditor

  test "classification accepts the slash form":
    check classifyCommand("/help") == ckSafeImmediate
    check classifyCommand(" /help ") == ckSafeImmediate
    check classifyCommand("/help extras ignored") == ckSafeImmediate

  test "dispatch renders the same help body as :help":
    let slash = handleCommandResult("/help", messages, session, prof, editor)
    let colon = handleCommandResult(":help", messages, session, prof, editor)
    check slash.recognized and slash.ok
    check slash.name == "help"
    check slash.body == colon.body
    check "commands:" in slash.body

  test "lookalikes are not commands":
    check classifyCommand("/helpful, please") == ckUnknown
    check classifyCommand("/Help") == ckUnknown
    check colonForm("/helpful, please") == "/helpful, please"
    check not handleCommandResult("/helpful, please", messages, session,
                                  prof, editor).recognized

  test "colonForm maps only the exact token":
    check colonForm("/help") == ":help"
    check colonForm("/help now") == ":help now"
    check colonForm(":help") == ":help"
    check colonForm("/helpp") == "/helpp"
