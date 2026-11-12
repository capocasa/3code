## Owned network-worker lifetime regressions.
##
## The pre-fix caller passed main-stack `NetJobState`/`NetWorkerArgs` to
## the worker and destroyed the job lock on return whenever the join
## budget expired with a live worker or a streaming hook raised. The
## worker then wrote through dangling stack pointers and a destroyed
## lock, and its connection cache lived in module globals, so a retry
## started while the abandoned worker lived could close or reuse the old
## worker's conn.
##
## These tests drive the REAL production lifecycle (`callModelThreaded`,
## `networkWorker`, `drainAndDispatch`) against local plain-HTTP servers,
## with a deterministic compile-time barrier (see the .nims) standing in
## for an uninterruptible resolver wedge, and assert via the retiring-call
## counter that abandoned workers park for the reaper and drain exactly
## once — no false success, no leaked lock, no interference with the
## replacement call.

import std/[atomics, json, net, os, strutils, times, unittest]
import threecode/[api, types]

{.push checks: off.}

type
  Srv = ref object
    socket: Socket
    port: Port
    response: string       ## full canned SSE body (chunked-framed)
    dripCount: int         ## >0: send this many content chunks, then stall
    dripDelayMs: int
    served: Atomic[int]

proc newSrv(response: string): Srv =
  result = Srv(socket: newSocket(), response: response)
  result.socket.setSockOpt(OptReuseAddr, true)
  result.socket.bindAddr(Port(0))
  result.socket.listen()
  let (_, p) = result.socket.getLocalAddr()
  result.port = p

proc url(s: Srv): string =
  "http://127.0.0.1:" & $s.port.uint16 & "/v1"

proc readRequestDrain(client: Socket) =
  ## Read the request head and body so a later close() sends FIN, not RST
  ## (an RST can discard queued response bytes on the client).
  var contentLength = 0
  while true:
    let line = client.recvLine(timeout = 3000).strip()
    if line.len == 0: break
    if line.toLowerAscii().startsWith("content-length:"):
      contentLength = try: parseInt(line.split(":")[1].strip) except ValueError: 0
  if contentLength > 0:
    var buf = newString(contentLength)
    var got = 0
    while got < contentLength:
      let r = client.recv(buf, contentLength - got, timeout = 3000)
      if r <= 0: break
      got += r

proc serveOk(s: Srv) {.thread.} =
  ## One connection: canned complete SSE response, proper chunked framing.
  var client: Socket
  try:
    s.socket.accept(client)
  except CatchableError:
    return
  discard s.served.fetchAdd(1, moRelaxed)
  try:
    client.readRequestDrain()
    let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n" &
               "Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
    client.send(head)
    let body = s.response
    client.send(toHex(body.len).toLowerAscii() & "\r\n" & body & "\r\n")
    client.send("0\r\n\r\n")
  except CatchableError:
    discard
  client.close()

proc serveDripStall(s: Srv) {.thread.} =
  ## One connection: HTTP head, then `dripCount` content chunks with a
  ## delay each, then hold the connection so the worker stays parked in
  ## recv while the caller's callback is unwinding. Exits when the client
  ## disconnects (fd shutdown wakes its recv and closes).
  var client: Socket
  try:
    s.socket.accept(client)
  except CatchableError:
    return
  discard s.served.fetchAdd(1, moRelaxed)
  try:
    client.readRequestDrain()
    let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n" &
               "Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
    client.send(head)
    for i in 0 ..< s.dripCount:
      let d = %*{"choices": [{"index": 0,
        "delta": {"content": "chunk " & $i}}]}
      let payload = "data: " & $d & "\n\n"
      client.send(toHex(payload.len).toLowerAscii() & "\r\n" &
                  payload & "\r\n")
      sleep(s.dripDelayMs)
    # Never finish the stream: no finish_reason, no [DONE], connection
    # held open. The worker stays in recv until woken.
    var buf: array[64, char]
    while client.recv(addr buf[0], buf.len, timeout = -1) > 0:
      discard
  except CatchableError:
    discard
  client.close()

proc okSse(text: string): string =
  let d1 = %*{"choices": [{"index": 0, "delta": {"content": text}}],
               "id": "id-1"}
  let d2 = %*{"choices": [{"index": 0, "delta": {},
               "finish_reason": "stop"}], "id": "id-1"}
  result = "data: " & $d1 & "\n\n" & "data: " & $d2 & "\n\n" & "data: [DONE]\n\n"

proc callProfile(s: Srv): Profile =
  Profile(name: "test", url: s.url, key: "test-key",
          model: "test-model", family: "glm")

proc callBody(): string =
  $(%*{"model": "test-model",
       "messages": [{"role": "user", "content": "go"}]})

when defined(netWorkerTestBarrier):
  from os import sleep

