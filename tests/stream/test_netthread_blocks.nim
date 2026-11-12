## Cross-platform since shutdownCachedStreamFd() grew a Winsock branch
## (winlean.shutdown wakes a blocked recv from any thread); the Windows
## interrupt contract this test asserts is the same fd-wakeup as POSIX.

## Blocks-forever test: a stuck provider must not hang the main thread.
##
## Tier 2 moved the blocking recv loop onto a worker thread so the UI stays
## responsive. This suite asserts the worker-lifetime contract: the caller
## of `callModelThreaded` must never return while a worker can still touch
## its stack-backed job/args, no matter how the call ends — normal
## completion, interrupt, quiet timeout, worker error, or a hook raising
## mid-stream. The `netWorkerGate` hook (compiled in by the adjacent
## .nims) parks a worker at the point modeling the one uninterruptible
## operation — a blocking system resolver/connect with no fd published
## yet — so late-worker access is deterministic, not a sleep-based DNS
## experiment.

import std/[atomics, json, net, os, strutils, times, unittest]
from std/nativesockets import selectRead
import threecode/[api, types]

{.push checks: off.}

type
  StuckServer = ref object
    socket: Socket
    port: Port

proc newStuckServer(): StuckServer =
  result = StuckServer(socket: newSocket())
  result.socket.setSockOpt(OptReuseAddr, true)
  result.socket.bindAddr(Port(0))
  result.socket.listen()
  let (_, p) = result.socket.getLocalAddr()
  result.port = p

proc serveStuckHead(server: StuckServer) {.thread.} =
  ## Accept, drain the request, send a 200 head, then hang forever on the
  ## body. The client gives up via interrupt (fd shutdown) and closes; we
  ## then exit so the thread doesn't leak past the test.
  var client: Socket
  server.socket.accept(client)
  client.setSockOpt(OptReuseAddr, true)
  while client.recvLine(timeout = 5000).strip() != "":
    discard
  let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n" &
             "Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
  try:
    # flags = {}: raise on a gone client instead of std/net's EPIPE spin
    # (nim-lang/Nim#23455; fix drafted as nim-lang/Nim#26251).
    net.send(client, head, flags = {})
    # Never send a body byte. Wait until the client disconnects (fd shutdown).
    var buf: array[16, char]
    discard client.recv(addr buf[0], buf.len, timeout = -1)
  except CatchableError:
    discard
  client.close()

proc url(server: StuckServer): string =
  # Bare endpoint like production provider urls; the transport appends
  # /chat/completions itself.
  "http://127.0.0.1:" & $server.port.uint16 & "/v1"

proc testProfile(server: StuckServer): Profile =
  Profile(name: "test", url: server.url, key: "test-key",
          model: "test-model", family: "glm")

# ---------------------------------------------------------------------------
# One-shot SSE responder for quick post-retirement calls.
# ---------------------------------------------------------------------------

const QuickSse =
  "data: " & $(%*{"choices":[{"index":0,"delta":{"content":"ok"},
    "finish_reason":"stop"}],"id":"x"}) & "\n\n" & "data: [DONE]\n\n"

type
  QuickServer = ref object
    socket: Socket
    port: Port

proc newQuickServer(): QuickServer =
  result = QuickServer(socket: newSocket())
  result.socket.setSockOpt(OptReuseAddr, true)
  result.socket.bindAddr(Port(0))
  result.socket.listen()
  let (_, p) = result.socket.getLocalAddr()
  result.port = p

proc drainRequestBody(client: Socket; contentLength: int) =
  ## Consume exactly the body bytes before close(): a close() with unread
  ## data makes the kernel send RST instead of FIN, which can discard
  ## response bytes already queued on the client.
  if contentLength <= 0: return
  var bodyBuf = newString(contentLength)
  var got = 0
  while got < contentLength:
    let r = client.recv(bodyBuf, contentLength - got, timeout = 10_000)
    if r == 0: break
    got += r

