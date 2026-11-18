## Command prefixes are configurable (`[settings]
## system-command-prefixes`, default `:`). The boundary this guards:
## under the default, slash-prefixed input — `/help` included — is
## ordinary prompt text (the old hardcoded `/help` synonym is gone,
## subsumed by enabling `/`); every enabled prefix recognizes,
## dispatches and completes identically to `:`, unknown commands keep
## their error, and completion keeps the prefix the user typed.
import std/[json, sequtils, strutils, unittest]
import threecode/[minline, session, types, ui, util]
import minline_testutils

suite "command prefixes: default boundary":
  setup:
    commandPrefixes = ":"
  teardown:
    commandPrefixes = ":"

  var messages = %* []
  var session = Session()
  var prof = Profile()
  var editor: LineEditor

  test "colonForm maps only the configured prefix":
    check colonForm(":help") == ":help"
    check colonForm(" :goal x ") == ":goal x"
    check colonForm("/help") == "/help"
    check colonForm("/goal x") == "/goal x"

  test "/help and /foo stay ordinary input under the default":
    check classifyCommand("/help") == ckUnknown
    check classifyCommand("/foo") == ckUnknown
    check not handleCommandResult("/help", messages, session, prof,
                                  editor).recognized
    check not handleCommandResult("/foo", messages, session, prof,
                                  editor).recognized

  test "other first characters stay ordinary input":
    check not handleCommandResult("!ls", messages, session, prof,
                                  editor).recognized
    check not handleCommandResult("a:foo", messages, session, prof,
                                  editor).recognized

  test "unknown colon command keeps its error":
    let r = handleCommandResult(":foo", messages, session, prof, editor)
    check r.recognized and not r.ok
    check "unknown command" in r.body

suite "command prefixes: enabled prefix parity":
  setup:
    commandPrefixes = ":/"
  teardown:
    commandPrefixes = ":"

  var messages = %* []
  var session = Session()
  var prof = Profile()
  var editor: LineEditor

  test "colonForm canonicalizes any enabled prefix":
    check colonForm("/help") == ":help"
    check colonForm(" /goal x ") == ":goal x"
    check colonForm(":help") == ":help"

  test "each enabled prefix dispatches the same command":
    let slash = handleCommandResult("/help", messages, session, prof, editor)
    let colon = handleCommandResult(":help", messages, session, prof, editor)
    check slash.recognized and slash.ok
    check slash.name == colon.name
    check slash.body == colon.body
    check "commands:" in slash.body

  test "classification parity for verbs, force marker and shell escape":
    check classifyCommand("/g ship it") == ckMutating
    check classifyCommand("/g") == ckSafeImmediate
    check classifyCommand("/q") == ckQuit
    check classifyCommand("/!ls") == ckMutating

  test "unknown command behavior is identical across prefixes":
    let slash = handleCommandResult("/nosuch", messages, session, prof,
                                    editor)
    let colon = handleCommandResult(":nosuch", messages, session, prof,
                                    editor)
    check slash.recognized and not slash.ok
    check colon.recognized and not colon.ok
    check "unknown command" in slash.body

  test "a disabled prefix stays ordinary input":
    check not handleCommandResult("!quit", messages, session, prof,
                                  editor).recognized
    commandPrefixes = ":."
    check classifyCommand("/help") == ckUnknown
    check not handleCommandResult("/quit", messages, session, prof,
                                  editor).recognized
    check handleCommandResult(".help", messages, session, prof,
                              editor).recognized

  test "mid-turn entry gate accepts every enabled prefix":
    check startsWithCommandPrefix(":foo")
    check startsWithCommandPrefix("/foo")
    check not startsWithCommandPrefix(" /foo")
    check not startsWithCommandPrefix("!foo")
    commandPrefixes = ":"
    check not startsWithCommandPrefix("/foo")

  test "quit lines follow the configured prefixes":
    check isQuitLine("quit")
    check isQuitLine(" exit ")
    check isQuitLine(":q")
    check isQuitLine("/quit")
    check isQuitLine(" /q ")
    commandPrefixes = ":"
    check not isQuitLine("/quit")
    check isQuitLine(":quit")

suite "command prefixes: completion":
  setup:
    commandPrefixes = ":/"
  teardown:
    commandPrefixes = ":"

  test "completionFor offers names in the typed prefix":
    let slash = completionFor("/he")
    check "/help" in slash
    check slash.allIt(it[0] == '/')
    let colon = completionFor(":he")
    check ":help" in colon
    check colon.allIt(it[0] == ':')

  test "default keeps slash out of command completion":
    commandPrefixes = ":"
    check completionFor("/he").len == 0
    check ":help" in completionFor(":he")

  test "subcommand slots normalize the command word":
    let verbs = completionFor("/provider ")
    check "add" in verbs
    check "edit" in verbs

  test "empty first word still lists canonical names":
    check ":help" in completionFor("")

  test "tab completion preserves the typed prefix and cursor":
    # Same wiring as the live editor (threecode.nim): the callback sees
    # the whole line. `/he` + Tab must land on `/help ` — the typed
    # prefix kept (not swapped for `:`), the word's bytes replaced as a
    # unit, and the cursor after the shell-style trailing space (unique
    # match, so args can be typed straight away).
    var ed = initEditor()
    ed.completionCallback = proc(ed: LineEditor): seq[string] =
      completionFor(ed.lineText)
    let d = newDriver()
    d.pushString "/he"
    d.push Tab
    d.push Enter
    check d.run(ed, prompt = "> ") == "/help "

  test "tab completion on the colon prefix is unchanged":
    var ed = initEditor()
    ed.completionCallback = proc(ed: LineEditor): seq[string] =
      completionFor(ed.lineText)
    let d = newDriver()
    d.pushString ":he"
    d.push Tab
    d.push Enter
    check d.run(ed, prompt = "> ") == ":help "
