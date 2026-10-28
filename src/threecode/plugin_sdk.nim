#[ The 3code plugin SDK (Nim).
##
## A plugin is one Nim module. The canonical shape:
##
##     include threecode/pluginabi   # types + helpers (FIRST)
##     import std/[os, json]         # your imports
##
##     proc onPrompt*(ev: var TcPromptEvent) =
##       if "todo" in tcView(ev.prompt):
##         tcAssignStr(ev.prompt, tcView(ev.prompt) & "\n(seen by myplugin)")
##
##     proc onToolPre*(ev: var TcToolPreEvent): cint =
##       if tcView(ev.name) == "write":
##         ev.verdict = tcVeto
##         tcAssignStr(ev.message, "myplugin: writes are frozen today")
##         return tcVeto
##       tcAllow
##
##     proc registerTools*(s: ptr TcState) =
##       discard s.registerTool("weather", "current conditions",
##         """{"type":"function","function":{"name":"weather",
##            "parameters":{"type":"object","properties":{
##              "city":{"type":"string"}},"required":["city"]}}}""")
##
##     proc onToolExec*(ev: var TcToolExecEvent): int32 =
##       tcAssignStr(ev.output, "args were: " & tcView(ev.args))
##       0
##
##     include threecode/plugin_sdk   # exports the tc_* hooks (LAST)
##
## Build with:
##     nim c --app:lib --mm:orc --threads:on -o:myplugin.so myplugin.nim
## and drop the library in ~/.local/share/3code/lib/ (plus a skill .md
## in ~/.config/3code/skills/ if the plugin wants to teach the model
## anything). `--threads:on` matters: the host calls you from its own
## plugin thread, and the SDK must register that thread with your
## runtime's GC (tcEnter below) before any Nim allocation.
##
## Optional procs (define any subset; only defined ones are exported
## and thus subscribed by the host):
##   init(s: ptr TcState)                 return 0 (value reserved)
##   shutdown(s: ptr TcState)
##   registerTools(s: ptr TcState)        call s.registerTool N times
##   registerCli(s: ptr TcState)          call s.registerCliCommand /
##                                        s.registerCliOption N times
##   onCliCommand(ev: var TcCliCommandEvent): int32
##                                        a `3code <name>` subcommand ran
##   onCliOptions(ev: var TcCliOptionsEvent)
##                                        plugin options seen on argv
##   onPrompt(ev: var TcPromptEvent)
##   onSystemPrompt(ev: var TcSysPromptEvent)
##   onToolPre(ev: var TcToolPreEvent): cint
##   onToolResult(ev: var TcToolResultEvent)
##   onToolExec(ev: var TcToolExecEvent): int32
##   onTurnStart(ev: var TcTurnEvent)
##   onTurnEnd(ev: var TcTurnEndEvent)
##   onModelRetry(ev: var TcRetryEvent)
##   onSessionStart(ev: var TcSessionEvent)
##   onCompact(ev: var TcCompactEvent)
##   onFileWrite(ev: var TcFileWriteEvent)
##
## Hook filtering (e.g. only some tools) is done here in your code,
## not in the host: the host calls every subscribed plugin for every
## event; cheap `if tcView(ev.name) != "write": return` guards are the
## intended idiom.
]##

var tcSdkThreadReady {.threadvar.}: bool

proc tcEnter(s: ptr TcState = nil) {.inline.} =
  ## Register the calling thread with this library's runtime. The host
  ## plugin thread is foreign to the .so's GC; without this, the first
  ## allocation on it is undefined behavior. Also publishes the state
  ## pointer of the call in flight.
  when declared(setupForeignThreadGc) and not defined(nimscript):
    if not tcSdkThreadReady:
      setupForeignThreadGc()
      tcSdkThreadReady = true
  if s != nil: tcCurrentState = s

proc tc_abi_version*(): cint {.exportc, dynlib, cdecl.} =
  TcAbiVersion

