#[ In-process agent backend for plugin frontends.
##
## The `--gui` entry installs this module's procs as the host half of
## the plugin `agent*` services (see plugins.nim's PluginAgentServices):
## a plugin GUI running on its frontend thread opens the process's one
## AgentSession, kicks turns on a worker thread, and polls events — all
## in-process, no sockets, no second process. The shape mirrors
## rpc.nim's HTTP frontend (one session, one worker per turn, a bounded
## event ring) with the C ABI as the wire.
##
## Threading: services are called only from a plugin frontend thread
## (the ABI contract), one at a time per process — the GUI's own loop
## serializes them. The turn runs on a worker thread created here and
## reports through onEvent into the ring; transcript-reading services
## refuse while a turn is running (the messages are not stable).
]##

import std/[atomics, json, locks, strutils]
import types, util, display, library, plugins, pluginabi

const EventKeep = 512  # ring cap; a GUI that never polls loses the middle

type
  EvItem = tuple
    kind: cint
    text: string
    promptTokens, completionTokens, reasoningTokens, elapsedMs: int

  AgentTurnJob = ref object
    s: library.AgentSession
    text: string

var
  agentSession: library.AgentSession  # nil until agentOpen succeeds
  agentErr = ""
  evLock: Lock
  evInit = false
  ring: seq[EvItem]
  turnBusy: Atomic[bool]
  turnThread: Thread[AgentTurnJob]
  turnStarted = false

proc evInitOnce() =
  if evInit: return
  evInit = true
  initLock(evLock)
  turnBusy.store(false)

proc pushEvent(kind: cint; text: string; usage: Usage = Usage();
               elapsedMs = 0) {.gcsafe.} =
  {.cast(gcsafe).}:
    evLock.acquire()
    ring.add (kind, text, usage.promptTokens, usage.completionTokens,
              usage.reasoningTokens, elapsedMs)
    if ring.len > EventKeep: ring = ring[ring.len - EventKeep .. ^1]
    evLock.release()

proc onEventCb(ev: AgentEvent) {.gcsafe.} =
  case ev.kind
  of aevDelta: pushEvent(taeDelta, ev.text)
  of aevReasoning: pushEvent(taeReasoning, ev.text)
  of aevTool: pushEvent(taeTool, ev.text)
  of aevRetry: pushEvent(taeRetry, ev.text)
  of aevNotice: pushEvent(taeNotice, ev.text)
  of aevDone: pushEvent(taeDone, "", ev.usage, ev.elapsed)
  of aevError: pushEvent(taeError, ev.text)

proc turnThreadMain(job: AgentTurnJob) {.thread.} =
  {.cast(gcsafe).}:
    try:
      discard job.s.prompt(job.text)
    except CatchableError as e:
      pushEvent(taeError, e.msg)
    turnBusy.store(false)

# -- service impls (frontend thread) --------------------------------

proc agentOpenImpl(optsJson: string): cint {.gcsafe.} =
  {.cast(gcsafe).}:
    evInitOnce()
    if agentSession != nil: return 1.cint
    var opts = AgentOptions()
    try:
      if optsJson.strip.len > 0:
        let j = parseJson(optsJson)
        if j.kind == JObject:
          opts.model = j{"model"}.getStr("")
          opts.cwd = j{"cwd"}.getStr("")
          opts.resumeId = j{"resumeId"}.getStr("")
          opts.resume = j{"resume"}.getBool(false)
          opts.sessionPath = j{"sessionPath"}.getStr("")
          opts.experimental = j{"experimental"}.getBool(false)
    except CatchableError:
      agentErr = "agentOpen: optsJson is not valid JSON"
      return 3.cint
    try:
      agentSession = initAgentSession(opts)
    except AgentError as e:
      agentErr = e.msg
      return 3.cint
    agentSession.onEvent = onEventCb
    0.cint

proc agentCloseImpl(): cint {.gcsafe.} =
  {.cast(gcsafe).}:
    if agentSession == nil: return 1.cint
    if turnBusy.load(moAcquire):
      agentSession.interrupt()
      joinThread(turnThread)
      turnStarted = false
    agentSession.close()
    agentSession = nil
    0.cint

