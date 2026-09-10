discard """
  # Windows: shutdownCachedStreamFd() is a no-op on Windows (it wraps
  # posix.shutdown to wake a blocking recv on the interrupt path), so the
  # core contract this test asserts (interrupt returns cleanly from a
  # body that never arrives) is not yet implemented cross-platform. The
  # Windows interrupt path needs an equivalent fd-wakeup (e.g. closesocket
  # or a self-pipe). See docs/windows-testing.md.
  disabled: "win"
"""

## Blocks-forever test: a stuck provider must not hang the main thread.
##
## Tier 2 moved the blocking recv loop onto a worker thread so the UI stays
## responsive. This test asserts the core contract: when a provider accepts
## the connection but never sends a body byte, the main thread's poll loop
## keeps advancing, and an interrupt returns cleanly within bounded time
## instead of hanging forever.
##
## The server sends a valid HTTP 200 head, then never sends the SSE body.
## The worker's `readLine` wakes every `QuietRecvWakeMs` (500ms) to re-check
## the interrupt flag. A timer thread sets the interrupt after 1s; `callModel`
## must return shortly after, proving the main thread was not blocked on the
## socket.

import std/[json, net, os, strutils, times, unittest]
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
  client.send(head)
  # Never send a body byte. Wait until the client disconnects (fd shutdown).
  var buf: array[16, char]
  discard client.recv(addr buf[0], buf.len, timeout = -1)
  client.close()

proc url(server: StuckServer): string =
  # Bare endpoint like production provider urls; the transport appends
  # /chat/completions itself.
  "http://127.0.0.1:" & $server.port.uint16 & "/v1"

proc testProfile(server: StuckServer): Profile =
  Profile(name: "test", url: server.url, key: "test-key",
          model: "test-model", family: "glm")

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

{.pop.}
