## ACP frontend: run 3code as an Agent Client Protocol v1 agent.
##
## `3code acp` (or `3code --acp`) speaks ACP over stdio for editors and
## custom clients: newline-delimited JSON-RPC 2.0, agent role, one session
## per process. It is a thin translation layer over the library module, the
## same embedding surface a GUI or batch script would use:
##
## * `initialize` -> capabilities (`loadSession`, `session/resume`)
## * `session/new` / `session/load` / `session/resume` -> `initAgentSession`
##   (`.3log` id as ACP sessionId; `load` replays history as chunks)
## * `session/prompt` -> `AgentSession.prompt` on a worker thread, streaming
##   `session/update` notifications (message chunks, thought chunks, tool
##   activity as completed tool cards, usage when the context window is
##   known); the response carries `end_turn` or `cancelled`
## * `session/cancel` -> `AgentSession.interrupt`
##
## Not supported and not advertised: MCP servers (accepted and ignored),
## fs/terminal client capabilities (3code keeps its own sandbox), permission
## requests, elicitation, modes, session config options, authentication.
## Stdout carries protocol records only; diagnostics go to stderr.

import std/[json, options, os, parseopt, strutils, atomics, locks]
import types, util, prompts, session, display, config, library

const
  AcpProtocolVersion = 1
  JrParseError = -32700
  JrMethodNotFound = -32601
  JrInvalidParams = -32602
  JrAppError = -32000

type
  PromptJob = ref object
    ## Worker-thread argument: the frontend, the request id to answer, and
    ## the assembled prompt text travel in one heap box because thread
    ## procs can't capture.
    fe: AcpFrontend
    reqId: JsonNode
    text: string

  AcpFrontend = ref object
    initialized: bool
    model: string
    debug: bool
    s: AgentSession
    sessionId: string
    gate: Lock          # one JSON-RPC record at a time across threads
    busy: Atomic[bool]  # a prompt turn is in flight
    worker: Thread[PromptJob]
    workerStarted: bool
    msgSeq: int
    toolSeq: int

# ---------- JSON access ----------
#
# `node{"key"}` returns nil for a missing key in Nim 2.2, and every
# proc then dereferences it. Protocol input is untrusted shape: a missing
# `cwd`, a prompt block without a `type`, a client response where a
# request would be. `jget` makes missing mean `null`, and the stdlib
# accessors (`getStr`, `getBool`, `.kind`) all have safe JNull behavior.

proc jget(n: JsonNode; key: string): JsonNode =
  let v = n{key}
  if v == nil: newJNull() else: v

# ---------- wire ----------

proc send(fe: AcpFrontend; node: JsonNode) =
  ## One JSON-RPC record per line, atomically: turn updates stream from the
  ## worker thread while the main thread answers other requests. A failed
  ## write means the client is gone; exiting mirrors the SIGPIPE behavior
  ## a POSIX client hangup would produce anyway.
  try:
    withLock fe.gate:
      stdout.writeLine $node
      stdout.flushFile()
  except CatchableError:
    if fe.s != nil: fe.s.interrupt()
    quit 0

proc respond(fe: AcpFrontend; id: JsonNode; result: JsonNode) =
  fe.send(%*{"jsonrpc": "2.0", "id": id, "result": result})

proc respondErr(fe: AcpFrontend; id: JsonNode; code: int; msg: string) =
  fe.send(%*{"jsonrpc": "2.0", "id": id,
             "error": {"code": code, "message": msg}})

proc notifyUpdate(fe: AcpFrontend; update: JsonNode) =
  if fe.sessionId.len == 0: return
  fe.send(%*{"jsonrpc": "2.0", "method": "session/update",
             "params": {"sessionId": fe.sessionId, "update": update}})

# ---------- sessions ----------

proc openSession(fe: AcpFrontend; cwd, resumeId: string) =
  ## Swap the live session (saved and unlocked) for a fresh or resumed one.
  ## Raises `AgentError` (no provider, unknown session, locks held).
  if fe.s != nil: fe.s.close()
  fe.sessionId = ""
  var opts = AgentOptions(
    cwd: cwd,
    resumeId: resumeId,
    model: fe.model,
    debug: fe.debug)
  fe.s = initAgentSession(opts)
  fe.sessionId = sessionIdFromPath(fe.s.state.savePath)

proc removeBlock(text, openTag, closeTag: string): string =
  ## Drop every open..close pair; a lone opening tag leaves the text
  ## untouched for the caller's dangling-tag handling.
  result = text
  while true:
    let a = result.find(openTag)
    if a < 0: break
    let b = result.find(closeTag, a + openTag.len)
    if b < 0: break
    result = result[0 ..< a] & result[b + closeTag.len .. ^1]

