## Test-only stub provider, conditionally included into `api.nim` when built
## with `-d:providerStub`. This module is pulled in with Nim's `include`
## directive, so it shares `api.nim`'s scope: the private `hook*` stream
## callbacks, the retry-level state, `ApiError`, `isInterrupted`, and the
## other helpers are all visible here without being exported.

var stubResponseIdx = 0

proc emitTestFrameEvent() =
  when defined(posix):
    let fdText = getEnv("THREECODE_TEST_FRAME_FD")
    if fdText.len > 0:
      try:
        let fd = cint(parseInt(fdText))
        var ch = 'f'
        discard posix.write(fd, addr ch, 1)
        let ackText = getEnv("THREECODE_TEST_FRAME_ACK_FD")
        if ackText.len > 0:
          let ackFd = cint(parseInt(ackText))
          var ack: array[1, char]
          discard posix.read(ackFd, addr ack[0], 1)
      except CatchableError:
        discard

proc testFrameMode(): bool =
  getEnv("THREECODE_TEST_FRAME_FD").len > 0

proc waitForTestContinue() =
  when defined(posix):
    let fdText = getEnv("THREECODE_TEST_API_CONTINUE_FD")
    if fdText.len == 0:
      return
    let fd = try: cint(parseInt(fdText)) except CatchableError: return
    var pfd: TPollfd
    pfd.fd = fd
    pfd.events = POLLIN
    while true:
      if isInterrupted():
        raise newException(ApiError, "interrupted by user")
      let r = poll(addr pfd, 1.Tnfds, 100.cint)
      if r > 0 and (pfd.revents and POLLIN) != 0:
        var ch: array[1, char]
        if posix.read(fd, addr ch[0], 1) > 0:
          break

type StubFailure* = enum
  sfNone, sfDns, sfNetworkUnreachable, sfConnectionRefused,
  sfConnectTimeout, sfTls, sfCertificate, sfBrokenPipe,
  sfConnectionReset, sfEof, sfReadTimeout, sfSilentThenOk,
  sfMalformedSse, sfInvalidJson, sfHttp400, sfHttp401, sfHttp403,
  sfHttp408, sfHttp409, sfHttp425, sfHttp429, sfHttp500, sfHttp502,
  sfHttp503, sfHttp504

proc parseStubFailure*(s: string): StubFailure =
  case s.strip.toLowerAscii.replace("_", "-")
  of "", "none": sfNone
  of "dns", "name-resolution", "resolve": sfDns
  of "network-unreachable", "net-unreachable", "unreachable", "enetunreach":
    sfNetworkUnreachable
  of "connection-refused", "refused", "econnrefused": sfConnectionRefused
  of "connect-timeout", "timeout-connect", "etimedout": sfConnectTimeout
  of "tls", "ssl": sfTls
  of "certificate", "cert", "cert-expired", "cert-verify": sfCertificate
  of "broken-pipe", "epipe": sfBrokenPipe
  of "connection-reset", "reset", "econnreset": sfConnectionReset
  of "eof", "closed": sfEof
  of "read-timeout", "timeout-read", "stall": sfReadTimeout
  of "silent-then-ok", "flaky-silent": sfSilentThenOk
  of "malformed-sse", "bad-sse": sfMalformedSse
  of "invalid-json", "bad-json": sfInvalidJson
  of "400", "http-400", "bad-request": sfHttp400
  of "401", "http-401", "unauthorized", "auth": sfHttp401
  of "403", "http-403", "forbidden": sfHttp403
  of "408", "http-408", "request-timeout": sfHttp408
  of "409", "http-409", "conflict": sfHttp409
  of "425", "http-425", "too-early": sfHttp425
  of "429", "http-429", "rate": sfHttp429
  of "500", "http-500": sfHttp500
  of "502", "http-502": sfHttp502
  of "503", "http-503": sfHttp503
  of "504", "http-504": sfHttp504
  else: sfNone

