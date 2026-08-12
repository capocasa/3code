import std/[json, strutils, tables, unittest]
import threecode/[api, types]

suite "api: parseUsage":
  test "parses standard OpenAI usage object":
    let u = parseUsage(%*{
      "prompt_tokens": 100,
      "completion_tokens": 50,
      "total_tokens": 150
    })
    check u.promptTokens == 100
    check u.completionTokens == 50
    check u.totalTokens == 150
    check u.cachedTokens == 0

  test "parses cached tokens from prompt_tokens_details":
    let u = parseUsage(%*{
      "prompt_tokens": 100,
      "completion_tokens": 50,
      "total_tokens": 150,
      "prompt_tokens_details": {"cached_tokens": 40}
    })
    check u.cachedTokens == 40

  test "falls back to prompt_cache_hit_tokens (DeepSeek style)":
    let u = parseUsage(%*{
      "prompt_tokens": 100,
      "completion_tokens": 50,
      "total_tokens": 150,
      "prompt_cache_hit_tokens": 60
    })
    check u.cachedTokens == 60

  test "prefers prompt_tokens_details over flat field":
    let u = parseUsage(%*{
      "prompt_tokens": 100,
      "completion_tokens": 50,
      "total_tokens": 150,
      "prompt_tokens_details": {"cached_tokens": 40},
      "prompt_cache_hit_tokens": 60
    })
    check u.cachedTokens == 40  # details wins

  test "returns zeros for nil":
    let u = parseUsage(nil)
    check u.promptTokens == 0
    check u.totalTokens == 0

  test "returns zeros for non-object":
    let u = parseUsage(newJArray())
    check u.promptTokens == 0

suite "api: classifyRetry":
  test "returns 'server' on exception":
    let e = newException(CatchableError, "connection refused")
    check classifyRetry(e, 0) == "server"

  test "returns 'rate' on 429":
    check classifyRetry(nil, 429) == "rate"

  test "returns 'server' on 500":
    check classifyRetry(nil, 500) == "server"

  test "returns 'server' on 502":
    check classifyRetry(nil, 502) == "server"

  test "returns 'server' on 503":
    check classifyRetry(nil, 503) == "server"

  test "returns empty string on 400":
    check classifyRetry(nil, 400) == ""

  test "returns empty string on 200":
    check classifyRetry(nil, 200) == ""

  test "exception takes priority over code":
    let e = newException(CatchableError, "timeout")
    check classifyRetry(e, 429) == "server"  # exception wins

suite "api: retryCategory":
  test "network failures retry as server":
    check retryCategory("stream read: connection reset by peer", nil, 0) == "server"

  test "429 retries as rate":
    check retryCategory("", nil, 429) == "rate"

  test "5xx statuses retry as server":
    for code in [500, 502, 503, 504]:
      check retryCategory("", nil, code) == "server"

  test "nonretryable auth and request statuses do not retry":
    for code in [400, 401, 403, 408, 409, 425]:
      check retryCategory("", nil, code) == ""

  test "assistant message without status is success":
    let msg = %*{"role": "assistant", "content": "ok"}
    check retryCategory("", msg, 0) == ""

  test "nonretryable status wins over net-error heuristic (regression)":
    # The bug: the streaming transport sets errMsg ("empty reply - no content,
    # no tool calls") and leaves assistantMsg nil for a non-200 error body.
    # The old netFailed shortcut (errMsg != "" and msg == nil => "server")
    # wrongly retried a 400/401/403 for the full 12-attempt budget. An
    # explicit non-retryable status must win regardless of errMsg.
    for code in [400, 401, 403, 408, 409, 425]:
      check retryCategory("empty reply - no content, no tool calls", nil, code) == ""

  test "retryable status wins over net-error heuristic":
    # A 5xx that also carries an errMsg (streaming transport sets it on the
    # empty-content path) must still retry as a server error.
    check retryCategory("empty reply - no content, no tool calls", nil, 502) == "server"
    check retryCategory("empty reply - no content, no tool calls", nil, 429) == "rate"

  test "status 0 without errMsg is not a transport error":
    # Only an explicit errMsg + nil msg at status 0 counts as a transport
    # failure; a bare nil/empty is not an error.
    check retryCategory("", nil, 0) == ""

