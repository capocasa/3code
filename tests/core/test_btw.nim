## `:btw` asks the model a side question about the conversation: one
## meta-call over the live history, the answer displayed to the user only.
## Neither the question nor the answer may enter `messages` — that is the
## whole feature — so these tests pin the payload shape, the untouched
## history, and the command wiring against a local HTTP server. The call
## runs on a worker thread (a system command never blocks the prompt), so
## the tests also pin the async contract: the command returns a receipt
## while the answer is still in flight, and the reply (answer plus burned
## tokens) is drained from the job.
import std/[json, sequtils, strutils, unittest, times]
import std/os except sleep
import std/net except send
from std/nativesockets import selectRead
import std/atomics
import threecode/[api, btwthread, compact, display, fatprompt, minline,
                  session, transcript, turns, types, ui, util]

when defined(posix):
  import std/posix except SocketHandle

type
  BtwSrv = ref object
    listener: Socket
    stop: bool
    gate: Atomic[bool]  # false holds every response until the test flips it
    payloads: seq[string]  # request bodies, in arrival order
    failFirst: Atomic[int]  # answer this many requests with a 503 first
    dropFirstGated: bool  # close the first gated request instead of
                          # answering it: the interrupt test's abandoned
                          # call then ends by a plain EOF, the same end
                          # any real provider eventually forces, and the
                          # reap handshake stops depending on how the
                          # runner delivers the would-be reply
    thread: Thread[BtwSrv]  # inside the ref: the OS trampoline keeps a
                           # pointer to this object, so it must not move