proc serveQuick(server: QuickServer) {.thread.} =
  ## Accept (deadline-bounded so a caller that never dials cannot hang the
  ## join), send one complete SSE reply, drain, close.
  var client: Socket
  let deadline = epochTime() + 15.0
  block acceptLoop:
    while epochTime() < deadline:
      var fds = @[server.socket.getFd]
      if selectRead(fds, 200) == 0: continue
      try: server.socket.accept(client)
      except CatchableError: break acceptLoop
      break acceptLoop
    return
  try:
    client.setSockOpt(OptReuseAddr, true)
    var contentLength = 0
    while true:
      let line = client.recvLine(timeout = 5000).strip()
      if line.len == 0: break
      if line.toLowerAscii().startsWith("content-length:"):
        contentLength = try: parseInt(line.split(":")[1].strip)
                        except ValueError: 0
    let resp =
      "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n" &
      "Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
    net.send(client, resp, flags = {})
    let chunk = toHex(QuickSse.len).toLowerAscii() & "\r\n" & QuickSse & "\r\n"
    net.send(client, chunk, flags = {})
    net.send(client, "0\r\n\r\n", flags = {})
    client.drainRequestBody(contentLength)
  except CatchableError:
    discard
  client.close()

proc newQuickProfile(server: QuickServer): Profile =
  Profile(name: "test", url: "http://127.0.0.1:" & $server.port.uint16 & "/v1",
          key: "test-key", model: "test-model", family: "glm")

# ---------------------------------------------------------------------------
# Deterministic worker gate: park a worker at the resolver/connect point.
# ---------------------------------------------------------------------------

var gateOpen: Atomic[bool]

proc parkInResolver() {.gcsafe.} =
  ## Parked where a first-time blocking getAddrInfo would park: the worker
  ## is alive, owns nothing observable, and no fd shutdown can wake it.
  while not gateOpen.load(moAcquire):
    sleep(2)

proc quietWatchSoon() {.thread.} =
  ## Stand-in for the production quiet-watch thread (fatprompt runtime):
  ## the only production mechanism that ends a call whose worker is parked
  ## in an unbounded resolver/connect. Fires once, then returns.
  sleep(1200)
  requestQuietShutdown()

proc waitForRetiredGone(): bool =
  ## Drive the production reaper until every retired job is joined and
  ## every job freed. Bounded: the worker publishes within milliseconds
  ## of the gate opening, so the first passes finish it.
  when declared(reapRetiredNetJobs):
    for i in 0 ..< 40:
      discard reapRetiredNetJobs(200)
      if netRetiredJobs() == 0 and netJobsLive() == 0:
        return true
      sleep(50)
    false
  else:
    # Pre-fix lifecycle code has no reaper; nothing to drive.
    false

suite "threaded worker: stuck provider does not hang main thread":
  test "interrupt returns cleanly from a body that never arrives":
    let server = newStuckServer()
    var serveThr: Thread[StuckServer]
    createThread(serveThr, serveStuckHead, server)
    clearInterrupted()
    # Timer thread: set the interrupt flag + shutdown the fd after 1s.
    # The main thread's poll loop checks isInterrupted() every 50ms, so
    # callModel must return within ~1.5s of the interrupt firing.
    proc interruptSoon() {.thread.} =
      sleep(1000)
      setInterrupted(true)
      shutdownCachedStreamFd()
    var intThr: Thread[void]
    createThread(intThr, interruptSoon)
    var usage = Usage()
    var raised = false
    let t0 = epochTime()
    try:
      discard callModel(testProfile(server),
        %*[{"role": "user", "content": "go"}], usage, 0)
    except ApiError:
      raised = true
    let elapsed = epochTime() - t0
    joinThread(intThr)
    joinThread(serveThr)
    server.socket.close()
    closeCachedStreamConn()
    clearInterrupted()
    # Must have returned (not hung) and within a bounded window.
    check raised or elapsed < 10.0
    check elapsed < 10.0