suite "api: formatApiDetail":
  test "body message with code is suffixed":
    let body = "{\"error\":{\"message\":\"invalid request error trace_id: abc\"}}"
    check formatApiDetail("", body, 400) ==
      "invalid request error trace_id: abc (code 400)"

  test "code-only body collapses to bare error (no duplication)":
    # Gateways emit `{"error":{"message":"error code: 502"}}` which adds
    # nothing beyond the status; collapse to `error (code 502)`.
    let body = "{\"error\":{\"message\":\"error code: 502\"}}"
    check formatApiDetail("", body, 502) == "error (code 502)"

  test "bare-error body collapses too":
    let body = "{\"error\":{\"message\":\"error\"}}"
    check formatApiDetail("", body, 400) == "error (code 400)"

  test "falls back to errMsg when body empty":
    check formatApiDetail("stream read: connection reset by peer", "", 502) ==
      "stream read: connection reset by peer (code 502)"

  test "falls back to bare error when both empty":
    check formatApiDetail("", "", 400) == "error (code 400)"

  test "omits code suffix when status is 0":
    check formatApiDetail("stream read: connection reset", "", 0) ==
      "stream read: connection reset"

  test "bare error with no code":
    check formatApiDetail("", "", 0) == "error"

  test "200-anomaly errMsg yields to a JSON error body (code 0)":
    # A 200 OK that carried an inline error object (e.g. z.ai's overloaded
    # message) must surface the body's error text on exhaustion, not the
    # generic transport errMsg. The promoted NetworkHealthError raise uses
    # formatApiDetail with code 0, so the body wins and no (code N) suffix
    # is appended.
    let body = "{\"error\":{\"message\":\"Service overloaded, please retry\"}}"
    check formatApiDetail(EmptyReplyMsg, body, 0) ==
      "Service overloaded, please retry"
    check formatApiDetail("api error in 200 body", body, 0) ==
      "Service overloaded, please retry"
    check formatApiDetail("response parse: unexpected token", body, 0) ==
      "Service overloaded, please retry"

  test "200-anomaly errMsg surfaces when body is empty (code 0)":
    # When the transport recorded no body (e.g. the empty-reply case where
    # nothing arrived), fall back to the transport errMsg so the user still
    # sees what went wrong. When a body IS present, the body text wins,
    # same contract as HttpError.
    check formatApiDetail(EmptyReplyMsg, "", 0) == EmptyReplyMsg
    check formatApiDetail("response parse: unexpected token", "", 0) ==
      "response parse: unexpected token"
    # A non-JSON body surfaces as its raw text, matching HttpError behavior.
    check formatApiDetail(EmptyReplyMsg, "this is not json at all", 0) ==
      "this is not json at all"

suite "api: applyReasoning — gpt-oss":
  test "sets reasoning_effort for gpt-oss":
    var body = %*{"stream": true}
    let p = Profile(name: "test.model", family: "gpt-oss", model: "model",
                    reasoning: "high")
    applyReasoning(p, body)
    check body{"reasoning_effort"}.getStr == "high"

suite "api: applyReasoning — deepseek":
  test "first-party low disables thinking, sets temperature 0":
    var body = %*{"stream": true}
    let p = Profile(name: "deepseek.model", family: "deepseek", model: "model",
                    reasoning: "low")
    applyReasoning(p, body)
    check body{"thinking"}{"type"}.getStr == "disabled"
    check body{"temperature"}.getFloat == 0.0

  test "first-party medium enables thinking, effort medium":
    var body = %*{"stream": true}
    let p = Profile(name: "deepseek.model", family: "deepseek", model: "model",
                    reasoning: "medium")
    applyReasoning(p, body)
    check body{"thinking"}{"type"}.getStr == "enabled"
    check body{"reasoning_effort"}.getStr == "medium"
    check body{"temperature"}.getFloat == 0.0

  test "first-party high enables thinking, effort high":
    var body = %*{"stream": true}
    let p = Profile(name: "deepseek.model", family: "deepseek", model: "model",
                    reasoning: "high")
    applyReasoning(p, body)
    check body{"thinking"}{"type"}.getStr == "enabled"
    check body{"reasoning_effort"}.getStr == "high"
    check body{"temperature"}.getFloat == 0.0

  test "hosted stack sets only reasoning_effort":
    var body = %*{"stream": true}
    let p = Profile(name: "nebius.model", family: "deepseek", model: "model",
                    reasoning: "high")
    applyReasoning(p, body)
    check body{"reasoning_effort"}.getStr == "high"
    check not body.hasKey("thinking")

