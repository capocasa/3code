## One parameterized probe binary for test_api's subprocess tests.
##
## Each mode below used to be its own `probe.nim`, written to a temp dir and
## compiled at test time: 16 separate compiles of the whole source tree,
## ~300s for the file. The suite now compiles this file once (mode picked via
## argv) and runs `probe <mode>` with the scenario's stub_responses.json as
## the working directory.
import std/[json, locks, net, os, sequtils, strutils, times]
import threecode
import threecode/api except callModel
import threecode/[types, compact]

when defined(posix):
  import std/posix

  proc setSockTimeoutMs(sock: Socket; ms: int) =
    var tv: Timeval
    tv.tv_sec = posix.Time(ms div 1000)
    tv.tv_usec = Suseconds((ms mod 1000) * 1000)
    discard setsockopt(sock.getFd(), SOL_SOCKET, SO_RCVTIMEO,
                       addr tv, sizeof(tv).SockLen)

type
  BadServer = ref object
    sock: Socket
    running: bool
    rejectSummarizer: bool
    envelope: int
    port: int

# --- queued-input thread shared by the eight turn probes -------------------

var
  evKind = ieLine
  evText = ""
  evEchoed = false
  evEchoRows = 0
  evDelayMs = 0
  eventThread: Thread[void]

proc pushProbeEvent() {.thread, gcsafe.} =
  # Signal, not sleep: wait until the bash tool has actually started (its
  # marker file), so the queued line always lands inside the tool window
  # regardless of how loaded the machine is. The 30s bound turns "the
  # marker never appeared" (tool failed to run) into a fast queue that the
  # probe's assertions then fail loudly, instead of hanging the suite.
  let deadline = epochTime() + 30.0
  while not fileExists("started") and epochTime() < deadline:
    sleep 1
  if evDelayMs > 0:
    sleep(evDelayMs)
  {.cast(gcsafe).}:
    pushInputEvent(InputEvent(kind: evKind, text: evText,
                              echoed: evEchoed, echoRows: evEchoRows))

proc startQueuedEvent(kind: InputEventKind; text: string;
                      echoed = false; echoRows = 0; delayMs = 0) =
  evKind = kind
  evText = text
  evEchoed = echoed
  evEchoRows = echoRows
  evDelayMs = delayMs
  createThread(eventThread, pushProbeEvent)

proc joinQueuedEvent() =
  joinThread(eventThread)

type
  ProbeRun = object
    messages: JsonNode
    session: Session
    profile: Profile

proc newTurnRun(): ProbeRun =
  result.messages = %*[
    {"role": "system", "content": "sys"},
    {"role": "user", "content": "first"}
  ]
  result.session.savePath = ""
  result.session.readCache = newReadCache()
  result.profile = Profile(name: "stub", family: "glm", model: "stub-model")

proc newPromptRun(profile: Profile): ProbeRun =
  result.messages = %*[
    {"role": "system", "content": "sys"},
    {"role": "user", "content": "go"}
  ]
  result.session.savePath = ""
  result.session.readCache = newReadCache()
  result.profile = profile

# --- turn probes: an input event queued while a tool runs ------------------

proc autosend() =
  var r = newTurnRun()
  startQueuedEvent(ieLine, "queued", echoRows = 1)
  discard runTurns(r.profile, r.messages, r.session)
  joinQueuedEvent()

  let queued = hasQueuedAutosend()
  doAssert queued
  doAssert r.messages.len == 4
  doAssert r.messages[2]{"role"}.getStr == "assistant"
  doAssert r.messages[3]{"role"}.getStr == "tool"
  doAssert "SHOULD_NOT_BE_CALLED" notin $r.messages

