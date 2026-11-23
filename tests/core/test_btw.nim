## `:btw` asks the model a side question about the conversation: one
## meta-call over the live history, the answer displayed to the user only.
## Neither the question nor the answer may enter `messages` — that is the
## whole feature — so these tests pin the payload shape, the untouched
## history, and the command wiring against a local HTTP server. The call
## runs on a worker thread (a system command never blocks the prompt), so
## the tests also pin the async contract: the command returns a receipt
## while the answer is still in flight, and the reply (answer plus burned
## tokens) is drained from the job.
import std/[json, strutils, unittest]
import std/net except send
from std/nativesockets import selectRead
import std/atomics
import threecode/[api, btwthread, compact, display, fatprompt, minline,
                  turns, types, ui, util]

when defined(posix):
  import std/posix except SocketHandle

type
  BtwSrv = ref object
    listener: Socket
    stop: bool
    gate: Atomic[bool]  # false holds every response until the test flips it
    payloads: seq[string]  # request bodies, in arrival order
    failFirst: Atomic[int]  # answer this many requests with a 503 first
    thread: Thread[BtwSrv]  # inside the ref: the OS trampoline keeps a
                           # pointer to this object, so it must not move

proc send(client: Socket; data: string) =
  # flags = {}: raise on a client that already hung up instead of std/net's
  # EPIPE retry spin (nim-lang/Nim#23455).
  net.send(client, data, flags = {})

proc serve(s: BtwSrv) {.thread.} =
  # selectRead, not SO_RCVTIMEO on the listener: accept(2) ignores that
  # option on macOS, so a timeout-wrapped accept parks forever there and
  # stopBtwSrv's joinThread hangs (the 720s OSX watchdog kill; same trap
  # acceptWithinDeadline in tests/stream/test_streaming_sse.nim records).
  {.cast(gcsafe).}:
    while not s.stop:
      try:
        var fds = @[s.listener.getFd]
        if selectRead(fds, 200) == 0:
          continue  # nothing dialed in: re-check `stop`
      except OSError:
        continue
      var client: Socket
      try:
        s.listener.accept(client)
      except CatchableError:
        continue
      try:
        var contentLength = 0
        while true:
          let line = client.recvLine(5000)
          if line.len == 0 or line.strip.len == 0: break
          if line.toLowerAscii.startsWith("content-length:"):
            contentLength = parseInt(line.split(":")[1].strip)
        var body = ""
        while body.len < contentLength:
          let chunk = client.recv(min(4096, contentLength - body.len))
          if chunk.len == 0: break
          body.add chunk
        if body.len == 0: continue
        s.payloads.add body
        # Gate: the test releases the response to observe the command
        # returning while the answer is still in flight. Bounded so a
        # forgotten flip cannot wedge the suite.
        # posix sleep (re-exported here) counts whole seconds, so the
        # bound is ten one-second polls, not the 10_000ms it pretends to be.
        var waited = 0
        while not s.gate.load(moAcquire) and waited < 10:
          discard sleep(1)
          inc waited
        if s.failFirst.load(moAcquire) > 0:
          discard s.failFirst.fetchSub(1, moAcquire)
          let err = """{"error":"overloaded"}"""
          send(client, "HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\nRetry-After: 1\r\n" &
            "Content-Length: " & $err.len & "\r\nConnection: close\r\n\r\n" &
            err)
          continue
        let reply = """{"choices":[{"message":{"role":"assistant","content":"SIDE ANSWER"}}],"usage":{"prompt_tokens":11,"completion_tokens":7,"total_tokens":18}}"""
        send(client, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" &
          "Content-Length: " & $reply.len & "\r\nConnection: close\r\n\r\n" &
          reply)
      except CatchableError:
        discard
      finally:
        try: client.close() except OSError: discard

type BtwHarness = tuple[srv: BtwSrv, prof: Profile]