proc replayUserText(content: string): string =
  ## Stored first-user messages carry harness-injected scaffolding: a
  ## `<session_context>` block (cwd, git, ls) and `<project_notes>` blocks
  ## (discovered AGENTS.md). When notes were found the context block wraps
  ## them without its own closing tag, so a dangling opener is stripped
  ## through the last notes block. Replay shows what the user typed.
  result = removeBlock(content, "<session_context>", "</session_context>")
  result = removeBlock(result, "<project_notes>", "</project_notes>")
  if result.startsWith("<session_context>"):
    let endNotes = result.rfind("</project_notes>")
    if endNotes >= 0:
      result = result[endNotes + "</project_notes>".len .. ^1]
  result = result.strip

proc replayHistory(fe: AcpFrontend) =
  ## `session/load` contract: the full stored conversation as chunk updates
  ## before the load response. Tool transcripts ride inside the message
  ## text, exactly as the `.3log` stores them.
  for m in fe.s.messages:
    let role = jget(m, "role").getStr
    var content = stripCheckpointMarkers(jget(m, "content").getStr("")).strip
    if role == "user": content = replayUserText(content)
    if content.len == 0 or role notin ["user", "assistant"]: continue
    inc fe.msgSeq
    fe.notifyUpdate(%*{
      "sessionUpdate": if role == "user": "user_message_chunk"
                       else: "agent_message_chunk",
      "messageId": "msg_" & $fe.msgSeq,
      "content": {"type": "text", "text": content}})

# ---------- prompt turns ----------

proc runPromptTurn(job: PromptJob) =
  let fe = job.fe
  inc fe.msgSeq
  var mid = "msg_" & $fe.msgSeq
  fe.s.onEvent = proc(ev: AgentEvent) =
    case ev.kind
    of aevDelta:
      fe.notifyUpdate(%*{"sessionUpdate": "agent_message_chunk",
        "messageId": mid, "content": {"type": "text", "text": ev.text}})
    of aevReasoning:
      fe.notifyUpdate(%*{"sessionUpdate": "agent_thought_chunk",
        "messageId": mid, "content": {"type": "text", "text": ev.text}})
    of aevTool:
      # Transcript items arrive committed and plain-text; one completed
      # card per item is the honest representation of that surface. The
      # stream also commits user echoes, the assistant reply echo, and
      # harness autosends as transcript items; ACP already represents
      # those (the client's own prompt, agent_message_chunk), so only
      # genuine tool items become cards.
      if ev.text.startsWith("● ") or ev.text.startsWith("❯ ") or
          isEmptyReplyMsg(ev.text):
        return
      if ev.text.startsWith("» "):
        stderr.writeLine "3code acp: " & ev.text
        return
      inc fe.toolSeq
      var title = ev.text.splitLines()[0]
      if title.len > 80: title = title[0 ..< 80] & "..."
      fe.notifyUpdate(%*{"sessionUpdate": "tool_call",
        "toolCallId": "call_" & $fe.toolSeq,
        "title": title, "kind": "other", "status": "completed",
        "content": [{"type": "content",
                     "content": {"type": "text", "text": ev.text}}]})
    of aevDone:
      let window = fe.s.profile.params.contextWindow
      if window.isSome and ev.usage.totalTokens > 0:
        fe.notifyUpdate(%*{"sessionUpdate": "usage_update",
          "used": ev.usage.promptTokens + ev.usage.completionTokens,
          "size": window.get})
      # Next model call (after tool results) opens a new message.
      inc fe.msgSeq
      mid = "msg_" & $fe.msgSeq
    of aevRetry, aevNotice, aevError:
      stderr.writeLine "3code acp: " & ev.text
  try:
    discard fe.s.prompt(job.text)
    fe.respond(job.reqId, %*{"stopReason": "end_turn"})
  except AgentError as e:
    if e.msg == InterruptedByUserMsg:
      fe.respond(job.reqId, %*{"stopReason": "cancelled"})
    else:
      fe.respondErr(job.reqId, JrAppError, e.msg)
  except CatchableError as e:
    fe.respondErr(job.reqId, JrAppError, e.msg)
  fe.s.onEvent = nil
  fe.busy.store(false)

proc acpPromptThread(job: PromptJob) {.thread.} =
  {.cast(gcsafe).}:
    runPromptTurn(job)

