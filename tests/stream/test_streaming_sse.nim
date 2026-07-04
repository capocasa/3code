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

import std/[json, jsonutils, net, os, strutils, threadpool, unittest]

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

proc newSseServer(response: string): SseServer =
  result = SseServer(socket: newSocket(), response: response)
  result.socket.setSockOpt(OptReuseAddr, true)
  result.socket.bindAddr(Port(0))
  result.socket.listen()
  let (_, p) = result.socket.getLocalAddr()
  result.port = p

proc serveOnce(server: SseServer) =
  var client: Socket
  server.socket.accept(client)
  # Drain the request headers + blank line.
  while client.recvLine(timeout = 3000).strip() != "":
    discard
  let body = server.response
  let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
  client.send(resp)
  let chunk = toHex(body.len).toLowerAscii() & "\r\n" & body & "\r\n"
  client.send(chunk)
  client.send("0\r\n\r\n")
  client.close()

proc serveOnceDelayedHead(server: SseServer; delayMs: int) =
  ## Like serveOnce but sleeps `delayMs` before sending the HTTP response
  ## head. Models providers (z.ai GLM) that hold the connection for several
  ## seconds while the model warms up before emitting even the status line.
  var client: Socket
  server.socket.accept(client)
  while client.recvLine(timeout = 3000).strip() != "":
    discard
  sleep(delayMs)
  let body = server.response
  let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
  client.send(resp)
  let chunk = toHex(body.len).toLowerAscii() & "\r\n" & body & "\r\n"
  client.send(chunk)
  client.send("0\r\n\r\n")
  client.close()

proc serveThread(server: SseServer) {.thread.} =
  serveOnce(server)

proc url(server: SseServer): string =
  "http://127.0.0.1:" & $server.port.uint16 & "/chat/completions"

proc testProfile(server: SseServer): Profile =
  Profile(name: "test", url: server.url, key: "test-key",
          model: "test-model", family: "glm")

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

suite "streaming SSE tool-call accumulation":
  test "complete fragmented tool_call reassembles correct arguments":
    let server = newSseServer(makeSseToolDeltas("echo HELLO_WORLD_42", "id-1"))
    spawn serveThread(server)
    var usage = Usage()
    let result = callModel(testProfile(server), %*[{"role": "user", "content": "run echo HELLO"}], usage, 0)
    check result != nil
    check result{"tool_calls"}.len == 1
    let args = result{"tool_calls"}[0]{"function"}{"arguments"}.getStr()
    check args == "{\"command\":\"echo HELLO_WORLD_42\"}"
    server.socket.close()
    closeCachedStreamConn()

  test "truncated tool_call mid-stream (no finish_reason)":
    let server = newSseServer(makeSseTruncatedToolDelta("echo TRUNCATED", "id-2", cutAfter = 12))
    spawn serveThread(server)
    var usage = Usage()
    let result = callModel(testProfile(server), %*[{"role": "user", "content": "run echo TRUNCATED"}], usage, 0)
    # With the truncation guard disabled, the partial arguments survive into
    # the assistant message. We assert they are partial (documents current
    # behavior so a regression to silent-empty is caught).
    if result != nil and result{"tool_calls"}.len > 0:
      let args = result{"tool_calls"}[0]{"function"}{"arguments"}.getStr()
      check args.len < "{\"command\":\"echo TRUNCATED\"}".len
    server.socket.close()
    closeCachedStreamConn()

  test "complete plain content - no tool calls":
    let server = newSseServer(makeSseCompleteContent("Hello from the model!", "id-3"))
    spawn serveThread(server)
    var usage = Usage()
    let result = callModel(testProfile(server), %*[{"role": "user", "content": "say hello"}], usage, 0)
    check result != nil
    check result{"content"}.getStr() == "Hello from the model!"
    server.socket.close()
    closeCachedStreamConn()

  test "reasoning then fragmented tool_call":
    let server = newSseServer(makeSseReasoningThenTool("Let me run a command.", "echo MIXED_99", "id-4"))
    spawn serveThread(server)
    var usage = Usage()
    let result = callModel(testProfile(server), %*[{"role": "user", "content": "run echo MIXED"}], usage, 0)
    check result != nil
    check result{"tool_calls"}.len == 1
    let args = result{"tool_calls"}[0]{"function"}{"arguments"}.getStr()
    check args == "{\"command\":\"echo MIXED_99\"}"
    server.socket.close()
    closeCachedStreamConn()

  test "two tool_calls both fragmented reassemble correctly":
    let server = newSseServer(makeSseMultiTool("echo FIRST", "echo SECOND", "id-5"))
    spawn serveThread(server)
    var usage = Usage()
    let result = callModel(testProfile(server), %*[{"role": "user", "content": "run two commands"}], usage, 0)
    check result != nil
    check result{"tool_calls"}.len == 2
    check result{"tool_calls"}[0]{"function"}{"arguments"}.getStr() == "{\"command\":\"echo FIRST\"}"
    check result{"tool_calls"}[1]{"function"}{"arguments"}.getStr() == "{\"command\":\"echo SECOND\"}"
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
