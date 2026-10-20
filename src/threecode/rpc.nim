## Headless REST frontend: `3code --rpc[=PORT]` serves the plain-text RPC
## surface 3code-app talks to (loopback only; the GUI relays outward).
##
## Wire format: text only. Request bodies are raw text; every answer is
## plain text or TSV rows. TSV text cells escape backslash, tab, CR, LF
## as `\\`, `\t`, `\r`, `\n` so a row is always one line.
##
##   GET  /id                     one row: pid cwd model busy version
##                                sessionid error   (busy 0/1; error is
##                                empty when the session is live)
##   POST /session/new?dir=DIR    reopen the session in DIR; answer:
##                                sessionid, or `error: ...`
##   POST /prompt                 body: the whole prompt; answer:
##                                started | busy | error: ...
##   POST /cancel                 ok (turn interrupted) | idle
##   GET  /events?after=N         long-poll (<= 25 s) TSV rows:
##                                seq kind text
##                                kinds: user delta reasoning tool notice
##                                retry error usage end
##   GET  /scrollback             TSV rows: role text (409 while a turn
##                                runs — the transcript is not stable)
##
## Discovery: the instance writes
##   ~/.local/share/3code/rpc/<pid>   port pid cwd epoch
## on startup and unlinks it at exit; entries whose pid is gone are swept
## on the next start. Clients list that dir and ping /id.
##
## Stdout stays protocol-clean (one startup line); diagnostics go to
## stderr. Same embedding surface as `--acp`: one AgentSession per
## process, one worker thread per turn.

import std/[asynchttpserver, asyncdispatch, atomics, httpcore, json, locks,
            os, options, parseopt, strformat, strutils, tables, times, uri]
when defined(posix):
  import std/posix except SocketHandle
import types, util, prompts, session, display, config, library

const
  EventKeep = 2000   # ring cap; beyond this the oldest half is dropped
  PollBudgetMs = 25_000
  PollSliceMs = 100

type
  RpcEventRow = tuple[seqNum: int64, kind, text: string]

  RpcJob = ref object
    ## Worker-thread argument: the state and the prompt text travel in one
    ## heap box because thread procs can't capture.
    st: RpcState
    text: string

  RpcState = ref object
    s: AgentSession
    sessionId: string
    initError: string
    model: string
    debug: bool
    cwd: string          # the session's dir (chat directory), not the pid's
    busy: Atomic[bool]
    gate: Lock          # one seq at a time across the event ring
    events: seq[RpcEventRow]
    nextSeq: int64
    worker: Thread[RpcJob]
    workerStarted: bool

# ---------- TSV cell escaping ----------

proc esc*(s: string): string =
  ## TSV text-cell escaping (see module doc). Exported: 3code-app decodes
  ## with the mirror-image rule.
  s.multiReplace(("\\", "\\\\"), ("\t", "\\t"), ("\r", "\\r"), ("\n", "\\n"))

proc jget(n: JsonNode; key: string): JsonNode =
  ## Same nil-tolerant access as acp.jget: missing keys read as JNull so
  ## untrusted message shapes never raise.
  let v = n{key}
  if v == nil: newJNull() else: v

proc unpercent(s: string): string =
  ## Percent-decode a query value. `+` stays literal: values here are
  ## paths, not form fields.
  const hex = {'0'..'9', 'a'..'f', 'A'..'F'}
  result = newStringOfCap(s.len)
  var i = 0
  while i < s.len:
    if s[i] == '%' and i + 2 < s.len and s[i + 1] in hex and s[i + 2] in hex:
      result.add chr(fromHex[int](s[i + 1 .. i + 2]))
      inc i, 3
    else:
      result.add s[i]
      inc i

# ---------- event ring ----------

proc push(st: RpcState; kind, text: string) =
  withLock st.gate:
    inc st.nextSeq
    st.events.add((st.nextSeq, kind, text))
    if st.events.len > EventKeep:
      st.events = st.events[EventKeep div 2 .. ^1]

proc rowsAfter(st: RpcState; after: int64): string =
  withLock st.gate:
    for e in st.events:
      if e.seqNum > after:
        result.add $e.seqNum & "\t" & e.kind & "\t" & esc(e.text) & "\n"

proc latestSeq*(st: RpcState): int64 =
  withLock st.gate:
    if st.events.len > 0: result = st.events[^1].seqNum

# ---------- registry ----------

proc rpcDir(): string = userDataRoot() / "rpc"

proc writeRegistry(port: int; cwd: string) =
  createDir(rpcDir())
  writeFile(rpcDir() / $getCurrentProcessId(),
    &"{port}\t{getCurrentProcessId()}\t{esc(cwd)}\t" &
    &"{toUnix(getTime())}\n")

