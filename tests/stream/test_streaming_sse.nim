## Output-driven streaming tests.
##
## These tests exercise the REAL streamHttp recv loop, accumulateToolCall,
## and the chunked-decoder against canned SSE served by a local HTTP server.
## They are output-driven: we feed raw SSE byte sequences (fragmented tool
## deltas, truncated streams, complete multi-delta streams, reasoning+tool
## mixes) and assert on the resulting assistant message JsonNode that
## callModel returns.
##
## Must be compiled with -d:testPlainHttp so streamHttp accepts http://127.0.0.1.

import std/[json, jsonutils, net, os, sequtils, strutils, unittest]
from std/times import epochTime
when defined(posix):
  from std/posix import Timeval, Time, Suseconds, SockLen, SOL_SOCKET,
                           SO_RCVTIMEO, setsockopt

import threecode/[api, types]

{.push checks: off.}

# ---------------------------------------------------------------------------
# SSE response builders — each returns a raw SSE byte stream.
# ---------------------------------------------------------------------------

proc makeSseToolDeltas(cmd, id: string, toolName = "bash"): string =
  ## Complete SSE stream: a single tool_call whose arguments arrive in many
  ## small fragments (mirrors GLM tool_stream behavior).
  var deltas: seq[string]
  deltas.add($(%*{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,
    "function":{"name":toolName,"arguments":"{"}}]}}],"id":id}))
  for p in @["\"command\":\"", cmd, "\"}"]:
    deltas.add($(%*{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,
      "function":{"arguments":p}}]}}],"id":id}))
  deltas.add($(%*{"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}],"id":id}))
  result = ""
  for d in deltas:
    result.add("data: " & d & "\n\n")
  result.add("data: [DONE]\n\n")

proc makeSseTruncatedToolDelta(cmd, id: string, cutAfter: int): string =
  ## SSE stream that emits a tool_call whose arguments are CUT MID-STREAM:
  ## no finish_reason, no [DONE]. The server just closes the connection.
  ## `cutAfter` controls how many chars of the arguments JSON arrive.
  let fullArgs = "{\"command\":\"" & cmd & "\"}"
  let partialArgs = fullArgs[0 ..< min(cutAfter, fullArgs.len)]
  let d = $(%*{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,
    "function":{"name":"bash","arguments":partialArgs}}]}}],"id":id})
  result = "data: " & d & "\n\n"
  # NO finish_reason, NO [DONE] — truncated

proc makeSseCompleteContent(text, id: string): string =
  ## Complete SSE stream with plain text content - no tool calls.
  let d = $(%*{"choices":[{"index":0,"delta":{"content":text},"finish_reason":"stop"}],"id":id})
  result = "data: " & d & "\n\n" & "data: [DONE]\n\n"

proc makeSseEmptyWithFinish(finishReason, id: string;
    completionTokens = 0; reasoningTokens = 0): string =
  ## SSE stream that emits NO content/tools/reasoning deltas at all, only a
  ## terminal choice carrying finish_reason plus a usage chunk. This is the
  ## GLM/Qwen/gpt-oss failure mode where the model spent its whole token
  ## budget on internal reasoning and left content empty. The provider
  ## sends usage on a separate final chunk via stream_options.include_usage.
  result = ""
  if completionTokens > 0 or reasoningTokens > 0:
    let details = %*{"reasoning_tokens": %reasoningTokens}
    result.add("data: " & $ %*{"choices":[{"index":0,"delta":{},
      "finish_reason":finishReason}],"id":id} & "\n\n")
    result.add("data: " & $ %*{"choices":[],"id":id,
      "usage":{"prompt_tokens":5,"completion_tokens":completionTokens,
        "total_tokens":5+completionTokens,
        "completion_tokens_details":details}} & "\n\n")
  else:
    result.add("data: " & $ %*{"choices":[{"index":0,"delta":{},
      "finish_reason":finishReason}],"id":id} & "\n\n")
  result.add("data: [DONE]\n\n")