proc stubFailureName*(f: StubFailure): string =
  case f
  of sfNone: "none"
  of sfConnectTimeout: "connect timeout"
  of sfDns: "dns failure"
  of sfNetworkUnreachable: "network unreachable"
  of sfConnectionRefused: "connection refused"
  of sfTls: "tls failure"
  of sfCertificate: "certificate failure"
  of sfBrokenPipe: "broken pipe"
  of sfConnectionReset: "connection reset"
  of sfEof: "unexpected eof"
  of sfReadTimeout: "read timeout"
  of sfSilentThenOk: "silent connection"
  of sfMalformedSse: "malformed sse"
  of sfInvalidJson: "invalid json"
  of sfHttp400: "api 400"
  of sfHttp401: "api 401"
  of sfHttp403: "api 403"
  of sfHttp408: "api 408"
  of sfHttp409: "api 409"
  of sfHttp425: "api 425"
  of sfHttp429: "api 429"
  of sfHttp500: "api 500"
  of sfHttp502: "api 502"
  of sfHttp503: "api 503"
  of sfHttp504: "api 504"

proc stubHttpStatus*(f: StubFailure): int =
  case f
  of sfHttp400: 400
  of sfHttp401: 401
  of sfHttp403: 403
  of sfHttp408: 408
  of sfHttp409: 409
  of sfHttp425: 425
  of sfHttp429: 429
  of sfHttp500: 500
  of sfHttp502: 502
  of sfHttp503: 503
  of sfHttp504: 504
  else: 0

proc stubTransportError*(f: StubFailure): string =
  case f
  of sfDns: "TLS connect failed: name or service not known"
  of sfNetworkUnreachable: "TLS connect failed: network is unreachable"
  of sfConnectionRefused: "TLS connect failed: connection refused"
  of sfConnectTimeout: "TLS connect failed: operation timed out"
  of sfTls: "TLS connect failed: handshake failed"
  of sfCertificate: "TLS connect failed: certificate verify failed"
  of sfBrokenPipe: "request failed: broken pipe"
  of sfConnectionReset: "stream read: connection reset by peer"
  of sfEof: "stream read: EOF before end of response"
  of sfReadTimeout: "stream read: operation timed out"
  of sfMalformedSse: "stream read: malformed chunked transfer encoding"
  of sfInvalidJson: "stream read: invalid JSON in SSE data"
  else: ""

proc stubDelayMs(j: JsonNode, key: string, fallback = 0): int =
  if j != nil and j.kind == JObject:
    result = j{key}.getInt(fallback)
  else:
    result = fallback

proc stubRetryAfter(j: JsonNode): string =
  if j != nil and j.kind == JObject:
    result = j{"retryAfter"}.getStr("")

proc stubErrBody(f: StubFailure, j: JsonNode): string =
  if j != nil and j.kind == JObject and "body" in j:
    return j{"body"}.getStr
  case f
  of sfHttp400: """{"error":"bad request"}"""
  of sfHttp401: """{"error":"unauthorized"}"""
  of sfHttp403: """{"error":"forbidden"}"""
  of sfHttp408: """{"error":"request timeout"}"""
  of sfHttp409: """{"error":"conflict"}"""
  of sfHttp425: """{"error":"too early"}"""
  of sfHttp429: """{"error":"rate limit"}"""
  of sfHttp500: """{"error":"server error"}"""
  of sfHttp502: """{"error":"bad gateway"}"""
  of sfHttp503: """{"error":"service unavailable"}"""
  of sfHttp504: """{"error":"gateway timeout"}"""
  else: ""