proc syscmdYield() =
  # A deferred system command (`:!`, mutating `:cmd`) queued while a tool
  # runs must yield the turn at the tool boundary - but the yield has to be
  # distinguishable from a finished turn, or the drain that runs the
  # command strands the conversation on unanswered tool results until
  # the next prompt. `turnYieldedToQueue` is that signal.
  var r = newTurnRun()
  # An echoed ieCommand is a command deferred to the drain (what the input
  # thread queues for `:!`/mutating commands); the marker makes sure it
  # lands inside the tool window.
  startQueuedEvent(ieCommand, ":! echo syscmd", echoed = true, echoRows = 1)
  discard runTurns(r.profile, r.messages, r.session)
  joinQueuedEvent()

  doAssert hasQueuedAutosend(), "deferred command still queued"
  doAssert turnYieldedToQueue, "mid-loop yield must be flagged for the drain"
  doAssert r.messages.len == 4
  doAssert r.messages[3]{"role"}.getStr == "tool"
  doAssert "SECOND_REPLY" notin $r.messages

proc syscmdResume() =
  # The interactive drain's exact sequence, driven headlessly: the turn
  # yields at the tool boundary for the deferred command, the drain runs
  # it (a no-op here - its output never reaches the model anyway), then
  # sends the model back in. The follow-up call must happen and the
  # conversation must end on the assistant's reply, not on the dangling
  # tool result.
  var r = newTurnRun()
  startQueuedEvent(ieCommand, ":! echo syscmd", echoed = true, echoRows = 1)
  discard runTurns(r.profile, r.messages, r.session)
  joinQueuedEvent()

  # The drain (threecode.nim handleBufferedAfterTurn): run the deferred
  # command's event off the queue, then send the model back in because the
  # turn yielded mid-loop and was not interrupted.
  let ev = pollInputEvent()
  doAssert ev.kind == ieCommand and ev.echoed
  doAssert pollInputEvent().kind == ieNone
  let interrupted = false
  if not interrupted and turnYieldedToQueue and
      r.messages[^1]{"role"}.getStr == "tool":
    turnYieldedToQueue = false
    discard runTurns(r.profile, r.messages, r.session)

  doAssert not turnYieldedToQueue
  doAssert r.messages.len == 5
  doAssert r.messages[4]{"role"}.getStr == "assistant"
  doAssert "SECOND_REPLY" in r.messages[4]{"content"}.getStr
  doAssert "tooldone" in r.messages[3]{"content"}.getStr

proc syscmdInline() =
  var r = newTurnRun()
  # An un-echoed ieCommand is one that already ran inline via the command
  # hook (safe/unknown commands); only its event stays behind for the drain
  # to skip.
  startQueuedEvent(ieCommand, ":tokens")
  discard runTurns(r.profile, r.messages, r.session)
  joinQueuedEvent()

  doAssert not hasQueuedAutosend(), "inline command must not count as queued"
  doAssert not turnYieldedToQueue, "turn finished; it never yielded"
  doAssert r.messages.len == 5
  doAssert r.messages[4]{"role"}.getStr == "assistant"
  doAssert "SECOND_REPLY" in r.messages[4]{"content"}.getStr

proc autosendApi() =
  var r = newTurnRun()
  startQueuedEvent(ieLine, "queued", echoRows = 1)
  discard runTurns(r.profile, r.messages, r.session)
  joinQueuedEvent()

  let queued = hasQueuedAutosend()
  doAssert queued
  doAssert r.messages.len == 4
  doAssert r.messages[2]{"role"}.getStr == "assistant"
  doAssert r.messages[3]{"role"}.getStr == "tool"
  doAssert "SHOULD_RUN" in r.messages[3]{"content"}.getStr
  doAssert "skipped" notin r.messages[3]{"content"}.getStr
  doAssert "SHOULD_NOT_BE_CALLED" notin $r.messages

proc autosendBatch() =
  var r = newTurnRun()
  startQueuedEvent(ieLine, "queued", echoRows = 1)
  discard runTurns(r.profile, r.messages, r.session)
  joinQueuedEvent()

  let queued = hasQueuedAutosend()
  doAssert queued
  doAssert r.messages.len == 5
  doAssert r.messages[2]{"role"}.getStr == "assistant"
  doAssert r.messages[3]{"role"}.getStr == "tool"
  doAssert r.messages[4]{"role"}.getStr == "tool"
  doAssert "first-tool" in r.messages[3]{"content"}.getStr
  doAssert "second-tool" in r.messages[4]{"content"}.getStr
  doAssert "skipped" notin r.messages[4]{"content"}.getStr
  doAssert "SHOULD_NOT_BE_CALLED" notin $r.messages

