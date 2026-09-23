## 3code as a library: a minimal web frontend.
##
## The same agent the 3code CLI runs, driven over HTTP. The 3code API is
## blocking + callback, so the session lives on its own worker thread
## (fed prompts through a channel) and the async HTTP dispatcher never
## runs a turn itself. Events flow back over Server-Sent Events.
##
##   nim c -r example/webserve.nim [model] [--port N] [--host H]   # default 127.0.0.1:8501
##
## Warning: the server is unauthenticated and POST /prompt runs arbitrary
## agent-proposed commands, so it binds loopback by default. --host 0.0.0.0
## (or any non-loopback address) exposes it to the network — only do that
## on a trusted LAN or behind a reverse proxy with auth.
##
## Endpoints:
##   GET  /           a bare-bones chat page
##   GET  /events     SSE stream of AgentEvents (deltas, tools, usage)
##   POST /prompt     body = prompt text; queued to the session thread
##   POST /command    body = a colon command (":tokens"); returns its body
##
## One AgentSession per process (the library's documented constraint);
## events broadcast to however many tabs are listening.

import std/[asynchttpserver, asyncdispatch, asyncnet, json, locks,
            os, strutils]
import threecode

const Page = """<!doctype html>
<meta charset="utf-8">
<title>3code web</title>
<style>
  body { font: 14px/1.5 monospace; max-width: 60em; margin: 2em auto; }
  #log { white-space: pre-wrap; border: 1px solid #ccc; padding: 1em;
         min-height: 20em; }
  .tool { color: #888; } .err { color: #c00; }
  input { width: 80%; font: inherit; }
</style>
<div id="log"></div>
<form id="f"><input id="q" autofocus placeholder="prompt or :command"><button>send</button></form>
<script>
const log = document.getElementById('log');
const esc = (s) => s.replace(/[<>&]/g, c => '&#' + c.codePointAt(0) + ';');
const es = new EventSource('/events');
es.onmessage = (m) => {
  const ev = JSON.parse(m.data);
  if (ev.kind === 'delta') log.append(ev.text);
  else if (ev.kind === 'tool') log.insertAdjacentHTML('beforeend',
    '<span class="tool">\n' + esc(ev.text) + '\n</span>');
  else if (ev.kind === 'done') log.append('\n[' + ev.usage.totalTokens + ' tokens]\n');
  else if (ev.kind === 'error') log.insertAdjacentHTML('beforeend',
    '<span class="err">\n' + esc(ev.text) + '\n</span>');
  log.scrollTop = log.scrollHeight;
};
document.getElementById('f').onsubmit = async (e) => {
  e.preventDefault();
  const q = document.getElementById('q');
  const text = q.value; q.value = '';
  if (text.startsWith(':')) {
    const r = await fetch('/command', {method: 'POST', body: text});
    log.append('\n' + await r.text() + '\n');
  } else {
    log.append('\n> ' + text + '\n');
    fetch('/prompt', {method: 'POST', body: text});  // events stream back
  }
};
</script>
"""

# Lock-protected queues bridge the dispatcher thread (HTTP) and the
# session thread (blocking 3code calls) - the same lock+seq idiom the
# codebase uses for its own worker threads (see netthread.nim; Channel
# is avoided there by convention). Prompts go in; SSE frames come out.
var
  promptLock: Lock
  promptQueue: seq[string]     # dispatcher -> session
  eventLock: Lock
  eventQueue: seq[string]      # session -> dispatcher (JSON SSE frames)
  cmdLock: Lock
  cmdQueue: seq[string]        # dispatcher -> session (colon commands)
  cmdCond: Cond
  cmdResult: string            # one outstanding command at a time
initLock(promptLock)
initLock(eventLock)
initLock(cmdLock)
initCond(cmdCond)

proc pushCommand(cmd: string): string =
  ## Run a colon command on the session thread and wait for its body.
  acquire(cmdLock)
  cmdQueue.add cmd
  cmdResult = ""
  while cmdResult.len == 0:
    wait(cmdCond, cmdLock)
  result = cmdResult
  release(cmdLock)

proc pushPrompt(text: string) =
  withLock promptLock:
    promptQueue.add text

proc popPrompt(): string =
  withLock promptLock:
    if promptQueue.len > 0:
      result = promptQueue[0]
      promptQueue.delete 0

proc pushEvent(frame: string) =
  withLock eventLock:
    eventQueue.add frame

proc drainEvents(): seq[string] =
  withLock eventLock:
    result = eventQueue
    eventQueue.setLen 0

# SSE fan-out: every connected /events client gets every frame.
var
  clientsLock: Lock
  clients: seq[AsyncSocket]