proc handlePrompt(fe: AcpFrontend; id: JsonNode; params: JsonNode) =
  if fe.s == nil:
    fe.respondErr(id, JrAppError, "no session: call session/new first")
    return
  if jget(params, "sessionId").getStr != fe.sessionId:
    fe.respondErr(id, JrAppError,
      "unknown session: " & jget(params, "sessionId").getStr)
    return
  if jget(params, "prompt").kind != JArray:
    fe.respondErr(id, JrInvalidParams, "prompt must be a content array")
    return
  var parts: seq[string]
  for b in params["prompt"]:
    case jget(b, "type").getStr
    of "text":
      parts.add jget(b, "text").getStr
    of "resource_link":
      parts.add jget(b, "name").getStr & " (" & jget(b, "uri").getStr & ")"
    else:
      fe.respondErr(id, JrInvalidParams,
        "unsupported prompt content type: " & jget(b, "type").getStr)
      return
  var nonEmpty: seq[string]
  for part in parts:
    if part.len > 0: nonEmpty.add part
  let text = nonEmpty.join("\n\n").strip
  if text.len == 0:
    fe.respondErr(id, JrInvalidParams, "empty prompt")
    return
  if fe.busy.exchange(true):
    fe.respondErr(id, JrAppError, "a prompt turn is already in progress")
    return
  if fe.workerStarted: joinThread(fe.worker)
  fe.workerStarted = true
  createThread(fe.worker, acpPromptThread,
               PromptJob(fe: fe, reqId: id, text: text))

# ---------- dispatch ----------

proc handleLine(fe: AcpFrontend; line: string) =
  var msg: JsonNode
  try:
    msg = parseJson(line)
  except CatchableError as e:
    fe.send(%*{"jsonrpc": "2.0", "id": newJNull(),
               "error": {"code": JrParseError,
                         "message": "parse error: " & e.msg}})
    return
  if msg.kind != JObject or jget(msg, "method").getStr.len == 0:
    return # a response to an agent request (we send none), or not JSON-RPC
  let id = if msg.hasKey("id"): msg["id"] else: nil
  let params = jget(msg, "params")
  let meth = msg["method"].getStr
  if meth != "initialize" and not fe.initialized:
    if id != nil:
      fe.respondErr(id, JrAppError, "not initialized: call initialize first")
    return
  case meth
  of "initialize":
    if id != nil:
      fe.initialized = true
      fe.respond(id, %*{
        "protocolVersion": AcpProtocolVersion,
        "agentCapabilities": {
          "loadSession": true,
          "sessionCapabilities": {"resume": {}}},
        "agentInfo": {"name": "3code", "title": "3code",
                      "version": Version},
        "authMethods": []})
  of "session/new", "session/load", "session/resume":
    if id == nil: return
    if fe.busy.load():
      fe.respondErr(id, JrAppError, "a prompt turn is in progress")
      return
    let cwd = jget(params, "cwd").getStr
    let resumeId =
      if meth == "session/new": ""
      else: jget(params, "sessionId").getStr
    if meth != "session/new" and resumeId.len == 0:
      fe.respondErr(id, JrInvalidParams, "sessionId required")
      return
    if meth == "session/new" and jget(params, "mcpServers").kind == JArray and
        jget(params, "mcpServers").len > 0:
      stderr.writeLine "3code acp: ignoring " &
        $jget(params, "mcpServers").len &
        " MCP server(s): MCP is not supported"
    try:
      openSession(fe, cwd, resumeId)
    except AgentError as e:
      fe.respondErr(id, JrAppError, e.msg)
      return
    if meth == "session/load":
      replayHistory(fe)
    if meth == "session/new":
      fe.respond(id, %*{"sessionId": fe.sessionId})
    else:
      fe.respond(id, %*{})
  of "session/prompt":
    if id == nil: return
    handlePrompt(fe, id, params)
  of "session/cancel":
    if fe.s != nil and fe.busy.load():
      fe.s.interrupt()
  else:
    if id != nil:
      fe.respondErr(id, JrMethodNotFound, "method not found: " & meth)

proc acpMain*(args: seq[string]): int =
  ## `3code acp` entry: run the JSON-RPC loop until stdin closes.
  var model = ""
  var debug = false
  # parseopt with an empty seq silently falls back to the process argv;
  # skip it entirely so `3code acp` parses nothing.
  if args.len > 0:
    var p = initOptParser(args,
      shortNoVal = {'x'}, longNoVal = @["debug", "experimental"])
    for kind, key, val in p.getopt():
      case kind
      of cmdLongOption, cmdShortOption:
        case key
        of "model", "m": model = val
        of "config", "c": configPathOverride = val
        of "debug": debug = true
        of "experimental": types.experimentalEnabled = true
        else:
          stderr.writeLine "3code acp: unknown option: " & key
          return 2
      of cmdArgument:
        stderr.writeLine "3code acp: unexpected argument: " & key
        return 2
      of cmdEnd: discard
  let fe = AcpFrontend(model: model, debug: debug)
  initLock(fe.gate)
  while true:
    var line: string
    if not stdin.readLine(line): break
    if line.strip().len == 0: continue
    handleLine(fe, line)
  # Client closed stdin: drain a live turn (its cancelled response may
  # still be deliverable), then persist and exit.
  if fe.busy.load(): fe.s.interrupt()
  if fe.workerStarted: joinThread(fe.worker)
  if fe.s != nil: fe.s.close()
  0
