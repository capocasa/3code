discard """
  targets: "c"
  matrix: ""
"""
## Plugin host testament: builds the fixture .so (the SDK include
## pattern), loads it through the real discovery path with
## XDG_DATA_HOME redirected, and drives every hook class — mutation
## chaining, veto/rewrite/takeover/wrap verdicts, registered tool
## execution, async events, the trace channel, ABI-version refusal, and
## timeout demotion. No network, no terminal.

import std/[json, os, sequtils, strutils, times, unittest]
import ../plugin_helpers
import threecode/[plugins, pluginabi]

var
  root: string
  logPath: string
  dbgPath: string
  built = false

proc logLines(): seq[string] = pluginLogLines(logPath)
proc resetLog() = pluginResetLog(logPath)

suite "plugin host":
  setup:
    if not built:
      root = getTempDir() / "3code_plugin_test_" & $getCurrentProcessId()
      logPath = root / "fixture.log"
      dbgPath = root / "debug.log"
      resetLog()
      buildPluginFixtures(root / "share")
      putEnv("XDG_DATA_HOME", root / "share")
      putEnv("TC_FIXTURE_LOG", logPath)
      putEnv("THREECODE_DEBUG_LOG", dbgPath)
      putEnv("THREECODE_PLUGIN_SYNC_MS", "3000")
      pluginsToolsEnabled = true
      pluginTraceOn = true
      pluginsDiscoverAndLoad()
      built = true

  test "loads good lib, refuses wrong ABI, notes both":
    check pluginsLoadedCount() == 1
    let body = pluginsListBody()
    check "plugin_fixture" in body
    check "plugin_badabi" in body
    check "abi version 4242" in body
    check "on_prompt" in body  # hook list rendered

  test "init and register ran on the plugin thread":
    let lines = logLines()
    check "init" in lines.mapIt(it.split('|')[0])
    check "register" in lines.mapIt(it.split('|')[0])

  test "prompt hook mutates":
    resetLog()
    var text = "hello"
    pluginOnPrompt(text, "/tmp/s.3log", "zai", "glm-5")
    check text == "hello [fixture]"

  test "system prompt hook memoized per profile":
    resetLog()
    let a = pluginSystemPrompt("base prompt", "zai", "glm-5", "glm")
    check "(fixture system line)" in a
    let b = pluginSystemPrompt("base prompt", "zai", "glm-5", "glm")
    check a == b
    # second call is a cache hit: exactly one hook fire recorded
    var fires = 0
    for l in logLines():
      if l.startsWith("sysprompt|"): inc fires
    check fires == 1
    # different profile key: fires again
    discard pluginSystemPrompt("base prompt", "nebius", "glm-5", "glm")
    var fires2 = 0
    for l in logLines():
      if l.startsWith("sysprompt|"): inc fires2
    check fires2 == 2

  test "tool pre default allow":
    var args = """{"path": "src/a.nim", "body": "x"}"""
    let r = pluginOnToolPre("write", args, "call1", "glm")
    check r.kind == tpkAllow
    check args == """{"path": "src/a.nim", "body": "x"}"""

  test "tool pre rewrite chains args back":
    putEnv("TC_FIXTURE_MODE", "rewrite")
    defer: putEnv("TC_FIXTURE_MODE", "mutate")
    var args = """{"path": "src/a.nim", "body": "x"}"""
    let r = pluginOnToolPre("write", args, "call2", "glm")
    check r.kind == tpkRewrite
    check "src/b.nim" in args
    check r.args == args

  test "tool pre veto short-circuits with note":
    putEnv("TC_FIXTURE_MODE", "veto")
    defer: putEnv("TC_FIXTURE_MODE", "mutate")
    var args = """{"path": "db.sqlite", "body": "x"}"""
    let r = pluginOnToolPre("write", args, "call3", "glm")
    check r.kind == tpkVeto
    check "fixture: writes are frozen" in r.note

  test "tool pre takeover returns plugin result":
    putEnv("TC_FIXTURE_MODE", "takeover")
    defer: putEnv("TC_FIXTURE_MODE", "mutate")
    var args = "ls"
    let r = pluginOnToolPre("bash", args, "call4", "glm")
    check r.kind == tpkTakeover
    check r.note == "fixture: took over this call"
    check r.code == 0

  test "tool pre wrap sandwiches the original":
    putEnv("TC_FIXTURE_MODE", "wrap")
    defer: putEnv("TC_FIXTURE_MODE", "mutate")
    var args = "ls"
    let r = pluginOnToolPre("bash", args, "call5", "glm")
    check r.kind == tpkWrap
    check r.note == "before-line"
    check r.post == "after-line"

  test "tool result hook redacts":
    var output = "the SECRET key is here"
    var code = 0
    pluginOnToolResult("bash", "env", output, code, 12, "")
    check output == "the [redacted] key is here"

  test "cli registration: commands and options, builtins refused":
    check pluginCliHasCommand("fixturecmd")
    check not pluginCliHasCommand("provider")
    let cmds = pluginCliCommands()
    check cmds.len == 1
    check cmds[0].name == "fixturecmd"
    check cmds[0].help == "fixture plugin subcommand"
    let opts = pluginCliOptions()
    check opts.len == 2  # provider/model/evil-opt/duplicate all refused
    check pluginCliFindOption("fixture-opt", '\0') >= 0
    check pluginCliFindOption("", 'Q') >= 0
    check pluginCliFindOption("fixture-flag", '\0') >= 0
    check pluginCliFindOption("model", '\0') == -1
    check pluginCliFindOption("", 'm') == -1
    check pluginCliValueShorts() == {'Q'}  # W is a flag, no value

  test "cli subcommand dispatch returns output and code":
    resetLog()
    let (outp, code) = pluginCliRunCommand("fixturecmd",
                                           @["hello", "two words"])
    check code == 0
    check outp == "fixturecmd got: [\"hello\",\"two words\"]"
    check pluginWaitForLog(logPath,
      proc(l: string): bool = l.startsWith("clicmd|"))

  test "cli options delivered as json":
    resetLog()
    pluginsDeliverCliOptions(@[("fixture-opt", "v"),
                               ("fixture-flag", ""),
                               ("fixture-opt", "v2")])
    check pluginWaitForLog(logPath,
      proc(l: string): bool =
        "cliopts|" in l and "\"fixture-opt\":\"v2\"" in l and
        "\"fixture-flag\":true" in l)

  test "registered tool advertised and executed":
    check pluginsHaveTool("fixture_echo")
    check not pluginsHaveTool("bash")  # builtin names never registerable
    let schemas = pluginToolSchemas()
    let schemaList = schemas.getElems()
    check schemaList.len == 1
    check schemaList[0]{"function"}{"name"}.getStr == "fixture_echo"
    resetLog()
    let (outp, code) = pluginToolExec("fixture_echo",
                                      """{"text": "ping"}""")
    check code == 0
    check "fixture_echo got: " in outp
    check pluginWaitForLog(logPath,
      proc(l: string): bool = l.startsWith("toolexec|"))

  test "async events reach the plugin thread":
    resetLog()
    pluginOnSessionStart("/tmp/s.3log", "/tmp", "zai", "glm-5", true, 7)
    pluginOnTurnStart(3, 1200)
    pluginOnTurnEnd(3, 1300, 42, 0, 5000, false, "/tmp/s.3log")
    pluginOnModelRetry("zai", "glm-5", 429, "rate", 12, 2)
    pluginOnCompact(30, 6, "recap text")
    pluginOnFileWrite("src/a.nim", 10, 0)
    check pluginWaitForLog(logPath,
      proc(l: string): bool = l.startsWith("session|"))
    check pluginWaitForLog(logPath,
      proc(l: string): bool = l.startsWith("turnstart|3"))
    check pluginWaitForLog(logPath,
      proc(l: string): bool = l.startsWith("turnend|3"))
    check pluginWaitForLog(logPath,
      proc(l: string): bool = l.startsWith("retry|429"))
    check pluginWaitForLog(logPath,
      proc(l: string): bool = l.startsWith("compact|30->6"))
    check pluginWaitForLog(logPath,
      proc(l: string): bool = l.startsWith("filewrite|src/a.nim"))

  test "trace channel logs calls and mutation diffs":
    check fileExists(dbgPath)
    let dbg = readFile(dbgPath)
    check "tc_on_prompt" in dbg
    check "prompt diff" in dbg
    check "hello" in dbg

  test "timeout: default outcome, strikes, then demotion":
    putEnv("TC_FIXTURE_MODE", "hang")
    putEnv("THREECODE_PLUGIN_SYNC_MS", "150")
    defer:
      putEnv("TC_FIXTURE_MODE", "mutate")
      putEnv("THREECODE_PLUGIN_SYNC_MS", "3000")
    # three slow calls: each returns the original text, one strike each
    for i in 1..3:
      var text = "orig" & $i
      pluginOnPrompt(text, "/tmp/s.3log", "zai", "glm-5")
      check text == "orig" & $i
    check "DEMOTED" in pluginsListBody()
    # fourth call is skipped fast (demoted): no timeout wait, no change
    let t0 = epochTime()
    var text = "after"
    pluginOnPrompt(text, "/tmp/s.3log", "zai", "glm-5")
    check text == "after"
    check epochTime() - t0 < 1.0
    # demoted also applies to tool exec
    check pluginToolExec("fixture_echo", "{}").code == 1

  teardown:
    # the demotion test is last; drain and join after every run so a
    # fixture stuck in a hang-hook can't outlive the suite process
    pluginsShutdown()