proc srvTrace(s: BtwSrv; msg: string) =
  # Timestamped stderr beats for the server half of each handshake; CI
  # captures stderr in the testament log, so a stalled macOS runner names
  # the phase that never ran.
  stderr.writeLine("btwsrv: ", $epochTime(), " ", msg)
  stderr.flushFile()

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
      srvTrace(s, "accepted")
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
        srvTrace(s, "body " & $body.len & "B")
        # Gate: the test releases the response to observe the command
        # returning while the answer is still in flight. Bounded so a
        # forgotten flip cannot wedge the suite.
        # posix sleep (re-exported here) counts whole seconds, so the
        # bound is ten one-second polls, not the 10_000ms it pretends to be.
        var waited = 0
        while not s.gate.load(moAcquire) and waited < 10:
          discard sleep(1)
          inc waited
        srvTrace(s, "gate after " & $waited & " polls")
        if s.dropFirstGated and s.payloads.len == 1:
          # The abandoned aside: end its call here. A real provider
          # answers or drops it eventually; dropping keeps the handshake
          # under test off the runner's reply-delivery timing.
          srvTrace(s, "dropping the abandoned call")
          continue
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
        srvTrace(s, "replied 200")
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
  # the /chat/completions branch the canned reply above speaks. The family
  # names the tool roster the aside carries (the cache prefix's tools half).
  result = (s, Profile(name: "test.provider", url: "http://127.0.0.1:" &
    $port.uint16, key: "k", model: "stub-chat", family: "glm"))

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
    check classifyCommand(":btw why?") == ckSafeImmediate
    check classifyCommand(":b why?") == ckSafeImmediate

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

  test "askBtw payload: live system prompt, verbatim history, trailing question":
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
    check msgs[0]{"content"}.getStr == "sysprompt"
    check msgs[1]{"content"}.getStr == "read foo.nim"
    check msgs[2]{"content"}.getStr == "foo.nim has 3 procs"
    check msgs[3]{"role"}.getStr == "user"
    check msgs[3]{"content"}.getStr == BtwTrailingPrefix & "what did foo.nim have?"
    check sent["model"].getStr == h.prof.model
    check sent["max_tokens"].getInt == BtwMaxTokens
    # The cache contract: the profile's roster rides so the prefix matches
    # the main call's, but the model may call none of it.
    check sent["tools"].kind == JArray
    check sent["tools"].len > 0
    check sent["tool_choice"].getStr == "none"

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
    # The command only posts: it may be typed mid-turn, from the input
    # thread, which must not read the live history. The owner fires the
    # question at its next tick.
    check btwJobsLive() == 0
    check postedBtwLive() == 1
    for question in takePostedBtw():
      check question == "what did foo.nim have?"
      check startBtw(question, messages, prof)
    check postedBtwLive() == 0
    check btwJobsLive() == 1
    h.srv.gate.store(true, moRelease)
    var replies: seq[BtwReply]
    waitBtw(replies, 10_000)
    check btwJobsLive() == 0
    check replies.len == 1
    check replies[0].answer == "SIDE ANSWER"
    # The reply echoes its question so the `@?` reference can quote both.
    check replies[0].question == "what did foo.nim have?"
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
    check sent["messages"][^1]{"content"}.getStr.endswith("what did foo.nim have?")

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
    check bytes.contains(GreyFg & BtwIcon & Reset & GreyFg & "  ")
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
    h.srv.dropFirstGated = true
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
    # freed on a later poll. Its call ended with the server's drop (the
    # transport error funnels through the same cancel-check the reply
    # path uses), so what remains is the publish + BtwReapWaitMs handshake
    # and the freeing poll. Wall-clock deadline, not an iteration count:
    # on a loaded runner (macos-15) each poll+sleep pass stretches and the
    # counted loop expired before the reap landed (observed 2026-11).
    let reapDeadline = epochTime() + (BtwReapWaitMs.float / 1000.0) + 30.0
    while epochTime() < reapDeadline:
      replies.setLen 0
      pollBtw(replies)
      if btwRetiredLive() == 0: break
      discard sleep(20)
    check btwRetiredLive() == 0

  test "the aside context is the conversation's verbatim wire prefix":
    # A provider's prompt cache keys on the tools + messages prefix, so
    # the aside rides the live history through the same transforms as the
    # main call: system prompt, tool_calls and tool messages intact,
    # internal bookkeeping fields gone — anything else would re-bill the
    # whole history as fresh input. The old tools-less payload with a
    # flattened history missed the cache AND still invited tool-call
    # answers; here the roster rides but `tool_choice: "none"` forbids
    # the model to use it.
    let messages = %* [
      {"role": "system", "content": "sysprompt"},
      {"role": "user", "content": "list the files"},
      {"role": "assistant", "content": "naming them", "tool_calls": [
        {"id": "c1", "type": "function", "function":
          {"name": "bash", "arguments": "{\"command\":\"ls\"}"}}]},
      {"role": "tool", "tool_call_id": "c1", "name": "bash", "content": "a.nim"},
      {"role": "assistant", "content": "there is one file",
       "usage": {"promptTokens": 5, "completionTokens": 1,
                  "totalTokens": 6},
       "agentSent": true},
    ]
    let before = $messages
    let h = startBtwSrv()
    defer: stopBtwSrv(h)
    discard askBtw("what did ls show?", messages, h.prof)
    check h.srv.payloads.len == 1
    let sent = parseJson(h.srv.payloads[0])
    let msgs = sent["messages"]
    check msgs.len == 6
    check msgs[0]{"content"}.getStr == "sysprompt"
    check msgs[2]{"tool_calls"}[0]{"function"}{"name"}.getStr == "bash"
    check msgs[2]{"content"}.getStr == "naming them"
    check msgs[3]{"role"}.getStr == "tool"
    check msgs[3]{"tool_call_id"}.getStr == "c1"
    check msgs[3]{"content"}.getStr == "a.nim"
    # Wire-safe exactly like the main call's copy: the bookkeeping fields
    # never reach the provider.
    check "usage" notin msgs[4]
    check "agentSent" notin msgs[4]
    check msgs[4]{"content"}.getStr == "there is one file"
    check msgs[5]{"content"}.getStr == BtwTrailingPrefix & "what did ls show?"
    check sent["tool_choice"].getStr == "none"
    # The live history is the caller's, byte for byte.
    check $messages == before

  test "an oversized aside clips its own payload, never the live history":
    # The envelope guard clips the payload in place when the body busts
    # the gateway cap, and the verbatim context shares message nodes with
    # the caller's history — so the clip must land on copies only, or one
    # big session would eat its own messages out of the conversation.
    let big = repeat("x", 400 * 1024)
    let messages = %*[
      {"role": "system", "content": "sysprompt"},
      {"role": "user", "content": big},
      {"role": "assistant", "content": big},
    ]
    let h = startBtwSrv()
    defer: stopBtwSrv(h)
    discard askBtw("still there?", messages, h.prof)
    check h.srv.payloads.len == 1
    let sent = parseJson(h.srv.payloads[0])
    check "clipped for size" in sent["messages"][1]{"content"}.getStr
    # The live history is untouched: byte for byte what the caller held.
    check messages[1]{"content"}.getStr == big
    check messages[2]{"content"}.getStr == big

  test "on /responses the aside pins the conversation's cache key":
    # gh #58: first-party openai shards the prompt cache by
    # prompt_cache_key; the aside must land on the shard the main call
    # warmed, carrying the same flattened tools array (prefix content).
    let oldId = conversationId
    conversationId = "conv-cache-key"
    defer: conversationId = oldId
    let messages = %*[
      {"role": "system", "content": "sysprompt"},
      {"role": "user", "content": "go"}]
    let p = Profile(name: "openai.gpt", url: "https://api.openai.com/v1",
                    key: "k", model: "gpt-5.6", family: "gpt")
    let req = buildBtwRequest(p, messages, "why?")
    check req.endpoint == "https://api.openai.com/v1/responses"
    let body = parseJson(req.body)
    check body{"prompt_cache_key"}.getStr == "conv-cache-key"
    check body{"tool_choice"}.getStr == "none"
    # Responses flattens {type, function:{...}} to {type:"function", ...},
    # same as the main call's body.
    check body{"tools"}[0]{"name"}.getStr.len > 0
    check body{"tools"}[0]{"function"} == nil
    check body{"input"}.len == 3
    check body{"input"}[0]{"content"}.getStr == "sysprompt"
    check body{"input"}[2]{"content"}.getStr.endswith("why?")