proc sweepStaleRpcEntries() =
  ## Drop entries whose pid no longer exists (killed instances never got
  ## to unlink). Kept best-effort: an unreachable-but-alive pid entry is
  ## the client's problem, resolved by its /id ping.
  when defined(posix):
    let dir = rpcDir()
    if not dirExists(dir): return
    for f in walkFiles(dir / "*"):
      let name = f.splitFile.name
      if name.len > 0 and name.allCharsInSet(Digits):
        let pid = parseInt(name)
        if pid != getCurrentProcessId() and
            kill(Pid(pid), 0) == -1 and errno == ESRCH:
          removeFile(f)

# ---------- sessions & turns ----------

proc openSession(st: RpcState; dir: string) =
  ## Swap the live session (saved and unlocked) for a fresh one in `dir`
  ## ("" = process cwd). Raises `AgentError` (no provider, locks held).
  if st.s != nil: st.s.close()
  st.s = initAgentSession(AgentOptions(
    cwd: dir, model: st.model, debug: st.debug))
  st.sessionId = sessionIdFromPath(st.s.state.savePath)
  st.initError = ""
  st.cwd = if dir.len > 0: dir else: getCurrentDir()

proc removeBlock(text, openTag, closeTag: string): string =
  ## Same normalization as acp.replayUserText: drop open..close pairs; a
  ## lone opener leaves the text for the caller's dangling-tag handling.
  result = text
  while true:
    let a = result.find(openTag)
    if a < 0: break
    let b = result.find(closeTag, a + openTag.len)
    if b < 0: break
    result = result[0 ..< a] & result[b + closeTag.len .. ^1]

proc replayUserText(content: string): string =
  ## Strip harness-injected scaffolding (<session_context>,
  ## <project_notes>) so scrollback shows what the user typed.
  result = removeBlock(content, "<session_context>", "</session_context>")
  result = removeBlock(result, "<project_notes>", "</project_notes>")
  if result.startsWith("<session_context>"):
    let endNotes = result.rfind("</project_notes>")
    if endNotes >= 0:
      result = result[endNotes + "</project_notes>".len .. ^1]
  result = result.strip

proc scrollbackRows(st: RpcState): string =
  ## Stored conversation, one `role text` row per message. Tool
  ## transcripts ride inside the message text, as the .3log stores them.
  if st.s == nil: return ""
  for m in st.s.messages:
    let role = jget(m, "role").getStr
    var content = stripCheckpointMarkers(jget(m, "content").getStr("")).strip
    if role == "user": content = replayUserText(content)
    if content.len == 0 or role notin ["user", "assistant"]: continue
    result.add role & "\t" & esc(content) & "\n"

proc runRpcTurn(job: RpcJob) =
  let st = job.st
  st.push("user", job.text)
  var mid = 1
  st.s.onEvent = proc(ev: AgentEvent) =
    case ev.kind
    of aevDelta:
      st.push("delta", ev.text)
    of aevReasoning:
      st.push("reasoning", ev.text)
    of aevTool:
      # Committed transcript items, plain text. User echoes, reply echo
      # and harness autosends are already represented as their own event
      # kinds; steering lines become notices.
      if ev.text.startsWith("● ") or ev.text.startsWith("❯ ") or
          isEmptyReplyMsg(ev.text):
        return
      if ev.text.startsWith("» ") or ev.text.startsWith("◎ "):
        st.push("notice", ev.text)
        return
      st.push("tool", ev.text)
    of aevDone:
      let window = st.s.profile.params.contextWindow
      let w = if window.isSome: $window.get else: "-"
      st.push("usage", &"prompt={ev.usage.promptTokens} " &
                        &"completion={ev.usage.completionTokens} " &
                        &"window={w} elapsed={ev.elapsed}")
      inc mid  # next model call (after tool results) is a new message
    of aevRetry:
      st.push("retry", ev.text)
    of aevNotice:
      st.push("notice", ev.text)
    of aevError:
      st.push("error", ev.text)
  try:
    discard st.s.prompt(job.text)
    st.push("end", "end_turn")
  except AgentError as e:
    if e.msg == InterruptedByUserMsg:
      st.push("end", "cancelled")
    else:
      st.push("error", e.msg)
      st.push("end", "error")
  except CatchableError as e:
    st.push("error", e.msg)
    st.push("end", "error")
  st.s.onEvent = nil
  st.busy.store(false)

proc rpcTurnThread(job: RpcJob) {.thread.} =
  {.cast(gcsafe).}:
    runRpcTurn(job)

proc startTurn(st: RpcState; text: string): bool =
  ## Atomically claim the busy flag; false means a turn already runs and
  ## the caller answers `busy`.
  if st.busy.exchange(true): return false
  if st.workerStarted: joinThread(st.worker)
  st.workerStarted = true
  createThread(st.worker, rpcTurnThread, RpcJob(st: st, text: text))
  true

# ---------- HTTP ----------

var boundPort = 0  # filled by rpcMain after listen; /session/new rewrites
                   # the registry row (cwd may have changed) with it

proc text(req: Request; code: HttpCode; body: string): Future[void] {.async, gcsafe.} =
  await req.respond(code, body,
    newHttpHeaders({"Content-Type": "text/plain; charset=utf-8"}))