proc agentStartImpl(prompt: string): cint {.gcsafe.} =
  {.cast(gcsafe).}:
    if agentSession == nil:
      agentErr = "agentStart: no session (call agentOpen first)"
      return 2.cint
    if turnBusy.load(moAcquire): return 1.cint
    if turnStarted:
      # the previous worker finished (not busy) but may still be winding
      # down; join is instant and makes the handle reusable
      joinThread(turnThread)
      turnStarted = false
    if prompt.strip.len > 0: pushEvent(taeUser, prompt)
    turnBusy.store(true)
    createThread(turnThread, turnThreadMain,
                 AgentTurnJob(s: agentSession, text: prompt))
    turnStarted = true
    0.cint

proc agentCancelImpl(): cint {.gcsafe.} =
  {.cast(gcsafe).}:
    if not turnBusy.load(moAcquire): return 1.cint
    agentSession.interrupt()
    0.cint

proc agentBusyImpl(): cint {.gcsafe.} =
  {.cast(gcsafe).}:
    if turnBusy.load(moAcquire): 1.cint else: 0.cint

proc agentCommandImpl(cmd: string; output: var string): cint {.gcsafe.} =
  {.cast(gcsafe).}:
    if agentSession == nil:
      agentErr = "agentCommand: no session (call agentOpen first)"
      return 2.cint
    if turnBusy.load(moAcquire): return 1.cint
    try:
      output = agentSession.command(cmd)
    except AgentError as e:
      agentErr = e.msg
      return 3.cint
    0.cint

proc removeBlock(text, openTag, closeTag: string): string =
  result = text
  while true:
    let a = result.find(openTag)
    if a < 0: break
    let b = result.find(closeTag, a + openTag.len)
    if b < 0: break
    result = result[0 ..< a] & result[b + closeTag.len .. ^1]

proc agentScrollbackImpl(output: var string): cint {.gcsafe.} =
  {.cast(gcsafe).}:
    if agentSession == nil:
      agentErr = "agentScrollback: no session (call agentOpen first)"
      return 2.cint
    if turnBusy.load(moAcquire): return 1.cint
    let rows = newJArray()
    for m in agentSession.messages:
      let role = m{"role"}.getStr("")
      if role notin ["user", "assistant"]: continue
      var content = stripCheckpointMarkers(m{"content"}.getStr("")).strip
      if role == "user":
        # drop harness-injected scaffolding; show what the user typed
        content = removeBlock(content, "<session_context>", "</session_context>")
        content = removeBlock(content, "<project_notes>", "</project_notes>")
        content = content.strip
      if content.len == 0: continue
      rows.add %*{"role": role, "content": content}
    output = $rows
    0.cint

proc agentLastErrorImpl(): string {.gcsafe.} =
  {.cast(gcsafe).}:
    agentErr

proc agentPollEventImpl(ev: ptr TcAgentEvent): cint {.gcsafe.} =
  {.cast(gcsafe).}:
    if ev == nil: return 0.cint
    evLock.acquire()
    var item: EvItem
    let got = ring.len > 0
    if got:
      item = ring[0]
      ring.delete(0)
    evLock.release()
    if not got: return 0.cint
    zeroMem(ev, sizeof(TcAgentEvent))
    ev[] = TcAgentEvent(abi: TcAbiVersion,
                        structSize: sizeof(TcAgentEvent).int32,
                        kind: item.kind,
                        promptTokens: item.promptTokens.int32,
                        completionTokens: item.completionTokens.int32,
                        reasoningTokens: item.reasoningTokens.int32,
                        elapsedMs: item.elapsedMs.int32)
    if item.text.len > 0:
      ev.text = TcStr(data: cast[cstring](addr item.text[0]),
                      len: item.text.len.int32)
    1.cint

proc agentForceClose*(): cint =
  ## Close the session if one is open: the `--gui` exit path after every
  ## frontend returned, so a GUI that quit without `agentClose` still
  ## gets its session persisted and its locks released. No-op otherwise.
  if agentSession == nil: return 1.cint
  agentCloseImpl()

proc installPluginAgentServices*() =
  ## Wire this module into the plugin host. Idempotent; call before
  ## `pluginsFrontendRun` (the `--gui` entry does).
  evInitOnce()
  plugins.pluginAgentServices = PluginAgentServices(
    open: agentOpenImpl,
    closeImpl: agentCloseImpl,
    start: agentStartImpl,
    cancel: agentCancelImpl,
    busy: agentBusyImpl,
    command: agentCommandImpl,
    scrollback: agentScrollbackImpl,
    lastError: agentLastErrorImpl,
    pollEvent: agentPollEventImpl)
