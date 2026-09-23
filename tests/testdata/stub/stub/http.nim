## Test-only stub for the non-streaming transport (`callHttp`), conditionally
## `include`d into `api.nim` when built with `-d:httpStub`. Shares this
## module's scope (`StreamOutcome`, `buildBatchAssistantMsg`, `parseUsage`,
## `hookProgress`, etc.) so the stub returns the same shape the real
## `callHttp` builds, without touching a socket.
##
## Resolution: a JSON array of response objects is read from
## ``THREECODE_HTTP_STUB_RESPONSES`` (or ``http_stub_responses.json`` in the
## cwd). Each element is one `callHttp` result, consumed in order:
##
##   { "choices": [{"message": {"content": "hi", "reasoning_content": "..."}}],
##     "usage": {...} }
##     -> a successful 200 completion reconstructed into an assistant message.
##
##   { "status": 429, "body": "..." }
##   { "failure": "429" }
##   { "failure": "500" }
##     -> a non-200 (or transport) failure, exercising the shared retry block.
##
##   { "status": 200, "body": "not json" }
##     -> a 200 with an unparseable body, exercising the parse-error path.
##
##   { "status": 200, "choices": [{"message": {"content": "<tool_call>..."} }}] }
##     -> 200 content carrying leaked chat-template tags; the shared
##        `xmlToolCallsFallback` promotion in `callModel` must lift them to
##        synthetic tool_calls.

var httpStubResponseIdx = 0

proc loadHttpStubResponses(): seq[JsonNode] =
  let path = block:
    let override = getEnv("THREECODE_HTTP_STUB_RESPONSES")
    if override.len > 0: override else: "http_stub_responses.json"
  if not fileExists(path):
    stderr.writeLine "3code: http stub: " & path & " not found"
    quit 1
  let raw = readFile(path)
  try: parseJson(raw).getElems
  except CatchableError:
    stderr.writeLine "3code: http stub: malformed JSON in " & path
    quit 1

proc nextHttpStubResponse(): JsonNode =
  let responses = loadHttpStubResponses()
  if httpStubResponseIdx >= responses.len:
    stderr.writeLine "3code: http stub: response index " & $httpStubResponseIdx &
      " out of range (" & $responses.len & " responses)"
    quit 1
  result = responses[httpStubResponseIdx]
  inc httpStubResponseIdx

proc resetHttpStubIdx*() =
  ## Test helper: rewind the response cursor so a fresh `callModel` starts
  ## at the first canned response. Exported so the test module can call it.
  httpStubResponseIdx = 0

proc httpStubStatus(node: JsonNode): int =
  node{"status"}.getInt(200)

proc consumeHttpStubCompletion(j: JsonNode; outcome: var StreamOutcome;
                               slurped: var int; baseLabel: string): bool =
  ## Shared 200-body reconstruction (mirrors `callHttp`'s success path) so
  ## the stub exercises the exact same field extraction. Returns false when
  ## the completion is empty so the caller records the empty-body error.
  let choices = j{"choices"}
  if choices == nil or choices.kind != JArray or choices.len == 0:
    if j{"error"} != nil:
      outcome.errMsg = "api error in 200 body"
      outcome.errBody = $j
    return false
  let message = choices[0]{"message"}
  if message == nil or message.kind != JObject:
    outcome.errBody = $j
    outcome.errMsg = "response missing choices[0].message"
    return false
  let content = message{"content"}.getStr("")
  var reasoning = message{"reasoning_content"}.getStr("")
  if reasoning.len == 0: reasoning = message{"reasoning"}.getStr("")
  let toolCalls =
    if message{"tool_calls"} != nil and message{"tool_calls"}.kind == JArray:
      message{"tool_calls"}
    else: newJArray()
  let frNode = choices[0]{"finish_reason"}
  let finishReason =
    if frNode != nil and frNode.kind == JString and frNode.getStr.len > 0:
      frNode.getStr
    else: ""
  outcome.finishReason = finishReason
  slurped = content.len + reasoning.len
  hookProgress(baseLabel, slurped)
  outcome.assistantMsg = buildBatchAssistantMsg(content, reasoning, toolCalls, finishReason)
  if outcome.assistantMsg == nil:
    outcome.errBody = $j
    outcome.errMsg = "empty reply - no content, no tool calls"
    return false
  let u2 = j{"usage"}
  if u2 != nil and u2.kind == JObject:
    outcome.usage = parseUsage(u2)
  result = true

proc callHttpStub(url, key, bodyStr: string; baseLabel: string;
                  slurped: var int): StreamOutcome =
  ## Drop-in replacement for `callHttp` under `-d:httpStub`. Builds a
  ## `StreamOutcome` from the next canned response, exercising every branch
  ## the real `callHttp` can produce (success, non-200, parse error, empty).
  ## Self-contained: does not depend on the provider stub's failure helpers
  ## so the two stubs can be used independently (http stub tests the
  ## network layer; provider stub tests everything else).
  let node = nextHttpStubResponse()
  result.statusCode = httpStubStatus(node)
  result.retryAfter = node{"retryAfter"}.getStr("")

  if node{"failure"}.getStr("").len > 0:
    # A failure marker: interpret an integral value as an HTTP status, any
    # other string as a transport-level error message.
    let f = node{"failure"}.getStr
    let asCode = try: parseInt(f) except CatchableError: 0
    if asCode > 0:
      result.statusCode = asCode
      result.errMsg = "api " & $asCode
    else:
      result.errMsg = "transport: " & f
    result.errBody = node{"body"}.getStr("")
    return

  if result.statusCode != 200:
    result.errBody = node{"body"}.getStr(node{"error"}.getStr(""))
    if result.errBody.len == 0:
      result.errMsg = "api " & $result.statusCode
    return

  # 200: either a well-formed completion or an unparseable body (parse-error
  # path). Distinguish by whether `choices` is present and well-formed.
  let rawBody = node{"body"}.getStr("")
  if rawBody.len > 0:
    # Caller pinned the raw body — parse it the same way the real callHttp
    # does so the error paths are exercised identically.
    result.errBody = rawBody
    let j = try: parseJson(rawBody) except CatchableError:
      result.errMsg = "response parse: " & getCurrentExceptionMsg()
      return
    if j == nil or j.kind != JObject:
      result.errMsg = "response not a JSON object"
      return
    result.errBody = ""
    discard consumeHttpStubCompletion(j, result, slurped, baseLabel)
    return

  discard consumeHttpStubCompletion(node, result, slurped, baseLabel)