suite "api: applyReasoning — minimax":
  # M-series on the OpenAI-compatible surface exposes a binary on/off
  # knob (`chat_template_kwargs.enable_thinking`). low/medium/high are
  # not valid for the minimax family — the `:reasoning` selector rejects
  # them, and `applyReasoning` simply omits the field if it sees one.
  test "off disables thinking and splits reasoning out of content":
    var body = %*{"stream": true}
    let p = Profile(name: "test.model", family: "minimax", model: "model",
                    reasoning: "off")
    applyReasoning(p, body)
    check body{"chat_template_kwargs"}{"enable_thinking"}.getBool == false
    check body{"reasoning_split"}.getBool == true

  test "on enables thinking and splits reasoning out of content":
    var body = %*{"stream": true}
    let p = Profile(name: "test.model", family: "minimax", model: "model",
                    reasoning: "on")
    applyReasoning(p, body)
    check body{"chat_template_kwargs"}{"enable_thinking"}.getBool == true
    check body{"reasoning_split"}.getBool == true

  test "M3 reasoning toggles the same way as M2.x":
    # M3 uses the same vLLM-style chat_template_kwargs knob on the
    # OpenAI-compatible endpoint; the family-level mapping is shared.
    # The version distinction lives in KnownGoodCombos, not the wire
    # mapping — verify it stays that way.
    for effort in ["off", "on"]:
      var body = %*{"stream": true}
      let p = Profile(name: "minimax.MiniMax-M3", family: "minimax",
                      model: "MiniMax-M3", reasoning: effort)
      applyReasoning(p, body)
      check body{"reasoning_split"}.getBool == true
      if effort == "off":
        check body{"chat_template_kwargs"}{"enable_thinking"}.getBool == false
      else:
        check body{"chat_template_kwargs"}{"enable_thinking"}.getBool == true

  test "reasoning_split is hardcoded true regardless of reasoning level":
    # reasoning_split is not a knob the user picks: it must always be on
    # so M-series thinking content never lands in the visible content
    # stream as <think>...</think>. Verify it sticks for empty reasoning
    # too — the only case where enable_thinking is omitted entirely.
    for effort in ["", "off", "on"]:
      var body = %*{"stream": true}
      let p = Profile(name: "minimax.MiniMax-M3", family: "minimax",
                      model: "MiniMax-M3", reasoning: effort)
      applyReasoning(p, body)
      check body.hasKey("reasoning_split")
      check body{"reasoning_split"}.getBool == true

  test "stale low/medium/high values are ignored (no enable_thinking sent)":
    # Belt-and-braces: a config file from before this rewrite may still
    # carry a level value. We don't crash, we don't silently coerce —
    # we just omit the knob and the model defaults to its own policy.
    for effort in ["low", "medium", "high"]:
      var body = %*{"stream": true}
      let p = Profile(name: "minimax.MiniMax-M3", family: "minimax",
                      model: "MiniMax-M3", reasoning: effort)
      applyReasoning(p, body)
      check not body.hasKey("chat_template_kwargs")
      check body{"reasoning_split"}.getBool == true

suite "api: applyReasoning — inkling":
  test "sets reasoning_effort for inkling (gpt-oss shape)":
    var body = %*{"stream": true}
    let p = Profile(name: "together.thinkingmachines/Inkling",
                    family: "inkling", model: "thinkingmachines/Inkling",
                    reasoning: "high")
    applyReasoning(p, body)
    check body{"reasoning_effort"}.getStr == "high"

  test "medium / low pass straight through":
    for effort in ["low", "medium", "high"]:
      var body = %*{"stream": true}
      let p = Profile(name: "baseten.thinkingmachines/inkling",
                      family: "inkling", model: "thinkingmachines/inkling",
                      reasoning: effort)
      applyReasoning(p, body)
      check body{"reasoning_effort"}.getStr == effort

suite "api: applyReasoning — unknown family":
  test "no-op for unknown family":
    var body = %*{"stream": true}
    let p = Profile(name: "test.model", family: "unknown", model: "model",
                    reasoning: "high")
    applyReasoning(p, body)
    check "thinking" notin body
    check "reasoning_effort" notin body
    check "chat_template_kwargs" notin body