proc cmdTombstone() =
  var r = newTurnRun()
  startQueuedEvent(ieCommand, ":tokens", delayMs = 50)
  discard runTurns(r.profile, r.messages, r.session)
  joinQueuedEvent()

  # The tombstone is still queued (the drain will skip it), and the turn ran
  # to completion: tool result paired, follow-up model call made, final
  # reply appended. Nothing was dropped early.
  doAssert hasQueuedAutosend() == false
  let ev = pollInputEvent()
  doAssert ev.kind == ieCommand and ev.text == ":tokens" and not ev.echoed
  doAssert r.messages.len == 5
  doAssert r.messages[2]{"role"}.getStr == "assistant"
  doAssert r.messages[3]{"role"}.getStr == "tool"
  doAssert "tooldone" in r.messages[3]{"content"}.getStr
  doAssert r.messages[4]{"role"}.getStr == "assistant"
  doAssert r.messages[4]{"content"}.getStr == "SECOND_REPLY"

proc cmdDeferred() =
  var r = newTurnRun()
  # A deferred command as commitQueuedEcho leaves it: echoed=true, the
  # drain's to-do.
  startQueuedEvent(ieCommand, ":streaming off", echoed = true, delayMs = 50)
  discard runTurns(r.profile, r.messages, r.session)
  joinQueuedEvent()

  doAssert hasQueuedAutosend()
  doAssert r.messages.len == 4
  doAssert r.messages[2]{"role"}.getStr == "assistant"
  doAssert r.messages[3]{"role"}.getStr == "tool"
  doAssert "tooldone" in r.messages[3]{"content"}.getStr
  doAssert "SHOULD_NOT_BE_CALLED" notin $r.messages

# --- pure api probes -------------------------------------------------------