suite "retired network worker lifecycle":
  setup:
    clearInterrupted()
    clearNetworkQuiet()
    setApiStreamHooks(ApiStreamHooks())
    when defined(netWorkerTestBarrier):
      openNetWorkerBarrier()
    # The worker reads this global for per-profile extra headers; the
    # normal path sets it inside callModel.
    extraHeadersProfile = Profile(name: "test", family: "glm")

  teardown:
    setApiStreamHooks(ApiStreamHooks())
    clearInterrupted()
    clearNetworkQuiet()

  test "callback error retires the live worker and drains it exactly once":
    let srv = newSrv("")
    var drip: Thread[Srv]
    srv.dripCount = 6
    srv.dripDelayMs = 120
    createThread(drip, serveDripStall, srv)
    var fired = 0
    setApiStreamHooks(ApiStreamHooks(
      contentDelta: proc(chunk, baseLabel: string; slurped: int): bool =
        inc fired
        if fired >= 3:
          raise newException(ValueError, "hook explode mid-stream")
        false))
    var raised = false
    try:
      discard callModelThreaded(callProfile(srv), callBody(), "test", false)
    except ValueError:
      # The caller's own error classification is preserved: the hook's
      # exception reaches the caller verbatim.
      raised = true
    check raised
    check retiredNetCalls() == 1
    # The worker is still parked in recv on the stalled stream. Wake it
    # the way the quiet watchdog does, then require the parked call to
    # drain: its lock, thread handle, and arg strings are released
    # exactly once, on main, after the worker exited.
    requestQuietShutdown()
    let left = reapRetiredNetCalls(8000)
    check left == 0
    joinThread(drip)
    srv.socket.close()

  test "retired worker's replacement call is not disturbed by it":
    # Real overlap: the replacement runs while the retired worker is
    # still streaming. Job-owned connection caches must keep the two
    # calls from closing or publishing into each other's conns.
    let srvA = newSrv("")
    var drip: Thread[Srv]
    srvA.dripCount = 6
    srvA.dripDelayMs = 120
    createThread(drip, serveDripStall, srvA)
    var fired = 0
    setApiStreamHooks(ApiStreamHooks(
      contentDelta: proc(chunk, baseLabel: string; slurped: int): bool =
        inc fired
        if fired >= 3:
          raise newException(ValueError, "hook explode")
        false))
    var raised = false
    try:
      discard callModelThreaded(callProfile(srvA), callBody(), "test", false)
    except ValueError:
      raised = true
    check raised
    check retiredNetCalls() == 1
    # Disarm the hook: the replacement call must replay its deltas
    # through clean callbacks.
    setApiStreamHooks(ApiStreamHooks())
    # Replacement call while worker 1 is still alive and parked in recv.
    let srvB = newSrv(okSse("replacement round trip"))
    var ok: Thread[Srv]
    createThread(ok, serveOk, srvB)
    let outcome = callModelThreaded(callProfile(srvB), callBody(), "test",
                                    false)
    check outcome.errMsg.len == 0
    check outcome.assistantMsg != nil
    check outcome.assistantMsg{"content"}.getStr == "replacement round trip"
    # Wake the still-streaming retired worker the way the quiet watchdog
    # does (its own fd was already compare-and-cleared from the wake slot
    # at retirement, so the quiet flag is what it observes), then require
    # an exact drain.
    requestQuietShutdown()
    check reapRetiredNetCalls(8000) == 0
    joinThread(drip)
    joinThread(ok)
    srvA.socket.close()
    srvB.socket.close()

  when defined(netWorkerTestBarrier):
    test "join-budget expiry retires the parked worker; no false success":
      # Park the worker before any fd exists (the wedge shape), interrupt
      # the caller, and let the shrunk join budget expire. The caller must
      # return without an outcome (no fabricated success), park the call
      # for the reaper, and leave room for a fully working replacement.
      closeNetWorkerBarrier()
      let srv = newSrv(okSse("late worker still completes"))
      var ok: Thread[Srv]
      createThread(ok, serveOk, srv)
      var wake: Thread[void]
      var fired = false
      proc interruptSoon() {.thread.} =
        sleep(300)
        fired = true
        setInterrupted(true)
      createThread(wake, interruptSoon)
      let outcome = callModelThreaded(callProfile(srv), callBody(),
                                      "test", false)
      joinThread(wake)
      check fired
      check outcome.assistantMsg.isNil
      check outcome.errMsg.len == 0
      check outcome.statusCode == 0
      check retiredNetCalls() == 1
      # Release the wedge: the retired worker proceeds on its own cache,
      # never advertising its fd over the replacement's, publishes into
      # its abandoned job, and exits for the reaper.
      openNetWorkerBarrier()
      # Replacement runs while the retired worker is still unwinding.
      let srvB = newSrv(okSse("fresh call after expiry"))
      var ok2: Thread[Srv]
      createThread(ok2, serveOk, srvB)
      clearInterrupted()
      let second = callModelThreaded(callProfile(srvB), callBody(),
                                     "test", false)
      check second.errMsg.len == 0
      check second.assistantMsg != nil
      check second.assistantMsg{"content"}.getStr == "fresh call after expiry"
      check reapRetiredNetCalls(8000) == 0
      joinThread(ok)
      joinThread(ok2)
      srv.socket.close()
      srvB.socket.close()
      clearInterrupted()

  test "repeated short calls park nothing and keep completing":
    # Sequential calls must not accumulate live workers, locks, handles,
    # or retained jobs: after each joined call the park list is empty.
    for i in 0 ..< 4:
      let srv = newSrv(okSse("round " & $i))
      var ok: Thread[Srv]
      createThread(ok, serveOk, srv)
      let outcome = callModelThreaded(callProfile(srv), callBody(),
                                      "test", false)
      joinThread(ok)
      srv.socket.close()
      check outcome.errMsg.len == 0
      check outcome.assistantMsg != nil
      check outcome.assistantMsg{"content"}.getStr == "round " & $i
      check retiredNetCalls() == 0

{.pop.}