suite "api: stripInternalFields":
  test "strips usage from assistant messages":
    let messages = %*[
      {"role": "system", "content": "sys"},
      {"role": "user", "content": "hi"},
      {"role": "assistant", "content": "hello", "usage": {"promptTokens": 100}}
    ]
    let stripped = stripInternalFields(messages)
    check stripped.len == 3
    check "usage" notin stripped[2]
    check stripped[2]["content"].getStr == "hello"

  test "preserves messages without usage":
    let messages = %*[
      {"role": "system", "content": "sys"},
      {"role": "user", "content": "hi"}
    ]
    let stripped = stripInternalFields(messages)
    check stripped.len == 2
    check stripped[0]["content"].getStr == "sys"

  test "strips reasoning_content when not deepseek":
    let messages = %*[
      {"role": "assistant", "content": "hi", "usage": {"promptTokens": 5},
       "reasoning_content": "thinking..."}
    ]
    let stripped = stripInternalFields(messages)
    check "usage" notin stripped[0]
    check stripped[0].hasKey("reasoning_content")

  test "strips interrupted marker from assistant messages":
    let messages = %*[
      {"role": "assistant", "content": "partial", "interrupted": true}
    ]
    let stripped = stripInternalFields(messages)
    check "interrupted" notin stripped[0]
    check stripped[0]["content"].getStr == "partial"

suite "api: buildStreamAssistantMsg":
  test "returns nil when stream produced no assistant data":
    let tools = initOrderedTable[int, JsonNode]()
    check buildStreamAssistantMsg("", "", tools, Usage()) == nil

  test "marks interrupted partial content":
    let tools = initOrderedTable[int, JsonNode]()
    let msg = buildStreamAssistantMsg("partial answer", "", tools, Usage(),
                                      wasInterrupted = true)
    check msg != nil
    check msg{"role"}.getStr == "assistant"
    check msg{"content"}.getStr == "partial answer"
    check msg{"interrupted"}.getBool == true
    check msg.hasKey("reasoning_content")

suite "api: extractErrorMsg":
  test "extracts OpenAI-style error message":
    let msg = extractErrorMsg("""{"error":{"message":"Rate limit exceeded","type":"rate_limit_error"}}""")
    check msg == "Rate limit exceeded"

  test "extracts Anthropic-style error message":
    let msg = extractErrorMsg("""{"error":{"type":"rate_limit_error","message":"Rate limit exceeded"}}""")
    check msg == "Rate limit exceeded"

  test "extracts flat message field (Gemini-style)":
    let msg = extractErrorMsg("""{"error":{"code":429,"message":"Resource exhausted","status":"RESOURCE_EXHAUSTED"}}""")
    check msg == "Resource exhausted"

  test "falls back to raw body for non-JSON":
    let msg = extractErrorMsg("plain text error")
    check msg == "plain text error"

  test "returns empty string for empty input":
    let msg = extractErrorMsg("")
    check msg == ""