proc handle(st: RpcState; req: Request): Future[void] {.async, gcsafe.} =
  let path = req.url.path.toLowerAscii
  var q: Table[string, string]
  for pair in req.url.query.split('&'):
    if pair.len == 0: continue
    let eq = pair.find('=')
    if eq < 0: q[pair] = ""
    else: q[unpercent(pair[0 ..< eq])] = unpercent(pair[eq + 1 .. ^1])
  case req.reqMethod
  of HttpGet:
    case path
    of "/id":
      let model = if st.s != nil: st.s.profile.model else: st.model
      let busy = if st.busy.load(): "1" else: "0"
      await text(req, Http200,
        &"{getCurrentProcessId()}\t{esc(st.cwd)}\t{esc(model)}\t" &
        &"{busy}\t{Version}\t{st.sessionId}\t{esc(st.initError)}\n")
    of "/events":
      var after = 0'i64
      try:
        if q.getOrDefault("after", "") == "now":
          after = st.latestSeq()  # open-the-chat semantics: only new rows
        else:
          after = parseBiggestInt(q.getOrDefault("after", "0"))
      except ValueError: discard
      let deadline = getTime() + initDuration(milliseconds = PollBudgetMs)
      while true:
        let rows = st.rowsAfter(after)
        if rows.len > 0 or getTime() >= deadline:
          await text(req, Http200, rows)
          break
        await sleepAsync(PollSliceMs)
    of "/scrollback":
      if st.busy.load():
        await text(req, Http409, "busy\n")
      else:
        await text(req, Http200, st.scrollbackRows())
    else:
      await text(req, Http404, "no such endpoint\n")
  of HttpPost:
    case path
    of "/prompt":
      let body = req.body.strip
      if st.s == nil:
        await text(req, Http500, "error: " & st.initError & "\n")
      elif body.len == 0:
        await text(req, Http400, "error: empty prompt\n")
      elif st.busy.load():
        await text(req, Http409, "busy\n")
      else:
        if startTurn(st, body):
          await text(req, Http200, "started\n")
        else:
          await text(req, Http409, "busy\n")
    of "/cancel":
      if st.s != nil and st.busy.load():
        st.s.interrupt()
        await text(req, Http200, "ok\n")
      else:
        await text(req, Http200, "idle\n")
    of "/session/new":
      if st.busy.load():
        await text(req, Http409, "busy\n")
      else:
        try:
          let dir = unpercent(q.getOrDefault("dir", ""))
          {.cast(gcsafe).}:
            openSession(st, dir)
          writeRegistry(boundPort, st.cwd)
          await text(req, Http200, st.sessionId & "\n")
        except AgentError as e:
          st.initError = e.msg
          await text(req, Http500, "error: " & e.msg & "\n")
    else:
      await text(req, Http404, "no such endpoint\n")
  else:
    await text(req, Http405, "method not allowed\n")

proc rpcMain*(args: seq[string]): int =
  ## `3code --rpc` entry: serve until killed. `args[0]` is the raw
  ## `--rpc` / `--rpc=PORT` token; the rest match `--acp` flags.
  var port = 0
  var model = ""
  var debug = false
  var rest: seq[string]
  if args.len > 0:
    if args[0] == "--rpc":
      rest = args[1 .. ^1]
    elif args[0].startsWith("--rpc="):
      try: port = parseInt(args[0][6 .. ^1])
      except ValueError:
        stderr.writeLine "3code --rpc: bad port: " & args[0][6 .. ^1]
        return 2
      rest = args[1 .. ^1]
    else:
      rest = args
  if rest.len > 0:
    var p = initOptParser(rest,
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
          stderr.writeLine "3code --rpc: unknown option: " & key
          return 2
      of cmdArgument:
        stderr.writeLine "3code --rpc: unexpected argument: " & key
        return 2
      of cmdEnd: discard

  let st = RpcState(model: model, debug: debug)
  initLock(st.gate)
  try:
    openSession(st, "")
  except AgentError as e:
    st.initError = e.msg
  if st.cwd.len == 0: st.cwd = getCurrentDir()

  sweepStaleRpcEntries()
  let server = newAsyncHttpServer()
  try:
    server.listen(Port(port), "127.0.0.1")
  except OSError as e:
    stderr.writeLine &"3code --rpc: cannot bind 127.0.0.1:{port}: {e.msg}"
    return 1
  boundPort = server.getPort().int
  writeRegistry(boundPort, st.cwd)
  echo &"3code rpc listening on 127.0.0.1:{boundPort} " &
       &"cwd={getCurrentDir()}" &
       (if st.s == nil: " (no session: " & st.initError & ")" else: "")

  proc cb(req: Request) {.async, gcsafe.} = await handle(st, req)
  proc acceptLoop() {.async, gcsafe.} =
    while true:
      try:
        await server.acceptRequest(cb)
      except CatchableError:
        discard  # one bad client never ends the agent
  waitFor acceptLoop()