when defined(providerStub):
  proc stubFailures() =
    doAssert parseStubFailure("dns") == sfDns
    doAssert parseStubFailure("network-unreachable") == sfNetworkUnreachable
    doAssert parseStubFailure("connection-refused") == sfConnectionRefused
    doAssert parseStubFailure("connect-timeout") == sfConnectTimeout
    doAssert parseStubFailure("certificate") == sfCertificate
    doAssert parseStubFailure("broken-pipe") == sfBrokenPipe
    doAssert parseStubFailure("connection-reset") == sfConnectionReset
    doAssert parseStubFailure("eof") == sfEof
    doAssert parseStubFailure("read-timeout") == sfReadTimeout
    doAssert parseStubFailure("silent-then-ok") == sfSilentThenOk
    doAssert parseStubFailure("malformed-sse") == sfMalformedSse
    doAssert parseStubFailure("invalid-json") == sfInvalidJson
    doAssert stubHttpStatus(parseStubFailure("400")) == 400
    doAssert stubHttpStatus(parseStubFailure("401")) == 401
    doAssert stubHttpStatus(parseStubFailure("403")) == 403
    doAssert stubHttpStatus(parseStubFailure("408")) == 408
    doAssert stubHttpStatus(parseStubFailure("409")) == 409
    doAssert stubHttpStatus(parseStubFailure("425")) == 425
    doAssert stubHttpStatus(parseStubFailure("429")) == 429
    doAssert stubHttpStatus(parseStubFailure("500")) == 500
    doAssert stubHttpStatus(parseStubFailure("502")) == 502
    doAssert stubHttpStatus(parseStubFailure("503")) == 503
    doAssert stubHttpStatus(parseStubFailure("504")) == 504

  # --- empty-content auto-handling probes ------------------------------------

  proc emptyEscalate() =
    # The headline bug: GLM/Qwen/gpt-oss return 200 OK with content empty and
    # finish_reason "length" (reasoning ate the whole budget). runTurns must
    # NOT dead-end here: it escalates max_tokens and retries within the same
    # turn, recovering when the second response carries real content. This is
    # a turns-layer concern (the transport retry block stays untouched).
    let profile = Profile(name: "nebius.zai-org/GLM-5.2", url: "stub://",
      key: "k", family: "glm", model: "zai-org/GLM-5.2")
    var r = newPromptRun(profile)
    discard runTurnsInteractive(r.profile, r.messages, r.session)

    # The empty turn is NOT added to history on a length-escalation retry (it
    # would pollute context); only the recovered content lands. The escalation
    # must have bumped max_tokens above the known-good 8192.
    let lastAssistant = r.messages[^1]
    doAssert lastAssistant{"role"}.getStr == "assistant",
      "last msg role: " & lastAssistant{"role"}.getStr
    let got = lastAssistant{"content"}.getStr
    doAssert "RECOVERED_AFTER_ESCALATION" in got,
      "content: " & got
    doAssert lastStubMaxTokensOverride() > 8192,
      "override was " & $lastStubMaxTokensOverride() & " (no escalation happened)"
    echo "OK"

  proc emptyDemote() =
    let profile = Profile(name: "zai.glm-5.3", url: "stub://", key: "k",
      family: "glm", model: "glm-5.3", reasoning: "high")
    var r = newPromptRun(profile)
    discard runTurnsInteractive(r.profile, r.messages, r.session)

    let lastAssistant = r.messages[^1]
    doAssert lastAssistant{"role"}.getStr == "assistant"
    doAssert "RECOVERED_AFTER_DEMOTE" in lastAssistant{"content"}.getStr,
      "content: " & lastAssistant{"content"}.getStr
    doAssert lastStubReasoningEffort() == "low",
      "effort was " & lastStubReasoningEffort() & " (no demote happened)"
    doAssert lastStubMaxTokensOverride() == 0,
      "override was " & $lastStubMaxTokensOverride() & " (budget raised before demote)"
    echo "OK"

  proc loopSteer() =
    let profile = Profile(name: "zai.glm-5.3", url: "stub://", key: "k",
      family: "glm", model: "glm-5.3", reasoning: "high")
    var r = newPromptRun(profile)
    discard runTurnsInteractive(r.profile, r.messages, r.session)

    let lastAssistant = r.messages[^1]
    doAssert lastAssistant{"role"}.getStr == "assistant"
    doAssert "RECOVERED_AFTER_LOOP_STEER" in lastAssistant{"content"}.getStr,
      "content: " & lastAssistant{"content"}.getStr
    # The cut turn and the agent steer both land in history, in that order.
    var cutIdx = -1
    var steerIdx = -1
    for i in 0 ..< r.messages.len:
      let m = r.messages[i]
      if m{"finish_reason"}.getStr == "reasoning-loop": cutIdx = i
      if m{"agentSent"}.getBool(false): steerIdx = i
    doAssert cutIdx > 0, "cut assistant turn missing from history"
    doAssert steerIdx == cutIdx + 1,
      "steer not appended right after the cut turn: " & $steerIdx & " vs " & $cutIdx
    doAssert "repeating itself" in r.messages[steerIdx]{"content"}.getStr
    # The budget ladder must NOT have fired for a loop cut.
    doAssert lastStubMaxTokensOverride() == 0,
      "override was " & $lastStubMaxTokensOverride() & " (budget raised on a loop)"
    doAssert lastStubReasoningEffort() == "high",
      "effort was " & lastStubReasoningEffort() & " (demoted on a loop)"
    echo "OK"

  proc loopGiveup() =
    let profile = Profile(name: "zai.glm-5.3", url: "stub://", key: "k",
      family: "glm", model: "glm-5.3", reasoning: "high")
    var r = newPromptRun(profile)
    discard runTurnsInteractive(r.profile, r.messages, r.session)

    # Three cut responses consumed: the initial call plus two steered retries,
    # then the turn ended. The give-up path leaves the last cut turn as the
    # final message.
    let cuts = r.messages.filterIt(it{"finish_reason"}.getStr == "reasoning-loop")
    doAssert cuts.len == 3, "cuts: " & $cuts.len
    doAssert r.messages[^1]{"finish_reason"}.getStr == "reasoning-loop"
    echo "OK"

  proc emptyDemoteLadder() =
    let profile = Profile(name: "mistral.mistral-medium-3-5", url: "stub://",
      key: "k", family: "mistral", model: "mistral-medium-3-5",
      reasoning: "high")
    var r = newPromptRun(profile)
    discard runTurnsInteractive(r.profile, r.messages, r.session)

    let lastAssistant = r.messages[^1]
    doAssert lastAssistant{"role"}.getStr == "assistant"
    doAssert "RECOVERED_AFTER_DEMOTE" in lastAssistant{"content"}.getStr,
      "content: " & lastAssistant{"content"}.getStr
    doAssert lastStubReasoningEffort() == "none",
      "effort was " & lastStubReasoningEffort() & " (demoted off the model ladder)"
    doAssert lastStubMaxTokensOverride() == 0,
      "override was " & $lastStubMaxTokensOverride() & " (budget raised before demote)"
    echo "OK"


