## A controllable local HTTP server for testing the real network transport
## (connect, handshake, send, streaming body) and its cancellation paths.
##
## The stub provider (`-d:providerStub`) short-circuits `callModel` before any
## socket is touched, so it cannot exercise the connect/handshake/recv phases
## where interrupt bugs live. This server drives the real `streamHttp`/
## `callHttp` path: configure it with a `MockScenario`, point a non-stub 3code
## binary at `http://127.0.0.1:<port>`, and it replays the chosen mode against
## the live transport.
##
## Scenarios model the distinct blocking phases of an API call:
##
##   - ``msSilentAfterAccept``: accept the TCP connection, then never reply.
##     Blocks the recv loop (and, over TLS, the handshake). This is the
##     black-holed-edge case: connect completes but no bytes arrive.
##   - ``msSlowStream``: send a valid SSE head + first chunk, then stall.
##     Exercises the recv-loop interrupt mid-body.
##   - ``msOk``: a complete, prompt SSE response. The happy path; lets a test
##     confirm the interrupt did not corrupt the follow-up turn.
##
## The server speaks plain HTTP (not TLS): the test binary is built with
## `-d:testPlainHttp` so ``http://127.0.0.1`` routes through the real transport
## without needing a local TLS cert. The connect-phase interrupt mechanism
## (fd shutdown wake) is transport-agnostic; `streamhttp`'s own suite covers
## the TLS-handshake variant.
import std/[net, os, strutils]
from std/times import epochTime

when defined(posix):
  import std/posix except SocketHandle

type
  MockScenario* = enum
    msOk                 ## complete SSE response immediately
    msSilentAfterAccept  ## accept TCP, then never reply (recv stall)
    msSlowStream         ## valid SSE head + first chunk, then stall
    msSlowStreamNoUsage  ## content chunk with NO usage object, then stall
    msStallAfterDone     ## complete SSE response, then black-hole (teardown close hang)

  MockServer* = ref object of RootObj
    listener*: Socket
    port*: Port
    thread*: Thread[MockServer]
    stop*: bool
    scenario*: MockScenario  ## shared via the ref; the server thread reads this
    chunkDelayMs*: int

proc setSocketTimeoutMs(sock: Socket; ms: int) =
  ## Set SO_RCVTIMEO so blocking accept()/recv() wake periodically and the
  ## server loop can re-check `stop`. Without this, `accept()` blocks forever
  ## on Linux and `stopMockServer`'s `joinThread` hangs if the client never
  ## connects (e.g. an interrupt kills the turn before connect completes).
  when defined(posix):
    var tv: Timeval
    tv.tv_sec = Time(ms div 1000)
    tv.tv_usec = Suseconds((ms mod 1000) * 1000)
    discard setsockopt(sock.getFd(), SOL_SOCKET, SO_RCVTIMEO,
                       addr tv, sizeof(tv).SockLen)

proc sseChunk(data: string): string =
  ## Wrap `data` as one SSE ``data:`` event with chunked encoding framing.
  let payload = "data: " & data & "\n\n"
  payload.len.toHex(8) & "\r\n" & payload & "\r\n"

proc sseDoneChunk(): string =
  let payload = "data: [DONE]\n\n"
  payload.len.toHex(8) & "\r\n" & payload & "\r\n"

proc handleOk(s: MockServer; client: Socket) =
  let body = """{"choices":[{"delta":{"content":"hi"},"finish_reason":""}],""" &
    """"usage":{"prompt_tokens":5,"completion_tokens":2,"total_tokens":7,"cached_tokens":0}}"""
  client.send("HTTP/1.1 200 OK\r\n")
  client.send("Content-Type: text/event-stream\r\n")
  client.send("Transfer-Encoding: chunked\r\n\r\n")
  client.send(sseChunk(body))
  if s.chunkDelayMs > 0: sleep(s.chunkDelayMs)
  client.send(sseDoneChunk())
  client.send("0\r\n\r\n")

proc holdUntilGone(client: Socket) =
  ## Block without sending anything, holding the socket open until the client
  ## gives up (shutdown/close surfaces as a 0-length recv here).
  client.setSocketTimeoutMs(200)
  let deadline = epochTime() + 30.0
  while epochTime() < deadline:
    let chunk = try: client.recv(64) except CatchableError: ""
    if chunk.len == 0: break
    sleep(20)