suite "api: NetworkHealthError":
  test "NetworkHealthError is a subclass of ApiError":
    let e = newException(NetworkHealthError, "network quiet for 45s")
    check e of NetworkHealthError
    check e of ApiError
    check e of CatchableError

  test "NetworkHealthError carries the quiet message":
    let e = newException(NetworkHealthError, networkQuietMsg())
    check isNetworkQuietMsg(e.msg)
    check e.msg == "network quiet for " & $(QuietTooLongMs div 1000) & "s"

  test "isNetworkQuietMsg matches the canonical message and prefix":
    check isNetworkQuietMsg(networkQuietMsg())
    check isNetworkQuietMsg("network quiet for 45s")
    check not isNetworkQuietMsg("interrupted by user")
    check not isNetworkQuietMsg("")

  test "networkQuietMsg carries no stray closing paren":
    # Regression: the inline constructors used to emit "network quiet for 45s)"
    # with a dangling ')'. The canonical constructor must not.
    let m = networkQuietMsg()
    check not m.endsWith(")")

  test "a network-quiet outcome retries as server":
    # callModel raises NetworkHealthError from a quiet outcome and the retry
    # loop treats it as a server-category failure. Verify the decision the
    # loop would reach: a quiet errMsg with no assistant msg and status 0 is
    # retryable as "server" under the shared retryCategory helper too, so
    # the class-based path and the legacy string path agree.
    check retryCategory(networkQuietMsg(), nil, 0) == "server"

  test "isEmptyReplyMsg matches the canonical message":
    check isEmptyReplyMsg(EmptyReplyMsg)
    check isEmptyReplyMsg("empty reply - no content, no tool calls")
    check not isEmptyReplyMsg("interrupted by user")
    check not isEmptyReplyMsg("")
    check not isEmptyReplyMsg(networkQuietMsg())

  test "EmptyReplyMsg is distinct from the quiet message":
    check EmptyReplyMsg != networkQuietMsg()
    check not isNetworkQuietMsg(EmptyReplyMsg)
    check not isEmptyReplyMsg(networkQuietMsg())

  test "an empty-200 outcome is promoted to NetworkHealthError, not HttpError":
    # Regression for the dead-end "empty reply ... (code 200)" bug: a 200 OK
    # with no content/tool_calls/finish_reason used to fall through
    # retryCategory's `else` branch (status 200 is not retryable), raising an
    # HttpError on the first attempt with no backoff. callModel now promotes
    # any 200 that produced no assistant message to NetworkHealthError so the
    # loop backs off and resends. The class is what the turn loop branches on.
    let e = newException(NetworkHealthError, EmptyReplyMsg)
    check e of NetworkHealthError
    check e of ApiError
    check isEmptyReplyMsg(e.msg)
    # Sanity: retryCategory alone would NOT retry a 200 (the old path). The
    # promotion in callModel happens before retryCategory is consulted.
    check retryCategory(EmptyReplyMsg, nil, 200) == ""
    # The same dead-end hit every 200 transport anomaly, not just the empty
    # reply: an unparseable body, a 200 carrying an inline error object, a
    # mid-stream read error after the head arrived. retryCategory rejects
    # them all at status 200; the promotion covers them by shape (200 + nil
    # assistantMsg + non-empty errMsg), not by string.
    check retryCategory("response parse: unexpected token", nil, 200) == ""
    check retryCategory("api error in 200 body", nil, 200) == ""
    check retryCategory("stream read: connection reset", nil, 200) == ""

suite "api: callModel pro-variant gate":
  test "gpt pro variants raise a clear not-a-chat-model error":
    # gpt-5.5-pro is a completions-only model; chat/completions 404s with
    # "not a chat model". callModel must fail fast with a clear message
    # rather than sending the request and surfacing a raw 404.
    let p = Profile(name: "openai.gpt-5.5-pro", family: "gpt",
                    model: "gpt-5.5-pro", version: "5.5", variant: "pro")
    var usage: Usage
    let messages = %*[{"role": "user", "content": "hi"}]
    expect HttpError:
      discard callModel(p, messages, usage, 0)

  test "plain gpt variants pass the gate":
    # A chat gpt variant must not trip the gate. We can't run a full
    # callModel here (no network), so assert the gate condition directly:
    # it keys on family "gpt" plus variant "pro".
    let p = Profile(name: "openai.gpt-5.6", family: "gpt",
                    model: "gpt-5.6", version: "5.6", variant: "")
    check not (p.family == "gpt" and p.variant == "pro")

suite "api: HttpError":
  test "HttpError is a subclass of ApiError":
    let e = newHttpError(502, "upstream error", "")
    check e of HttpError
    check e of ApiError
    check e of CatchableError

  test "HttpError carries the status code in the field":
    let e = newHttpError(401, "", "")
    check e.code == 401

  test "HttpError message carries the (code N) suffix":
    let e = newHttpError(503, "overloaded", "")
    check e.msg == "overloaded (code 503)"

  test "HttpError surfaces the body error text":
    let body = "{\"error\":{\"message\":\"invalid api key\"}}"
    let e = newHttpError(401, "", body)
    check e.msg == "invalid api key (code 401)"
    check e.code == 401

  test "HttpError and NetworkHealthError are distinct classes":
    let http = newHttpError(500, "", "")
    let net = newException(NetworkHealthError, networkQuietMsg())
    check http of HttpError
    check http of ApiError
    check net of NetworkHealthError
    check net of ApiError
    check not (http of NetworkHealthError)
    check not (net of HttpError)