when declared(shutdown):
  proc tc_shutdown*(s: ptr TcState) {.exportc, dynlib, cdecl.} =
    tcEnter(s)
    when compiles(shutdown(s)):
      shutdown(s)

proc tc_init*(s: ptr TcState): cint {.exportc, dynlib, cdecl.} =
  tcEnter(s)
  when declared(init):
    when compiles(init(s)):
      init(s)
    else:
      {.error: "init must take (s: ptr TcState)".}
  0.cint

when declared(registerTools):
  proc tc_register_tools*(s: ptr TcState) {.exportc, dynlib, cdecl.} =
    tcEnter(s)
    registerTools(s)

when declared(registerCli):
  proc tc_register_cli*(s: ptr TcState) {.exportc, dynlib, cdecl.} =
    tcEnter(s)
    registerCli(s)

when declared(onCliCommand):
  proc tc_cli_command*(s: ptr TcState; ev: ptr TcCliCommandEvent): cint {.
      exportc, dynlib, cdecl.} =
    tcEnter(s)
    ev.code = onCliCommand(ev[])
    0.cint

when declared(onCliOptions):
  proc tc_on_cli_options*(s: ptr TcState; ev: ptr TcCliOptionsEvent) {.
      exportc, dynlib, cdecl.} =
    tcEnter(s)
    onCliOptions(ev[])

when declared(onPrompt):
  proc tc_on_prompt*(s: ptr TcState; ev: ptr TcPromptEvent) {.
      exportc, dynlib, cdecl.} =
    tcEnter(s)
    onPrompt(ev[])

when declared(onSystemPrompt):
  proc tc_on_system_prompt*(s: ptr TcState; ev: ptr TcSysPromptEvent) {.
      exportc, dynlib, cdecl.} =
    tcEnter(s)
    onSystemPrompt(ev[])

when declared(onToolPre):
  proc tc_on_tool_pre*(s: ptr TcState; ev: ptr TcToolPreEvent): cint {.
      exportc, dynlib, cdecl.} =
    tcEnter(s)
    ev.verdict = onToolPre(ev[])
    ev.verdict

when declared(onToolResult):
  proc tc_on_tool_result*(s: ptr TcState; ev: ptr TcToolResultEvent) {.
      exportc, dynlib, cdecl.} =
    tcEnter(s)
    onToolResult(ev[])

when declared(onToolExec):
  proc tc_tool_exec*(s: ptr TcState; ev: ptr TcToolExecEvent): cint {.
      exportc, dynlib, cdecl.} =
    tcEnter(s)
    ev.code = onToolExec(ev[])
    0.cint

when declared(onTurnStart):
  proc tc_on_turn_start*(s: ptr TcState; ev: ptr TcTurnEvent) {.
      exportc, dynlib, cdecl.} =
    tcEnter(s)
    onTurnStart(ev[])

when declared(onTurnEnd):
  proc tc_on_turn_end*(s: ptr TcState; ev: ptr TcTurnEndEvent) {.
      exportc, dynlib, cdecl.} =
    tcEnter(s)
    onTurnEnd(ev[])

when declared(onModelRetry):
  proc tc_on_model_retry*(s: ptr TcState; ev: ptr TcRetryEvent) {.
      exportc, dynlib, cdecl.} =
    tcEnter(s)
    onModelRetry(ev[])

when declared(onSessionStart):
  proc tc_on_session_start*(s: ptr TcState; ev: ptr TcSessionEvent) {.
      exportc, dynlib, cdecl.} =
    tcEnter(s)
    onSessionStart(ev[])

when declared(onCompact):
  proc tc_on_compact*(s: ptr TcState; ev: ptr TcCompactEvent) {.
      exportc, dynlib, cdecl.} =
    tcEnter(s)
    onCompact(ev[])

when declared(onFileWrite):
  proc tc_on_file_write*(s: ptr TcState; ev: ptr TcFileWriteEvent) {.
      exportc, dynlib, cdecl.} =
    tcEnter(s)
    onFileWrite(ev[])