proc emptyResend() =
  let profile = Profile(name: "nebius.zai-org/GLM-5.2", url: "stub://",
    key: "k", family: "glm", model: "zai-org/GLM-5.2")
  var r = newPromptRun(profile)
  let t0 = epochTime()
  discard runTurnsInteractive(r.profile, r.messages, r.session)
  # The steer (1s) + bare resend (2s) backoffs must actually elapse: an
  # instant retry loop is the bug this guards against.
  doAssert epochTime() - t0 >= 2.5,
    "empty-reply retries took no backoff: " & $(epochTime() - t0) & "s"

  let lastAssistant = r.messages[^1]
  doAssert lastAssistant{"role"}.getStr == "assistant",
    "last msg role: " & lastAssistant{"role"}.getStr
  doAssert "RECOVERED_AFTER_RESEND" in lastAssistant{"content"}.getStr,
    "content: " & lastAssistant{"content"}.getStr
  echo "OK"

# --- the byte-envelope / summarizer server probe ---------------------------

proc handle(server: BadServer, client: Socket) =
  try:
    var buf = ""
    var contentLength = 0
    while true:
      let ch = client.recv(1)
      if ch.len == 0: return
      buf.add ch
      if buf.endsWith("\r\n\r\n"): break
    for line in buf.splitLines:
      if line.toLowerAscii.startsWith("content-length:"):
        contentLength = parseInt(line.split(":")[1].strip)
    var body = ""
    while body.len < contentLength:
      let chunk = client.recv(min(4096, contentLength - body.len))
      if chunk.len == 0: break
      body.add chunk
    let head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" &
      "Content-Length: "
    proc reply(client: Socket, body: string) =
      client.send(head & $body.len & "\r\nConnection: close\r\n\r\n" & body)
    let isSummarizer = body.find("You are summarizing") >= 0
    if body.len > server.envelope or (isSummarizer and server.rejectSummarizer):
      let err = $(%*{"error": {"message": "inference_failed"}})
      client.send("HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\n" &
        "Content-Length: " & $err.len & "\r\nConnection: close\r\n\r\n" & err)
    elif isSummarizer:
      reply(client, $(%*{"choices": [{"index": 0, "finish_reason": "stop",
        "message": {"role": "assistant", "content": "recap: earlier turns"}}],
        "usage": {"prompt_tokens": 50, "completion_tokens": 10,
                  "total_tokens": 60}}))
    else:
      # Small reported usage: the proactive summarize threshold (0.8 of
      # the window) must never fire, so the recovery can only be the
      # reactive 400 path under test.
      reply(client, $(%*{"choices": [{"index": 0, "finish_reason": "stop",
        "message": {"role": "assistant", "content": "RECOVERED_AFTER_SUMMARY"}}],
        "usage": {"prompt_tokens": 100, "completion_tokens": 10,
                  "total_tokens": 110}}))
  except CatchableError:
    discard