proc startBtwSrv(): BtwHarness =
  let s = BtwSrv(listener: newSocket())
  s.gate.store(true, moRelease)
  s.listener.setSockOpt(OptReuseAddr, true)
  s.listener.bindAddr(Port(0), "127.0.0.1")
  s.listener.listen()
  let (_, port) = s.listener.getLocalAddr()
  createThread(s.thread, serve, s)
  # Provider name with a dot but not openai/chatgpt, so the meta-call takes
  # the /chat/completions branch the canned reply above speaks.
  result = (s, Profile(name: "test.provider", url: "http://127.0.0.1:" &
    $port.uint16, key: "k", model: "stub-chat"))

proc stopBtwSrv(h: BtwHarness) =
  h.srv.stop = true
  joinThread(h.srv.thread)
  try: h.srv.listener.close() except OSError: discard

proc history(): JsonNode =
  result = %* [
    {"role": "system", "content": "sysprompt"},
    {"role": "user", "content": "read foo.nim"},
    {"role": "assistant", "content": "foo.nim has 3 procs"},
  ]

suite ":btw side questions":
  test "classification and prefix resolution":
    check canonicalCommandName(":btw") == (":btw", "")
    check canonicalCommandName(":b") == (":btw", "")
    check classifyCommand(":btw") == ckSafeImmediate
    check classifyCommand(":btw why?") == ckMutating
    check classifyCommand(":b why?") == ckMutating

  test "bare :btw is a usage hint":
    var messages = history()
    var session = Session()
    var prof = Profile()
    var editor: LineEditor
    let r = handleCommandResult(":btw", messages, session, prof, editor)
    check r.recognized and not r.ok
    check "usage: :btw" in r.body
    check messages.len == 3

  test ":btw without a provider fails like :summarize":
    var messages = history()
    var session = Session()
    var prof = Profile()
    var editor: LineEditor
    let r = handleCommandResult(":btw why?", messages, session, prof, editor)
    check r.recognized and not r.ok
    check "no provider configured" in r.body
    check btwJobsLive() == 0

  test "askBtw payload: aside prompt, live history, trailing question":
    let h = startBtwSrv()
    defer: stopBtwSrv(h)
    var messages = history()
    let before = $messages
    let reply = askBtw("what did foo.nim have?", messages, h.prof)
    check reply.answer == "SIDE ANSWER"
    # The burned tokens come back with the answer for the session ledger.
    check reply.usage.promptTokens == 11
    check reply.usage.completionTokens == 7
    check reply.usage.totalTokens == 18
    # The live conversation is the caller's, byte for byte.
    check $messages == before
    check h.srv.payloads.len == 1
    let sent = parseJson(h.srv.payloads[0])
    let msgs = sent["messages"]
    check msgs.len == 4
    check msgs[0]{"role"}.getStr == "system"
    check msgs[0]{"content"}.getStr == BtwSystemPrompt
    check msgs[1]{"content"}.getStr == "read foo.nim"
    check msgs[2]{"content"}.getStr == "foo.nim has 3 procs"
    check msgs[3]{"role"}.getStr == "user"
    check msgs[3]{"content"}.getStr == "what did foo.nim have?"
    check sent["model"].getStr == h.prof.model
    check sent["max_tokens"].getInt == BtwMaxTokens

  test "meta-call carries the family reasoning knob":
    # Regression: the meta-call used to omit the per-family reasoning
    # wire mapping the main turn sends. On forced-thinking GLM-5.3 the
    # omission starved the whole token budget into reasoning and :btw
    # came back with "no answer" every time.
    let h = startBtwSrv()
    defer: stopBtwSrv(h)
    var prof = h.prof
    prof.family = "glm"
    prof.model = "glm-5.3"
    prof.version = "5"
    prof.variant = "3"
    prof.reasoning = "high"
    var messages = history()
    discard askBtw("why?", messages, prof)
    check h.srv.payloads.len == 1
    let sent = parseJson(h.srv.payloads[0])
    check sent{"reasoning_effort"}.getStr == "high"

  test "command returns at once; the answer arrives when the worker lands":
    # The dev-guidelines contract: a system command never blocks. The
    # server holds its response; the command must already have returned
    # its receipt, with the question in flight on a worker thread.
    let h = startBtwSrv()
    defer: stopBtwSrv(h)
    h.srv.gate.store(false, moRelease)
    var messages = history()
    var session = Session()
    var prof = h.prof
    var editor: LineEditor
    let r = handleCommandResult(":btw what did foo.nim have?", messages,
                                session, prof, editor)
    check r.recognized and r.ok
    check r.name == "btw"
    check "SIDE ANSWER" notin r.body
    # No receipt line: the controller echoes the question itself as the
    # `?`-led item (the goal kickoff's shape).
    check r.body == ""
    check r.btwQuestion == "what did foo.nim have?"
    check btwJobsLive() == 1
    h.srv.gate.store(true, moRelease)
    var replies: seq[BtwReply]
    waitBtw(replies, 10_000)
    check btwJobsLive() == 0
    check replies.len == 1
    check replies[0].answer == "SIDE ANSWER"
    check replies[0].usage.totalTokens == 18
    # The contract: no question, no answer, nothing new in the context —
    # before and after delivery alike.
    check messages.len == 3
    check messages[0]{"content"}.getStr == "sysprompt"
    check messages[^1]{"content"}.getStr == "foo.nim has 3 procs"
    # ...and the request carried the question as a trailing user message,
    # not as an edit of the shared history.
    let sent = parseJson(h.srv.payloads[0])
    check sent["messages"].len == 4
    check sent["messages"][^1]{"content"}.getStr == "what did foo.nim have?"

  test "the aside's tokens land on the session and the summed bar":
    # The turn's own call spent 100/20 (already ledgered, carried inline
    # by the last assistant message); the aside spends 11/7 more. The bar
    # the session rests on is the SUM of both requests, not the aside's
    # numbers in place of the turn's.
    var session: Session
    session.savePath = ""
    session.usage = Usage(promptTokens: 100, completionTokens: 20,
      totalTokens: 120, cachedTokens: 0)
    var messages = %*[
      {"role": "user", "content": "go"},
      {"role": "assistant", "content": "done",
       "usage": {"promptTokens": 100, "completionTokens": 20,
                  "totalTokens": 120, "cachedTokens": 0}}]
    # The streamed-reply turn end consumed the pending hint into its
    # receipt, so the idle prompt's delivery falls back to the wire's
    # inline usage - the same shape a real :btw answer arrives in.
    emitFatPromptEvent clearPendingHintEvent()
    accountSideCallUsage(session, messages,
      Usage(promptTokens: 11, completionTokens: 7, totalTokens: 18), 1_000)
    check session.usage.promptTokens == 111
    check session.usage.completionTokens == 27
    check session.usage.totalTokens == 138
    check fatPromptState.footer.barLabel ==
      contextLabel(111, 1_000) & "  ↑111  ↓27"
    check fatPromptState.footer.restingLabel == contextLabel(111, 1_000)

  test "the answer renders as a dim icon-led quote block":
    # `?` asked, `!` answers: the aside's icons are the question mark
    # and the exclamation mark.
    check BtwQuestionIcon == "?"
    check BtwIcon == "!"
    let bytes = btwAnswerBytes("first line\nsecond line")
    check bytes.contains(GreyFg & BtwIcon & Reset & " ")
    check bytes.contains(GreyFg)
    check "first line" in bytes
    check "second line" in bytes
    check btwAnswerBytes("   ") == ""
    let cancelled = btwCancelledBytes()
    check cancelled.contains(BtwIcon)
    check cancelled.contains(InterruptedByUserMsg)

  test "the aside retries a 503 like a main request":
    # Two 503s, then the answer: the worker's curve takes both failures
    # and lands the third attempt's reply as one delivered aside.
    let h = startBtwSrv()
    defer: stopBtwSrv(h)
    h.srv.failFirst.store(2, moRelease)
    check startBtw("what did foo.nim have?", history(), h.prof)
    var replies: seq[BtwReply]
    waitBtw(replies, 30_000)
    check btwJobsLive() == 0
    check h.srv.payloads.len == 3
    check replies.len == 1
    check not replies[0].cancelled
    check replies[0].answer == "SIDE ANSWER"
    check replies[0].usage.totalTokens == 18

  test "an interrupt cancels the aside instead of leaving it unanswered":
    # The server holds its response; the interrupt lands mid-call. The
    # poll delivers the cancellation at once (the question's `?` item
    # gets its `! interrupted by user` row) and the registry is clear,
    # so a later aside's answer never queues behind the abandoned call.
    let h = startBtwSrv()
    defer: stopBtwSrv(h)
    h.srv.gate.store(false, moRelease)
    check startBtw("what did foo.nim have?", history(), h.prof)
    requestTurnInterrupt("test")
    defer: clearInterrupted()
    var replies: seq[BtwReply]
    pollBtw(replies)
    check replies.len == 1
    check replies[0].cancelled
    check replies[0].answer == ""
    check btwJobsLive() == 0
    # A fresh aside started under the interrupt is not cancelled by it:
    # the stale flag must not read as a new interrupt.
    h.srv.gate.store(true, moRelease)
    check startBtw("and now?", history(), h.prof)
    replies.setLen 0
    waitBtw(replies, 30_000)
    check replies.len == 1
    check not replies[0].cancelled
    check replies[0].answer == "SIDE ANSWER"
    # The abandoned worker is released by its own timeout handshake and
    # freed on a later poll.
    h.srv.gate.store(true, moRelease)
    for _ in 0 ..< (BtwReapWaitMs div 1000 + 4):
      replies.setLen 0
      pollBtw(replies)
      if btwRetiredLive() == 0: break
      discard sleep(1)
    check btwRetiredLive() == 0

  test "btwContext flattens the tool exchange to prose":
    # The meta-call carries no tools parameter: replayed tool_calls made
    # the model answer with tool calls of its own (an empty content, i.e.
    # no answer). Prose survives, calls and results become bracketed
    # lines, and the live history is untouched.
    let messages = %* [
      {"role": "system", "content": "sysprompt"},
      {"role": "user", "content": "list the files"},
      {"role": "assistant", "content": "naming them", "tool_calls": [
        {"id": "c1", "type": "function", "function":
          {"name": "bash", "arguments": "{\"command\":\"ls\"}"}}]},
      {"role": "tool", "tool_call_id": "c1", "name": "bash", "content": "a.nim"},
      {"role": "assistant", "content": "there is one file"},
    ]
    let before = $messages
    let ctx = btwContext(messages)
    check ctx.len == 5
    check ctx[0] == messages[0]
    check ctx[1] == messages[1]
    check ctx[2]{"tool_calls"} == nil
    check ctx[2]{"content"}.getStr == "naming them\n[tool call: bash {\"command\":\"ls\"}]"
    check ctx[3]{"role"}.getStr == "user"
    check ctx[3]{"tool_call_id"} == nil
    check ctx[3]{"content"}.getStr == "[tool result]\na.nim"
    check ctx[4]{"content"}.getStr == "there is one file"
    # An argument longer than the cap is cut, a silent tool-call turn
    # gets its bracket line alone.
    let long = repeat("x", BtwCallArgChars + 50)
    let silent = %*[
      {"role": "assistant", "content": "", "tool_calls": [
        {"id": "c2", "type": "function", "function":
          {"name": "write", "arguments": long}}]}]
    let flat = btwContext(silent)
    check flat[0]{"content"}.getStr == "[tool call: write " &
      long[0 ..< BtwCallArgChars] & "...]"
    check $messages == before