proc handleSilent(s: MockServer; client: Socket) = client.holdUntilGone()

proc handleStallAfterDone(s: MockServer; client: Socket) =
  ## Serve a complete, prompt SSE response (so the client's stream loop
  ## finishes cleanly and returns), then black-hole: hold the socket open
  ## without sending anything. The client then tears the connection down in
  ## `closeCachedStreamConn`. Against a black-holed peer a graceful TLS
  ## `close_notify` would hang forever waiting for the peer's second leg
  ## (and, under the stdlib's `blockSigpipe`, also block in `sigwait` for a
  ## SIGPIPE that never arrives) - the teardown deadlock threecode hit on
  ## flaky links. Mirrors the real flaky-network case where the response
  ## lands but the link dies as the connection is being closed.
  s.handleOk(client)
  client.holdUntilGone()

proc handleSlowStream(s: MockServer; client: Socket) =
  let body = """{"choices":[{"delta":{"content":"fi"},"finish_reason":""}],""" &
    """"usage":{"prompt_tokens":5,"completion_tokens":2,"total_tokens":7,"cached_tokens":0}}"""
  client.send("HTTP/1.1 200 OK\r\n")
  client.send("Content-Type: text/event-stream\r\n")
  client.send("Transfer-Encoding: chunked\r\n\r\n")
  client.send(sseChunk(body))
  # Now stall: hold the socket, never send [DONE] or the closing chunk.
  client.holdUntilGone()

proc handleSlowStreamNoUsage(s: MockServer; client: Socket) =
  ## Content delta with no `usage` object, then stall. Models the real-world
  ## interrupt shape: providers send usage as a separate end-of-stream SSE
  ## event, so a mid-stream interrupt leaves `callModel` with content but
  ## `usage.totalTokens == 0`. Used to lock out the spurious `· Xs` timing
  ## line that `hookNoUsage` used to emit above the interrupt message.
  let body = """{"choices":[{"delta":{"content":"fi"},"finish_reason":""}]}"""
  client.send("HTTP/1.1 200 OK\r\n")
  client.send("Content-Type: text/event-stream\r\n")
  client.send("Transfer-Encoding: chunked\r\n\r\n")
  client.send(sseChunk(body))
  client.holdUntilGone()

proc serverLoop(s: MockServer) {.thread.} =
  {.cast(gcsafe).}:
    try:
      while not s.stop:
        var client: Socket
        try:
          s.listener.accept(client)
        except OSError:
          # SO_RCVTIMEO on the listener wakes accept() every 200ms; the
          # resulting timeout surfaces as OSError here. Re-check `stop`.
          continue
        case s.scenario
        of msOk: s.handleOk(client)
        of msSilentAfterAccept: s.handleSilent(client)
        of msSlowStream: s.handleSlowStream(client)
        of msSlowStreamNoUsage: s.handleSlowStreamNoUsage(client)
        of msStallAfterDone: s.handleStallAfterDone(client)
        try: client.close() except CatchableError: discard
    except CatchableError:
      discard

proc startMockServer*(scenario: MockScenario; chunkDelayMs = 0): MockServer =
  ## Start the mock server and return it. Serves connections under `scenario`
  ## until `stopMockServer`. `chunkDelayMs` is the inter-chunk stall.
  result = MockServer()
  result.listener = newSocket(buffered = false)
  result.listener.setSockOpt(OptReuseAddr, true)
  result.listener.bindAddr(Port(0))
  result.listener.listen()
  result.listener.setSocketTimeoutMs(200)
  let (_, port) = result.listener.getLocalAddr()
  result.port = port
  result.stop = false
  result.scenario = scenario
  result.chunkDelayMs = chunkDelayMs
  createThread(result.thread, serverLoop, result)

proc stopMockServer*(s: MockServer) =
  s.stop = true
  try: s.listener.close() except CatchableError: discard
  joinThread(s.thread)

proc url*(s: MockServer): string =
  "http://127.0.0.1:" & $s.port.uint16