proc loadStubResponses(): seq[JsonNode] =
  ## Read stub_responses.json: a JSON array of assistant-message objects.
  ## Each element is an OpenAI-shape assistant message (role, content,
  ## tool_calls), or `{failure: "...", delayMs: N}` to exercise retry /
  ## flaky-network paths. Re-read on every call so edits take effect
  ## mid-session.
  ##
  ## Resolution: an absolute path in ``THREECODE_STUB_RESPONSES`` wins,
  ## otherwise the cwd-relative ``stub_responses.json``. The override lets
  ## a test delete the process cwd (to reproduce a deleted-cwd crash) and
  ## still serve responses from a stable path.
  let path = block:
    let override = getEnv("THREECODE_STUB_RESPONSES")
    if override.len > 0: override else: "stub_responses.json"
  if not fileExists(path):
    stderr.writeLine "3code: stub: " & path & " not found"
    quit 1
  let raw = readFile(path)
  try: parseJson(raw).getElems
  except CatchableError:
    stderr.writeLine "3code: stub: malformed JSON in " & path
    quit 1

proc stubCallModel(messages: JsonNode): JsonNode =
  let responses = loadStubResponses()
  if stubResponseIdx >= responses.len:
    stderr.writeLine "3code: stub: response index " & $stubResponseIdx &
      " out of range (" & $responses.len & " responses)"
    quit 1
  result = responses[stubResponseIdx]
  inc stubResponseIdx

proc stubUsage(node: JsonNode, content: string): Usage =
  let u = if node != nil and node.kind == JObject: node{"usage"} else: nil
  if u != nil and u.kind == JObject:
    result.promptTokens =
      u{"promptTokens"}.getInt(u{"prompt_tokens"}.getInt(0))
    result.completionTokens =
      u{"completionTokens"}.getInt(u{"completion_tokens"}.getInt(0))
    result.totalTokens =
      u{"totalTokens"}.getInt(u{"total_tokens"}.getInt(0))
    result.cachedTokens =
      u{"cachedTokens"}.getInt(
        u{"cached_tokens"}.getInt(
          u{"prompt_cache_hit_tokens"}.getInt(0)))
    if result.totalTokens == 0:
      result.totalTokens = result.promptTokens + result.completionTokens
    return
  result.promptTokens = 100
  result.completionTokens = max(1, content.len div 4)
  result.totalTokens = result.promptTokens + result.completionTokens

proc stubStringChunks(node: JsonNode; key, fallback: string): seq[string] =
  let chunks = node{key}
  if chunks != nil and chunks.kind == JArray:
    for chunk in chunks:
      result.add chunk.getStr("")
  if result.len == 0:
    for ch in fallback:
      result.add $ch