suite ":btw asides in the .3log":
  # The aside's log records: the `?` question and the `!` answer ride the
  # .3log at their scrollback anchors so a resume replays them, and the
  # load adds nothing to `messages` - the aside never becomes context,
  # on initial add or on replay.

  test "btw records round-trip anchored, outside the message tree":
    let dir = getTempDir() / "btw_log_test_" & $getCurrentProcessId()
    createDir(dir)
    let path = dir / "20260302T120000" & SessionExt
    var session: Session
    session.savePath = path
    session.cwd = dir
    session.btwAsides.add BtwAsideRecord(after: 1, isQuestion: true,
      text: "why this?", usage: Usage())
    session.btwAsides.add BtwAsideRecord(after: 2, isQuestion: false,
      text: "because of this",
      usage: Usage(promptTokens: 11, completionTokens: 7,
                   totalTokens: 18, cachedTokens: 3))
    let messages = %*[
      {"role": "user", "content": "go"},
      {"role": "assistant", "content": "done"}]
    let text = renderSession(session, messages)
    check "btw_q" in text and "why this?" in text
    check "btw_a fresh=8 cached=3 out=7 hit=27%" in text
    # Record order is scrollback order: the `?` after the message it
    # anchored on (after=1: the user line), the `!` after the turn's
    # reply.
    check text.find("user") < text.find("btw_q")
    check text.find("btw_q") < text.find("assistant")
    check text.find("assistant") < text.find("btw_a")
    # No empty-usage header on the question; the answer's receipt rides
    # the header so replay can render the same receipt the live commit did.
    check "btw_q fresh" notin text
    writeFile(path, text)
    try:
      let (loaded, msgs) = loadSessionFile(path)
      # The asides never became messages: the loader's system backfill
      # aside, exactly the user/assistant pair saved above.
      check msgs.len == 3
      check msgs[0]{"role"}.getStr == "system"
      for m in msgs[1 .. ^1]:
        check m{"role"}.getStr in ["user", "assistant"]
      check loaded.btwAsides.len == 2
      check loaded.btwAsides[0].isQuestion
      check loaded.btwAsides[0].text == "why this?"
      check not loaded.btwAsides[1].isQuestion
      check loaded.btwAsides[1].text == "because of this"
      check loaded.btwAsides[1].usage.totalTokens == 18
      check loaded.btwAsides[1].usage.promptTokens == 11
      check loaded.btwAsides[1].usage.cachedTokens == 3
      # Re-render from the loaded session: byte-stable anchors.
      check renderSession(loaded, msgs) == text
    finally:
      removeDir(dir)

  test "the answer's receipt renders below the quote block":
    # Same styling any receipt uses: the canonical receiptBytes row.
    var bytes = btwAnswerBytes("because of this")
    bytes.attachReceipt(receiptBytes(tokenLineLabel(
      Usage(promptTokens: 11, completionTokens: 7, totalTokens: 18,
            cachedTokens: 3), 1_000)), true)
    check bytes.contains(BtwIcon)
    check "because of this" in bytes
    check bytes.contains(receiptBytes(tokenLineLabel(
      Usage(promptTokens: 11, completionTokens: 7, totalTokens: 18,
            cachedTokens: 3), 1_000)))
    check "↑8" in bytes and "↓7" in bytes