proc serve(server: BadServer) {.thread.} =
  while server.running:
    var client: Socket
    try:
      server.sock.accept(client)
    except OSError:
      continue
    if client == nil: continue
    try:
      server.handle(client)
    except CatchableError:
      discard
    try: client.close() except CatchableError: discard

proc newBadServer(): BadServer =
  result = BadServer(sock: newSocket(), running: true, envelope: 900_000)
  result.sock.setSockOpt(OptReuseAddr, true)
  result.sock.bindAddr(Port(0))
  result.sock.listen()
  setSockTimeoutMs(result.sock, 200)
  let (_, p) = result.sock.getLocalAddr()
  result.port = p.int

proc size400() =
  # The stub provider can't drive this (summarizeHistory goes through real
  # HTTP), so the probe runs the real non-stream transport against a local
  # byte-envelope server.
  let server = newBadServer()
  var serveThread: Thread[BadServer]
  createThread(serveThread, serve, server)

  # Plain-http loopback + the non-stream transport: the probe asserts the
  # recovery logic, not SSE parsing.
  streamingEnabled = false
  let profile = Profile(name: "nebius.zai-org/GLM-5.2",
    url: "http://127.0.0.1:" & $server.port,
    key: "k", family: "glm", model: "zai-org/GLM-5.2")

  proc bigHistory(): JsonNode =
    # 20 turns of 60KB = ~1.2MB of request JSON: over the 900KB envelope,
    # under any token threshold the fake usage reports. The summarizer's
    # clip cap (768KB) sits under the envelope, exactly like Zen, so the
    # clipped meta-call fits even though the raw history does not.
    result = %*[{"role": "system", "content": "sys"}]
    for i in 1..20:
      result.add %*{"role": "user", "content": "turn " & $i & " " & "x".repeat(60000)}

  block scenario_a:
    # Summarizer meta-call succeeds: the turn recovers with a real recap.
    var messages = bigHistory()
    var session: Session
    session.savePath = ""
    session.readCache = newReadCache()
    discard runTurnsInteractive(profile, messages, session)
    let last = messages[^1]
    doAssert last{"role"}.getStr == "assistant",
      "A: last role " & last{"role"}.getStr
    doAssert "RECOVERED_AFTER_SUMMARY" in last{"content"}.getStr,
      "A: content " & last{"content"}.getStr
    doAssert messages.len == 11, "A: " & $messages.len & " messages"
    doAssert SummaryPrefix in messages[1]{"content"}.getStr,
      "A: no synthetic recap: " & messages[1]{"content"}.getStr
    echo "SCENARIO_A_OK"

  block scenario_b:
    # Summarizer meta-call also 400s: the middle is dropped locally via
    # OverflowFallbackSummary instead of dead-ending the session forever.
    server.rejectSummarizer = true
    var messages = bigHistory()
    var session: Session
    session.savePath = ""
    session.readCache = newReadCache()
    discard runTurnsInteractive(profile, messages, session)
    let last = messages[^1]
    doAssert last{"role"}.getStr == "assistant",
      "B: last role " & last{"role"}.getStr
    doAssert "RECOVERED_AFTER_SUMMARY" in last{"content"}.getStr,
      "B: content " & last{"content"}.getStr
    doAssert "dropped without a recap" in messages[1]{"content"}.getStr,
      "B: no fallback recap: " & messages[1]{"content"}.getStr
    echo "SCENARIO_B_OK"

  block scenario_c:
    # Proactive guard: an opencode (Zen) profile whose request body crosses
    # the 1MB guard must collapse at end of turn WITHOUT any 400 — the call
    # succeeds (envelope raised to 2MB), and the byte guard fires on the
    # measured body size, not on a rejection.
    server.rejectSummarizer = false
    server.envelope = 2_000_000
    let zenProfile = Profile(name: "opencode.glm-5.3",
      url: "http://127.0.0.1:" & $server.port,
      key: "k", family: "glm", model: "glm-5.3")
    var messages = %*[{"role": "system", "content": "sys"}]
    for i in 1..17:
      messages.add %*{"role": "user", "content": "turn " & $i & " " & "x".repeat(60000)}
    var session: Session
    session.savePath = ""
    session.readCache = newReadCache()
    discard runTurnsInteractive(zenProfile, messages, session)
    let last = messages[^1]
    doAssert last{"role"}.getStr == "assistant",
      "C: last role " & last{"role"}.getStr
    doAssert "RECOVERED_AFTER_SUMMARY" in last{"content"}.getStr,
      "C: content " & last{"content"}.getStr
    doAssert messages.len == 10, "C: " & $messages.len & " messages"
    doAssert SummaryPrefix in messages[1]{"content"}.getStr,
      "C: no synthetic recap: " & messages[1]{"content"}.getStr
    echo "SCENARIO_C_OK"

  block scenario_d:
    # Proactive message-count guard: a tesseracted Kolibri profile whose
    # history crosses MaxMessagesTesseracted (72) must collapse at end of
    # turn with a real recap and no 400 at all — the tesseracted gateway
    # caps `messages` at 80 entries regardless of token count (the
    # 2026-10-08 session died at 82 messages, 12% of the window).
    server.rejectSummarizer = false
    server.envelope = 2_000_000
    let kolibriProfile = Profile(name: "tesseracted.Aleph-Alpha/Kolibri-1",
      url: "http://127.0.0.1:" & $server.port,
      key: "k", family: "kolibri", model: "Aleph-Alpha/Kolibri-1")
    var messages = %*[{"role": "system", "content": "sys"}]
    for i in 1..70:
      messages.add %*{"role": "user", "content": "turn " & $i}
    doAssert messages.len == 71
    var session: Session
    session.savePath = ""
    session.readCache = newReadCache()
    discard runTurnsInteractive(kolibriProfile, messages, session)
    let last = messages[^1]
    doAssert last{"role"}.getStr == "assistant",
      "D: last role " & last{"role"}.getStr
    doAssert "RECOVERED_AFTER_SUMMARY" in last{"content"}.getStr,
      "D: content " & last{"content"}.getStr
    doAssert messages.len == 10, "D: " & $messages.len & " messages"
    doAssert SummaryPrefix in messages[1]{"content"}.getStr,
      "D: no synthetic recap: " & messages[1]{"content"}.getStr
    echo "SCENARIO_D_OK"

  server.running = false
  server.sock.close()
  joinThread(serveThread)

# --- dispatch ---------------------------------------------------------------

when isMainModule:
  if paramCount() != 1:
    stderr.writeLine "usage: probe <mode>"
    quit 2
  when defined(providerStub):
    case paramStr(1)
    of "autosend": autosend()
    of "syscmd-yield": syscmdYield()
    of "syscmd-resume": syscmdResume()
    of "syscmd-inline": syscmdInline()
    of "autosend-api": autosendApi()
    of "autosend-batch": autosendBatch()
    of "cmd-tombstone": cmdTombstone()
    of "cmd-deferred": cmdDeferred()
    of "stub-failures": stubFailures()
    of "empty-escalate": emptyEscalate()
    of "empty-demote": emptyDemote()
    of "loop-steer": loopSteer()
    of "loop-giveup": loopGiveup()
    of "empty-demote-ladder": emptyDemoteLadder()
    of "empty-resend": emptyResend()
    of "size400": size400()
    else:
      stderr.writeLine "unknown probe mode: " & paramStr(1)
      quit 2
  else:
    # The plain-http build exists only for size400, the one scenario that
    # must reach a real local HTTP server rather than the stub provider.
    if paramStr(1) != "size400":
      stderr.writeLine "this probe build only supports size400"
      quit 2
    size400()