proc callModelStub(p: Profile, messages: JsonNode, usage: var Usage,
                   lastPromptTokens: int): JsonNode =
  let stubT0 = epochTime()
  let stubWindow = contextWindowFor(p)
  let stubBaseLabel = hookBeforeCall(lastPromptTokens, stubWindow)
  defer:
    hookAfterCall()
  const StubMaxAttempts = 12
  var attempt = 0
  var lastFailure = sfNone
  while true:
    inc attempt
    let node = stubCallModel(messages)
    if node.kind == JObject and node{"failure"}.getStr("").len > 0:
      lastFailure = parseStubFailure(node{"failure"}.getStr)
      let delayMs = stubDelayMs(node, "delayMs", 300)
      var remaining = delayMs
      while remaining > 0:
        if isInterrupted():
          hookStopSpinner()
          raise newException(ApiError, "interrupted by user")
        let step = min(100, remaining)
        sleep(step)
        remaining -= step
      let code = stubHttpStatus(lastFailure)
      var errMsg =
        if code > 0: "api " & $code
        else: stubTransportError(lastFailure)
      if errMsg.len == 0:
        errMsg = stubFailureName(lastFailure)
      let category = retryCategory(errMsg, nil, code)
      if category.len == 0 or attempt >= StubMaxAttempts:
        hookStopSpinner()
        raise newException(ApiError,
          errMsg & (if stubErrBody(lastFailure, node).len > 0:
            ": " & stubErrBody(lastFailure, node) else: ""))
      let retryAfter = try: parseInt(stubRetryAfter(node)) except CatchableError: 0
      let backoff =
        if retryAfter > 0: retryAfter
        elif category == "rate": min(1 shl rateRetryLevel, 90)
        else: min(1 shl serverRetryLevel, 16)
      hookStopSpinner()
      hookRetryNotice &"3code: {errMsg}; retry {attempt + 1}/{StubMaxAttempts} in {backoff}s"
      var waitMs = backoff * 1000
      while waitMs > 0:
        if isInterrupted():
          raise newException(ApiError, "interrupted by user during retry backoff")
        let step = min(100, waitMs)
        sleep(step)
        waitMs -= step
      if category == "rate":
        inc rateRetryLevel
        rateLastTs = epochTime()
      else:
        inc serverRetryLevel
        serverLastTs = epochTime()
      hookSetStatusLabel(&"retry {attempt + 1}/{StubMaxAttempts}")
      hookStartSpinner("")
    else:
      result = node
      break
  if result.kind == JObject and "role" notin result:
    result["role"] = %"assistant"
  debugOut &"callModel stub idx={stubResponseIdx-1} failure={stubFailureName(lastFailure)}"
  var slurped = 0
  let preStreamDelay = stubDelayMs(result, "preStreamDelayMs", 0)
  if preStreamDelay > 0:
    var remaining = preStreamDelay
    while remaining > 0:
      if isInterrupted():
        hookStopSpinner()
        raise newException(ApiError, "interrupted by user")
      let step = min(100, remaining)
      sleep(step)
      remaining -= step
  if testFrameMode() and result{"waitForTestContinue"}.getBool(false):
    waitForTestContinue()
  let stubContent = result{"content"}.getStr("")
  var stubStreamedLive = false
  if result{"stream"}.getBool(true):
    var stubReasoning = result{"reasoning_content"}.getStr("")
    if stubReasoning.len == 0:
      stubReasoning = result{"reasoning"}.getStr("")
    var accReasoning = ""
    var contentStarted = false
    for chunk in stubStringChunks(result, "reasoningChunks", stubReasoning):
      accReasoning.add chunk
      slurped += chunk.len
      hookProgress(stubBaseLabel, slurped)
      if not contentStarted:
        hookReasoningDelta(accReasoning, stubBaseLabel, slurped,
                           contentStarted)
      emitTestFrameEvent()
    for chunk in stubStringChunks(result, "contentChunks", stubContent):
      slurped += chunk.len
      hookProgress(stubBaseLabel, slurped)
      contentStarted = hookContentDelta(chunk, stubBaseLabel, slurped)
      emitTestFrameEvent()
    if contentStarted:
      stubStreamedLive = hookContentFinished(stubContent, stubBaseLabel,
                                             slurped)
      hookTrimTrailingContent(stubContent, stubBaseLabel, slurped)
      if stubStreamedLive:
        hookAfterLiveContent(stubBaseLabel, slurped)
      emitTestFrameEvent()
  hookStopSpinner()
  usage = stubUsage(result, stubContent)
  let stubElapsed =
    if testFrameMode(): 0
    else: (epochTime() - stubT0).int
  hookFinalUsage(usage, stubWindow, stubElapsed, stubContent,
                 stubStreamedLive)
  emitTestFrameEvent()
  if result.kind == JObject:
    result["usage"] = %*{
      "promptTokens": usage.promptTokens,
      "completionTokens": usage.completionTokens,
      "totalTokens": usage.totalTokens,
      "cachedTokens": usage.cachedTokens,
      "elapsed": stubElapsed,
      "ts": now().format("yyyy-MM-dd'T'HH:mm:sszzz"),
    }

proc isStubUrl*(url: string): bool =
  url.startsWith("stub://")

proc stubModels*: seq[string] =
  @["stub-model"]