initLock(clientsLock)

proc eventKindName(k: AgentEventKind): string =
  case k
  of aevDelta: "delta"
  of aevReasoning: "reasoning"
  of aevTool: "tool"
  of aevRetry: "retry"
  of aevNotice: "notice"
  of aevDone: "done"
  of aevError: "error"

# ---------- session thread: the only thread that touches AgentSession ----------

type Job = tuple[model: string, experimental: bool]

proc sessionThread(job: Job) {.thread.} =
  ## Owns the AgentSession for its whole life. Blocking calls only;
  ## results and events are pushed to eventChan as JSON strings.
  {.cast(gcsafe).}:
    let session = initAgentSession(AgentOptions(model: job.model,
        experimental: job.experimental))
    session.onEvent = proc(ev: AgentEvent) =
      {.cast(gcsafe).}:
        let j = %*{"kind": eventKindName(ev.kind), "text": ev.text,
                   "usage": {"totalTokens": ev.usage.totalTokens}}
        pushEvent($j)
    pushEvent($(%*{"kind": "ready", "text": session.profileLabel}))
    while true:
      acquire(cmdLock)
      if cmdQueue.len > 0:
        let cmd = cmdQueue[0]
        cmdQueue.delete 0
        cmdResult = session.command(cmd) & "\n"
        signal(cmdCond)
        release(cmdLock)
        continue
      release(cmdLock)
      let prompt = popPrompt()
      if prompt.len == 0:
        sleep(20)
        continue
      try:
        discard session.prompt(prompt)
        pushEvent($(%*{"kind": "turnend", "text": ""}))
      except CatchableError as e:
        pushEvent($(%*{"kind": "error", "text": e.msg}))

# ---------- dispatcher thread: HTTP + SSE ----------

proc flushEvents() {.async.} =
  ## Drain session->dispatcher frames to every SSE client, then sleep.
  while true:
    var batch: seq[string]
    {.cast(gcsafe).}:
      batch = drainEvents()
    for msg in batch:
      var snapshot: seq[AsyncSocket]
      {.cast(gcsafe).}:
        withLock clientsLock:
          snapshot = clients
      for c in snapshot:
        # Fire-and-forget; a failed send marks the socket closed and the
        # owning /events handler prunes it (only that handler mutates the
        # list), so sends here never race a removal.
        asyncCheck c.send("data: " & msg & "\n\n")
    await sleepAsync(30)

proc serve(req: Request) {.async, gcsafe.} =
  let route = $req.reqMethod & " " & req.url.path
  case route
  of "GET /":
    await req.respond(Http200, Page, newHttpHeaders(
      {"Content-Type": "text/html; charset=utf-8"}))
  of "GET /events":
    # Register before the header send: the send awaits, and a prompt
    # landing in that window would otherwise flush to zero clients.
    {.cast(gcsafe).}:
      withLock clientsLock:
        clients.add req.client
    await req.client.send("HTTP/1.1 200 OK\r\n" &
      "Content-Type: text/event-stream\r\nCache-Control: no-cache\r\n\r\n")
    # Hold open until disconnect or a flush send failed; only this handler
    # removes the socket from the list.
    while not req.client.isClosed:
      await sleepAsync(500)
    {.cast(gcsafe).}:
      withLock clientsLock:
        let i = clients.find(req.client)
        if i >= 0: clients.delete(i)
    req.client.close()
  of "POST /prompt":
    {.cast(gcsafe).}:
      pushPrompt(req.body)
    await req.respond(Http202, "turn queued\n")
  of "POST /command":
    # Commands read session state, so they run on the session thread;
    # pushCommand blocks until the body comes back.
    var body = ""
    {.cast(gcsafe).}:
      body = pushCommand(req.body)
    await req.respond(Http200, body)
  else:
    await req.respond(Http404, "not found\n")

proc main() =
  var model = ""
  var host = "127.0.0.1"
  var port = 8501
  var experimental = false
  var i = 1
  while i <= paramCount():
    let a = paramStr(i)
    if a == "--port" and i < paramCount():
      port = parseInt(paramStr(i + 1))
      inc i
    elif a == "--host" and i < paramCount():
      host = paramStr(i + 1)
      inc i
    elif a in ["-x", "--experimental"]:
      experimental = true
    elif model.len == 0:
      model = a
    inc i
  var worker: Thread[Job]
  createThread(worker, sessionThread, (model: model, experimental: experimental))
  echo "3code web frontend on http://", host, ":", port
  asyncCheck flushEvents()
  let server = newAsyncHttpServer()
  waitFor server.serve(port.Port, serve, host)

when isMainModule:
  main()