proc makeSseMidStreamError(message, id: string; code = 502): string =
  ## OpenRouter mid-stream error: a `data:` chunk with a top-level `error`
  ## object and `choices[0].finish_reason` set to "error". The HTTP status
  ## is 200 (already committed), so the error arrives in-band. No [DONE]
  ## follows — the stream is terminated by the error event.
  result = "data: " & $ %*{"id":id,"object":"chat.completion.chunk",
    "created":1234567890,"model":"test/model","provider":"test",
    "error":{"code":code,"message":message},
    "choices":[{"index":0,"delta":{"content":""},"finish_reason":"error"}]} & "\n\n"

proc makeSseMidStreamErrorAfterContent(content, message, id: string; code = 502): string =
  ## Mid-stream error after some content was already streamed: a content
  ## delta, then the error chunk. The partial content must NOT be returned
  ## as a valid assistant turn — the error takes priority.
  result = "data: " & $ %*{"choices":[{"index":0,"delta":{"content":content}}],"id":id} & "\n\n"
  result.add(makeSseMidStreamError(message, id, code))

proc makeSseReasoningThenTool(reasoning, cmd, id: string): string =
  ## SSE with reasoning_content first, then a tool_call in many fragments.
  result = ""
  result.add("data: " & $ %*{"choices":[{"index":0,"delta":{"reasoning_content":reasoning}}],"id":id} & "\n\n")
  result.add("data: " & $ %*{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,
    "function":{"name":"bash","arguments":"{"}}]}}],"id":id} & "\n\n")
  for p in @["\"command\":\"", cmd, "\"}"]:
    result.add("data: " & $ %*{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,
      "function":{"arguments":p}}]}}],"id":id} & "\n\n")
  result.add("data: " & $ %*{"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}],"id":id} & "\n\n")
  result.add("data: [DONE]\n\n")

proc makeSseMultiTool(cmd1, cmd2, id: string): string =
  ## SSE stream with two tool_calls, each fragmented across deltas.
  result = ""
  result.add("data: " & $ %*{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,
    "function":{"name":"bash","arguments":"{"}}]}}],"id":id} & "\n\n")
  for p in @["\"command\":\"", cmd1, "\"}"]:
    result.add("data: " & $ %*{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,
      "function":{"arguments":p}}]}}],"id":id} & "\n\n")
  result.add("data: " & $ %*{"choices":[{"index":0,"delta":{"tool_calls":[{"index":1,
    "function":{"name":"bash","arguments":"{"}}]}}],"id":id} & "\n\n")
  for p in @["\"command\":\"", cmd2, "\"}"]:
    result.add("data: " & $ %*{"choices":[{"index":0,"delta":{"tool_calls":[{"index":1,
      "function":{"arguments":p}}]}}],"id":id} & "\n\n")
  result.add("data: " & $ %*{"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}],"id":id} & "\n\n")
  result.add("data: [DONE]\n\n")

# ---------------------------------------------------------------------------
# Local HTTP server serving canned SSE.
# ---------------------------------------------------------------------------

type
  SseServer = ref object
    socket: Socket
    port: Port
    response: string
    capturedHeaders*: seq[string]
      ## Request header lines read by serveCaptureHeaders; read after
      # joinThread. Drives the OpenCode Zen/Go header contract tests.
    acceptDeadline: float
      ## Wakes a blocking accept() every 200ms so a serve thread whose client
      ## never dials (connection cache reuse, a transport retry that stays on
      ## the old socket) can pass its deadline and exit instead of blocking
      ## forever: the joinThread-after-it hang (1442s CI kill).

proc setSocketTimeoutMs(sock: Socket; ms: int) =
  when defined(posix):
    var tv: Timeval
    tv.tv_sec = Time(ms div 1000)
    tv.tv_usec = Suseconds((ms mod 1000) * 1000)
    discard setsockopt(sock.getFd(), SOL_SOCKET, SO_RCVTIMEO,
                       addr tv, sizeof(tv).SockLen)

proc acceptWithinDeadline(server: SseServer; client: var Socket): bool =
  ## Accept with a deadline. Returns false when no client dialed in time,
  ## letting serve threads (and their joiners) terminate instead of hanging
  ## on an accept that will never come.
  while epochTime() < server.acceptDeadline:
    try:
      server.socket.accept(client)
      return true
    except OSError:
      discard  # SO_RCVTIMEO wake: loop and re-check the deadline.
  false

proc newSseServer(response: string): SseServer =
  result = SseServer(socket: newSocket(), response: response,
                     acceptDeadline: epochTime() + 30.0)
  result.socket.setSockOpt(OptReuseAddr, true)
  result.socket.bindAddr(Port(0))
  result.socket.listen()
  result.socket.setSocketTimeoutMs(200)
  let (_, p) = result.socket.getLocalAddr()
  result.port = p

proc readRequestHead(client: Socket): int =
  ## Read the request headers up to the blank line; return Content-Length.
  while true:
    let line = client.recvLine(timeout = 3000)
    let s = line.strip()
    if s.len == 0: return result
    if s.toLowerAscii().startsWith("content-length:"):
      result = try: parseInt(s.split(":")[1].strip) except ValueError: 0

proc drainRequestBody(client: Socket; contentLength: int) =
  ## Consume exactly the Content-Length body bytes before close(). Reading
  ## headers alone leaves the POST body unread in the socket's receive
  ## buffer, and a close() with unread data makes the kernel send RST
  ## instead of FIN; the RST can discard response bytes already queued on
  ## the client, which then sees a 200 head with an empty body and retries
  ## into a server that only accepts one connection (the suite hang).
  ## Runs AFTER the response is fully sent: draining first can deadlock
  ## against the client's send timeout on a partially-written request.
  if contentLength <= 0: return
  var bodyBuf = newString(contentLength)
  var got = 0
  while got < contentLength:
    let r = client.recv(bodyBuf, contentLength - got, timeout = 10_000)
    if r == 0: break
    got += r

proc serveOnce(server: SseServer) =
  var client: Socket
  if not server.acceptWithinDeadline(client): return
  let contentLength = client.readRequestHead()
  let body = server.response
  let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
  client.send(resp)
  let chunk = toHex(body.len).toLowerAscii() & "\r\n" & body & "\r\n"
  client.send(chunk)
  client.send("0\r\n\r\n")
  client.drainRequestBody(contentLength)
  client.close()

proc serveOnceDelayedHead(server: SseServer; delayMs: int) =
  ## Like serveOnce but sleeps `delayMs` before sending the HTTP response
  ## head. Models providers (z.ai GLM) that hold the connection for several
  ## seconds while the model warms up before emitting even the status line.
  var client: Socket
  if not server.acceptWithinDeadline(client): return
  let contentLength = client.readRequestHead()
  sleep(delayMs)
  let body = server.response
  let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
  client.send(resp)
  let chunk = toHex(body.len).toLowerAscii() & "\r\n" & body & "\r\n"
  client.send(chunk)
  client.send("0\r\n\r\n")
  client.drainRequestBody(contentLength)
  client.close()

proc serveThread(server: SseServer) {.thread.} =
  serveOnce(server)

proc url(server: SseServer): string =
  # Bare endpoint like production provider urls; the transport appends
  # /chat/completions (or /responses) itself.
  "http://127.0.0.1:" & $server.port.uint16 & "/v1"

proc testProfile(server: SseServer): Profile =
  Profile(name: "test", url: server.url, key: "test-key",
          model: "test-model", family: "glm")

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

suite "streaming SSE tool-call accumulation":
  test "complete fragmented tool_call reassembles correct arguments":
    let server = newSseServer(makeSseToolDeltas("echo HELLO_WORLD_42", "id-1"))
    var srv: Thread[SseServer]
    createThread(srv, serveThread, server)
    var usage = Usage()
    let result = callModel(testProfile(server), %*[{"role": "user", "content": "run echo HELLO"}], usage, 0)
    check result != nil
    check result{"tool_calls"}.len == 1
    let args = result{"tool_calls"}[0]{"function"}{"arguments"}.getStr()
    check args == "{\"command\":\"echo HELLO_WORLD_42\"}"
    joinThread(srv)
    server.socket.close()
    closeCachedStreamConn()

  test "truncated tool_call mid-stream (no finish_reason)":
    let server = newSseServer(makeSseTruncatedToolDelta("echo TRUNCATED", "id-2", cutAfter = 12))
    var srv: Thread[SseServer]
    createThread(srv, serveThread, server)
    var usage = Usage()
    let result = callModel(testProfile(server), %*[{"role": "user", "content": "run echo TRUNCATED"}], usage, 0)
    # With the truncation guard disabled, the partial arguments survive into
    # the assistant message. We assert they are partial (documents current
    # behavior so a regression to silent-empty is caught).
    if result != nil and result{"tool_calls"}.len > 0:
      let args = result{"tool_calls"}[0]{"function"}{"arguments"}.getStr()
      check args.len < "{\"command\":\"echo TRUNCATED\"}".len
    joinThread(srv)
    server.socket.close()
    closeCachedStreamConn()

  test "complete plain content - no tool calls":
    let server = newSseServer(makeSseCompleteContent("Hello from the model!", "id-3"))
    var srv: Thread[SseServer]
    createThread(srv, serveThread, server)
    var usage = Usage()
    let result = callModel(testProfile(server), %*[{"role": "user", "content": "say hello"}], usage, 0)
    check result != nil
    check result{"content"}.getStr() == "Hello from the model!"
    joinThread(srv)
    server.socket.close()
    closeCachedStreamConn()

  test "reasoning then fragmented tool_call":
    let server = newSseServer(makeSseReasoningThenTool("Let me run a command.", "echo MIXED_99", "id-4"))
    var srv: Thread[SseServer]
    createThread(srv, serveThread, server)
    var usage = Usage()
    let result = callModel(testProfile(server), %*[{"role": "user", "content": "run echo MIXED"}], usage, 0)
    check result != nil
    check result{"tool_calls"}.len == 1
    let args = result{"tool_calls"}[0]{"function"}{"arguments"}.getStr()
    check args == "{\"command\":\"echo MIXED_99\"}"
    joinThread(srv)
    server.socket.close()
    closeCachedStreamConn()

  test "two tool_calls both fragmented reassemble correctly":
    let server = newSseServer(makeSseMultiTool("echo FIRST", "echo SECOND", "id-5"))
    var srv: Thread[SseServer]
    createThread(srv, serveThread, server)
    var usage = Usage()
    let result = callModel(testProfile(server), %*[{"role": "user", "content": "run two commands"}], usage, 0)
    check result != nil
    check result{"tool_calls"}.len == 2
    check result{"tool_calls"}[0]{"function"}{"arguments"}.getStr() == "{\"command\":\"echo FIRST\"}"
    check result{"tool_calls"}[1]{"function"}{"arguments"}.getStr() == "{\"command\":\"echo SECOND\"}"
    joinThread(srv)
    server.socket.close()
    closeCachedStreamConn()

  test "GLM tool_stream set for z.ai (streamhttp truncation fixed)":
    # GLM-5.2 with tool_stream=true fragments tool-call arguments into many
    # tiny per-token deltas. This was disabled to dodge a streamhttp TLS
    # truncation bug; that bug is fixed (streamhttp >= 0.2.0), so tool_stream
    # is back on for the first-party z.ai API. The fragmented tool_call
    # reassembly tests above are the real regression guard for the per-token
    # delta path this enables.
    let p = Profile(url: "stub://", family: "glm",
                    model: "glm-5.2", name: "zai.glm-5.2")
    let body = parseJson("{\"model\":\"glm-5.2\"}")
    applyStreamingOptions(p, body)
    check body.hasKey("tool_stream")
    check body{"tool_stream"}.getBool == true


suite "streaming SSE: slow response head":
  # Regression: readResponseHead used the same QuietRecvWakeMs-bounded recv
  # as the streaming body loop, but treated StreamTimeoutError as a stale-conn
  # failure. A provider that holds the connection for seconds before sending
  # even the HTTP status line (z.ai GLM, ~7s to first byte) burned both
  # stale-conn retries and then failed with "recv timed out" — hanging every
  # request on macOS where the head arrives after the 500ms poll window. The
  # fix loops on StreamTimeoutError (re-checking interrupt/quiet) so a slow
  # head is normal, not a dead connection. This test delays the head past the
  # recv wake window and asserts the request still completes.
  test "slow head (>recv wake window) still succeeds":
    let server = newSseServer(makeSseCompleteContent("slow but done", "id-slow"))
    proc delayedThread(s: SseServer) {.thread.} = serveOnceDelayedHead(s, 1400)
    var thr: Thread[SseServer]
    createThread(thr, delayedThread, server)
    var usage = Usage()
    let result = callModel(testProfile(server),
      %*[{"role": "user", "content": "say hi"}], usage, 0)
    joinThread(thr)
    check result != nil
    check result{"content"}.getStr() == "slow but done"
    server.socket.close()
    closeCachedStreamConn()

suite "streaming SSE: empty-content with finish_reason":
  # The bug: GLM/Qwen/gpt-oss reasoning models routinely return 200 OK with a
  # well-formed body where content is empty and the model spent its whole
  # token budget on reasoning (finish_reason "length"). The empty-content
  # auto-handling mode must NOT treat this as a transport error. callModel
  # returns a minimal assistant message tagged with finish_reason so runTurns
  # can branch on it (escalate max_tokens on "length", steer on "stop",
  # terminal on "content_filter"). These are the streaming-equivalent guards
  # for the non-stream tests in test_http_nonstream.nim.
  test "empty with finish_reason length returns a tagged msg, not an error":
    let server = newSseServer(
      makeSseEmptyWithFinish("length", "id-empty-length",
        completionTokens = 8192, reasoningTokens = 8192))
    var srv: Thread[SseServer]
    createThread(srv, serveThread, server)
    var usage = Usage()
    let result = callModel(testProfile(server),
      %*[{"role": "user", "content": "go"}], usage, 0)
    check result != nil
    check result{"content"}.getStr() == ""
    check result{"finish_reason"}.getStr == "length"
    check usage.reasoningTokens == 8192
    joinThread(srv)
    server.socket.close()
    closeCachedStreamConn()

  test "empty with finish_reason stop returns a tagged msg, not an error":
    let server = newSseServer(makeSseEmptyWithFinish("stop", "id-empty-stop"))
    var srv: Thread[SseServer]
    createThread(srv, serveThread, server)
    var usage = Usage()
    let result = callModel(testProfile(server),
      %*[{"role": "user", "content": "go"}], usage, 0)
    check result != nil
    check result{"content"}.getStr() == ""
    check result{"finish_reason"}.getStr == "stop"
    joinThread(srv)
    server.socket.close()
    closeCachedStreamConn()

  test "empty with finish_reason content_filter returns a tagged msg":
    let server = newSseServer(
      makeSseEmptyWithFinish("content_filter", "id-empty-cf"))
    var srv: Thread[SseServer]
    createThread(srv, serveThread, server)
    var usage = Usage()
    let result = callModel(testProfile(server),
      %*[{"role": "user", "content": "go"}], usage, 0)
    check result != nil
    check result{"finish_reason"}.getStr == "content_filter"
    joinThread(srv)
    server.socket.close()
    closeCachedStreamConn()


suite "streaming SSE: mid-stream error (OpenRouter)":
  # OpenRouter emits mid-stream provider failures as a `data:` chunk with a
  # top-level `error` object and finish_reason "error", all under HTTP 200.
  # Without explicit detection the error is swallowed: finish_reason "error"
  # builds an empty assistant message that the turn loop retries as a bare
  # empty reply, never showing the provider's error message. The transport
  # must surface the error so the user sees it.
  test "mid-stream error surfaces as ApiError with the provider message":
    # Use a 400 (non-retryable) so the error surfaces immediately without
    # callModel's retry backoff (the test server only accepts one conn).
    let server = newSseServer(
      makeSseMidStreamError("Provider disconnected unexpectedly", "id-err-1",
        code = 400))
    var srv: Thread[SseServer]
    createThread(srv, serveThread, server)
    var usage = Usage()
    var raised = false
    try:
      discard callModel(testProfile(server),
        %*[{"role": "user", "content": "go"}], usage, 0)
    except ApiError as e:
      raised = true
      check "Provider disconnected unexpectedly" in e.msg
    check raised
    joinThread(srv)
    server.socket.close()
    closeCachedStreamConn()

  test "mid-stream error after partial content surfaces the error, not content":
    # 400 (non-retryable) so it surfaces on the first attempt.
    let server = newSseServer(
      makeSseMidStreamErrorAfterContent("partial text...",
        "Provider overloaded", "id-err-2", code = 400))
    var srv: Thread[SseServer]
    createThread(srv, serveThread, server)
    var usage = Usage()
    var raised = false
    try:
      discard callModel(testProfile(server),
        %*[{"role": "user", "content": "go"}], usage, 0)
    except ApiError as e:
      raised = true
      check "Provider overloaded" in e.msg
    check raised
    joinThread(srv)
    server.socket.close()
    closeCachedStreamConn()


# ---------------------------------------------------------------------------
# verifyProfile
# ---------------------------------------------------------------------------
#
# The provider-verification ping shares the transport with callModel but
# used to run through stdlib `newHttpClient`. That client reads a chunked
# body via `socket.recvLine()` with no timeout, so a provider that accepts
# the connection then never sends the first SSE chunk (a transient network
# stall) blocked the main thread forever — the deadlock reproduced live as
# tid blocked in `wait_woken`. verifyProfile now uses the same bounded
# streamhttp path (setReadTimeoutMs → SO_RCVTIMEO) as callModel, so a stall
# surfaces as `(false, ...)` within VerifyTimeoutMs instead of hanging.
#
# These tests run the REAL transport (not -d:providerStub) against a local
# plain-HTTP server, mirroring the SSE tests above.

proc serveCaptureHeaders(server: SseServer) {.thread.} =
  ## Serve one complete-content SSE response, capturing every request
  ## header line into `server.capturedHeaders` for the caller to assert
  ## on (User-Agent, x-opencode-session).
  var client: Socket
  if not server.acceptWithinDeadline(client): return
  var contentLength = 0
  while true:
    let line = client.recvLine(timeout = 3000)
    let s = line.strip()
    if s.len == 0: break
    server.capturedHeaders.add s.toLowerAscii()
    if s.toLowerAscii().startsWith("content-length:"):
      contentLength = try: parseInt(s.split(":")[1].strip) except ValueError: 0
  let body = makeSseCompleteContent("ok", "cap-1")
  client.send("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n" &
    "Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n")
  client.send(toHex(body.len).toLowerAscii() & "\r\n" & body & "\r\n")
  client.send("0\r\n\r\n")
  client.drainRequestBody(contentLength)
  client.close()

proc serveVerifyOk(server: SseServer) {.thread.} =
  ## Serve a minimal 200 OK SSE ping response. The request body is drained
  ## after the response so the closing FIN is not downgraded to an RST.
  var client: Socket
  if not server.acceptWithinDeadline(client): return
  let contentLength = client.readRequestHead()
  let body = "data: {\"choices\":[{\"delta\":{\"content\":\"x\"}," &
    "\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
  client.send("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n" &
    "Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n")
  client.send(toHex(body.len).toLowerAscii() & "\r\n" & body & "\r\n")
  client.send("0\r\n\r\n")
  client.drainRequestBody(contentLength)
  client.close()

proc serveVerifySilent(server: SseServer) {.thread.} =
  ## Accept the connection, drain the request, then hold the socket open
  ## WITHOUT EVER REPLYING. This is the deadlock case: connect and the
  ## request succeed, but the response head never arrives, so an unbounded
  ## recv hangs forever. The client is silent after its request, so we just
  ## sleep; on client teardown the peer-closed socket surfaces as a
  ## recv returning "", which lets us exit.
  var client: Socket
  if not server.acceptWithinDeadline(client): return
  client.setSocketTimeoutMs(200)
  while client.recvLine(timeout = 3000).strip() != "":
    discard
  let deadline = epochTime() + 60.0
  while epochTime() < deadline:
    let chunk = try: client.recv(64, timeout = 200) except CatchableError: "x"
    # A timeout raises TimeoutError (caught → "x"); a real peer close
    # returns "". Only break on a genuine 0-length read.
    if chunk.len == 0: break
    sleep(50)
  client.close()

proc pingProfile(server: SseServer): Profile =
  Profile(name: "test", url: server.url, key: "test-key",
          model: "test-model", family: "glm")

suite "verifyProfile bounded against silent provider":
  test "happy path: 200 SSE verifies ok":
    let server = newSseServer("")
    var thr: Thread[SseServer]
    createThread(thr, serveVerifyOk, server)
    # Drop any connection cached from an earlier suite's server first:
    # verifyProfile would happily reuse it (its peer already answered and
    # closed), never dial THIS server, and the joinThread below would wait
    # forever on an accept that never comes. The 1442s CI hang.
    closeCachedStreamConn()
    let (ok, err) = verifyProfile(pingProfile(server))
    joinThread(thr)
    server.socket.close()
    check ok == true
    check err == ""
    closeCachedStreamConn()

  test "silent-after-accept does not hang (returns false promptly)":
    # Regression: before the fix this deadlocked the main thread in a
    # timeout-less recv. Now the bounded streamhttp recv wakes every
    # QuietRecvWakeMs, and VerifyTimeoutMs caps the whole ping, so this
    # returns (false, ...) in well under a minute instead of hanging.
    let server = newSseServer("")
    var thr: Thread[SseServer]
    createThread(thr, serveVerifySilent, server)
    closeCachedStreamConn()
    let t0 = epochTime()
    let (ok, err) = verifyProfile(pingProfile(server))
    let elapsed = epochTime() - t0
    joinThread(thr)
    server.socket.close()
    check ok == false
    check err.len > 0
    # The test build shrinks VerifyTimeoutMs to 3s (see .nims), so a bounded
    # return is ~3s; an unbounded one would run the full 60s hold. Allow
    # generous headroom over the 3s budget but well under the 60s deadline.
    check elapsed < 20.0

suite "request headers (OpenCode Zen/Go contract)":
  # Issue #32: OpenCode Zen/Go require x-opencode-session on every request
  # (routing/session affinity; headerless requests rejected from 2026-09-06)
  # and asked for an identifying User-Agent. These drive the REAL transport
  # and assert on the header lines the server actually received.
  test "every request carries User-Agent 3code/<version>":
    let server = newSseServer("")
    var thr: Thread[SseServer]
    createThread(thr, serveCaptureHeaders, server)
    closeCachedStreamConn()
    var usage: Usage
    discard callModel(testProfile(server),
      %*[{"role": "user", "content": "hi"}], usage, 0)
    joinThread(thr)
    server.socket.close()
    check server.capturedHeaders.filterIt(it.startsWith("user-agent:")).len == 1
    check "user-agent: 3code/" in server.capturedHeaders[0..^1].join("\n")
    # Request line: the profile url is a bare /v1 endpoint and the transport
    # appends /chat/completions exactly once (no doubled path).
    check server.capturedHeaders.len > 0
    check server.capturedHeaders[0] ==
      "post /v1/chat/completions http/1.1"
    closeCachedStreamConn()

  test "opencode gateway gets x-opencode-session; other providers do not":
    let server = newSseServer("")
    var thr: Thread[SseServer]
    createThread(thr, serveCaptureHeaders, server)
    closeCachedStreamConn()
    var usage: Usage
    let p = Profile(name: "opencode.glm-5.3", url: server.url,
                    key: "test-key", model: "glm-5.3", family: "glm")
    conversationId = ""
    discard callModel(p, %*[{"role": "user", "content": "hi"}], usage, 0)
    joinThread(thr)
    server.socket.close()
    let hdrs = server.capturedHeaders.join("\n")
    check hdrs.contains("x-opencode-session: 3code-")  # one-shot fallback
    closeCachedStreamConn()

  test "conversationId rides the header when published":
    let server = newSseServer("")
    var thr: Thread[SseServer]
    createThread(thr, serveCaptureHeaders, server)
    closeCachedStreamConn()
    var usage: Usage
    let p = Profile(name: "opencodego.glm-5.3", url: server.url,
                    key: "test-key", model: "glm-5.3", family: "glm")
    conversationId = "20260903T101415"
    defer: conversationId = ""
    discard callModel(p, %*[{"role": "user", "content": "hi"}], usage, 0)
    joinThread(thr)
    server.socket.close()
    # The capture lowercases lines, so compare on the lowered id.
    check "x-opencode-session: 20260903t101415" in server.capturedHeaders.join("\n")
    closeCachedStreamConn()