suite "threaded worker: lifetime across caller exit":
  test "late worker retired after join budget expires, exits safely after caller returned":
    ## The deterministic late-worker regression: the worker is parked at
    ## the resolver/connect point when the caller's join budget expires.
    ## The caller must return within its budget WITHOUT leaving the worker
    ## referencing expired state; the worker released afterwards must
    ## publish, exit, and be joined by the reaper, leaving no live jobs.
    clearInterrupted()
    clearNetworkQuiet()
    gateOpen.store(false, moRelease)
    when defined(netWorkerTestHooks):
      netWorkerGate = parkInResolver
    let server = newQuickServer()  # never dialed by the parked worker
    var srv: Thread[QuickServer]
    createThread(srv, serveQuick, server)
    clearInterrupted()
    clearNetworkQuiet()
    defer:
      clearInterrupted()
      clearNetworkQuiet()
    let t0 = epochTime()
    # Connect-refused endpoint: once the gate opens, the worker fails
    # fast, publishes a terminal outcome, and exits — no DNS involved.
    let deadProfile = Profile(name: "test",
      url: "http://127.0.0.1:1/v1", key: "test-key",
      model: "test-model", family: "glm")
    var quietThr: Thread[void]
    createThread(quietThr, quietWatchSoon)
    let outcome = callModelThreaded(deadProfile,
      """{"model":"test-model","messages":[],"stream":true}""",
      "test", false)
    joinThread(quietThr)
    let quietShaped = outcome.errMsg.startsWith("network quiet for")
    check quietShaped
    clearNetworkQuiet()
    let callerElapsedMs = int((epochTime() - t0) * 1000)
    # Caller returned after roughly the (shrunk) join budget, not blocked
    # on the parked worker.
    check callerElapsedMs < 10_000
    check outcome.assistantMsg == nil
    # Release the worker only after the caller has fully completed.
    gateOpen.store(true, moRelease)
    # The worker must now exit safely through the production cleanup path
    # and be reaped: no crash, no leaked job, no live worker.
    check waitForRetiredGone()
    when defined(netWorkerTestHooks):
      netWorkerGate = nil
    when declared(netJobsLive):
      check netJobsLive() == 0
      check netRetiredJobs() == 0
    # A subsequent call must be isolated from the retired one and work.
    var usage = Usage()
    let msg = callModel(newQuickProfile(server),
      %*[{"role": "user", "content": "go"}], usage, 0)
    check msg{"content"}.getStr() == "ok"
    joinThread(srv)
    server.socket.close()
    closeCachedStreamConn()
    when declared(netJobsLive):
      check netJobsLive() == 0

  test "callback raising midstream retires the worker cleanly":
    ## A hook raising inside the drain/dispatch loop must not destroy the
    ## job lock under a live worker. The exception propagates, the worker
    ## keeps running on state it owns, publishes a terminal outcome, and
    ## the reaper joins it.
    clearInterrupted()
    clearNetworkQuiet()
    when defined(netWorkerTestHooks):
      netWorkerGate = nil
    let server = newQuickServer()
    var srv: Thread[QuickServer]
    createThread(srv, serveQuick, server)
    let savedHooks = apiStreamHooks
    apiStreamHooks.contentDelta =
      proc (chunk, baseLabel: string; slurped: int): bool {.closure, gcsafe.} =
        raise newException(CatchableError, "hook boom")
    var usage = Usage()
    var raised = false
    try:
      discard callModel(newQuickProfile(server),
        %*[{"role": "user", "content": "go"}], usage, 0)
    except CatchableError as e:
      raised = e.msg == "hook boom"
    finally:
      apiStreamHooks = savedHooks
    check raised
    # The abandoned worker must converge on the production cleanup path:
    # joined, job freed, nothing left retired.
    check waitForRetiredGone()
    when declared(netJobsLive):
      check netJobsLive() == 0
      check netRetiredJobs() == 0
    joinThread(srv)
    server.socket.close()
    closeCachedStreamConn()

  test "repeated short calls leave no live jobs, retired jobs, or locks":
    ## Bounded-repeat lifecycle check on real counters: normal completions
    ## free every job immediately; nothing accumulates.
    clearInterrupted()
    clearNetworkQuiet()
    when defined(netWorkerTestHooks):
      netWorkerGate = nil
    when declared(netJobsLive):
      let before = netJobsLive()
      check before == 0
    for i in 0 ..< 6:
      let server = newQuickServer()
      var srv: Thread[QuickServer]
      createThread(srv, serveQuick, server)
      var usage = Usage()
      let msg = callModel(newQuickProfile(server),
        %*[{"role": "user", "content": "go " & $i}], usage, 0)
      check msg{"content"}.getStr() == "ok"
      joinThread(srv)
      server.socket.close()
      when declared(netJobsLive):
        check netJobsLive() == 0
        check netRetiredJobs() == 0
    closeCachedStreamConn()

{.pop.}
