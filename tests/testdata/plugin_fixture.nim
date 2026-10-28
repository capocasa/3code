#[ Test fixture plugin: exercises every hook of the 3code C ABI.
##
## Built as a .so by tests/core/test_plugins.nim and loaded through the
## real discovery path (XDG_DATA_HOME redirected). Behavior is driven by
## two environment variables read at call time, so one binary covers all
## test cases:
##
##   TC_FIXTURE_LOG   append a "<hook>|<detail>" line per call here
##   TC_FIXTURE_MODE  "" (mutate) | allow | veto | rewrite | takeover |
##                    wrap | hang
##
## It is also the executable example of the SDK include pattern: types
## and helpers first, hooks in the middle, plugin_sdk included LAST.
]##

include threecode/pluginabi
import std/[os, strutils]

proc logLine(hook: string; detail = "") =
  let path = getEnv("TC_FIXTURE_LOG")
  if path.len == 0: return
  let f = open(path, fmAppend)
  defer: f.close()
  f.writeLine(hook & "|" & detail)

proc mode(): string = getEnv("TC_FIXTURE_MODE", "mutate")

proc init*(s: ptr TcState) =
  logLine "init", $s.pluginName
  s.userData = nil

proc shutdown*(s: ptr TcState) =
  logLine "shutdown"

proc onPrompt*(ev: var TcPromptEvent) =
  if mode() == "hang":
    logLine "prompt-hang"
    var i = 0
    while i < 300 and not tcCancelled(tcCurrentState):
      sleep(100)
      inc i
    return
  logLine "prompt", tcView(ev.prompt)
  if mode() != "allow":
    tcAssignStr(ev.prompt, tcView(ev.prompt) & " [fixture]")

proc onSystemPrompt*(ev: var TcSysPromptEvent) =
  logLine "sysprompt", tcView(ev.family)
  if mode() == "mutate":
    tcAssignStr(ev.prompt, tcView(ev.prompt) & "\n(fixture system line)")

proc onToolPre*(ev: var TcToolPreEvent): cint =
  let m = mode()
  let name = tcView(ev.name)
  logLine "toolpre", name & " " & m
  case m
  of "veto":
    if name == "write":
      tcAssignStr(ev.message, "fixture: writes are frozen in this mode")
      return tcVeto
  of "rewrite":
    if name == "write":
      var args = tcView(ev.args)
      args = args.replace("src/a.nim", "src/b.nim")
      tcAssignStr(ev.args, args)
      return tcRewrite
  of "takeover":
    if name == "bash":
      tcAssignStr(ev.message, "fixture: took over this call")
      ev.code = 0
      return tcTakeover
  of "wrap":
    if name == "bash":
      tcAssignStr(ev.message, "before-line")
      tcAssignStr(ev.post, "after-line")
      return tcWrap
  of "hang":
    if name == "write":
      var i = 0
      while i < 300 and not tcCancelled(tcCurrentState):
        sleep(100)
        inc i
      return tcAllow
  else: discard
  tcAllow

proc onToolResult*(ev: var TcToolResultEvent) =
  logLine "toolresult", tcView(ev.name)
  let outp = tcView(ev.output)
  if "SECRET" in outp:
    tcAssignStr(ev.output, outp.replace("SECRET", "[redacted]"))

proc registerCli*(s: ptr TcState) =
  logLine "registercli"
  # ok registrations
  discard s.registerCliCommand("fixturecmd", "fixture plugin subcommand")
  discard s.registerCliOption("fixture-opt", 'Q', "a fixture value option")
  discard s.registerCliOption("fixture-flag", 'W', "a fixture flag",
                              takesValue = false)
  # rejected ones: builtin subcommand, builtin long option, builtin
  # short char, duplicate command
  discard s.registerCliCommand("provider", "hijack attempt")
  discard s.registerCliOption("model", 'Z', "hijack attempt")
  discard s.registerCliOption("evil-opt", 'm', "hijack attempt")
  discard s.registerCliCommand("fixturecmd", "duplicate")

proc onCliCommand*(ev: var TcCliCommandEvent): int32 =
  logLine "clicmd", tcView(ev.args)
  tcAssignStr(ev.output, "fixturecmd got: " & tcView(ev.args))
  if mode() == "failcmd": 7 else: 0

proc onCliOptions*(ev: var TcCliOptionsEvent) =
  logLine "cliopts", tcView(ev.options)

proc registerTools*(s: ptr TcState) =
  logLine "register"
  discard s.registerTool("fixture_echo", "echo its args back",
    """{"type":"function","function":{"name":"fixture_echo","description":"echo its args back","parameters":{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}}}""")

proc onToolExec*(ev: var TcToolExecEvent): int32 =
  logLine "toolexec", tcView(ev.args)
  tcAssignStr(ev.output, "fixture_echo got: " & tcView(ev.args))
  0

proc onTurnStart*(ev: var TcTurnEvent) =
  logLine "turnstart", $ev.turn

proc onTurnEnd*(ev: var TcTurnEndEvent) =
  logLine "turnend", $ev.turn & " interrupted=" & $ev.interrupted

proc onModelRetry*(ev: var TcRetryEvent) =
  logLine "retry", $ev.status & " " & tcView(ev.category)

proc onSessionStart*(ev: var TcSessionEvent) =
  logLine "session", tcView(ev.provider) & " resumed=" & $ev.resumed

proc onCompact*(ev: var TcCompactEvent) =
  logLine "compact", $ev.before & "->" & $ev.after

proc onFileWrite*(ev: var TcFileWriteEvent) =
  logLine "filewrite", tcView(ev.path) & " kind=" & $ev.kind

include threecode/plugin_sdk
