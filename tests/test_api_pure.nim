import std/[json, tables, unittest]
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

suite "api: applyReasoning — gpt-oss":
  test "sets reasoning_effort for gpt-oss":
    var body = %*{"stream": true}
    let p = Profile(name: "test.model", family: "gpt-oss", model: "model",
                    reasoning: "high")
    applyReasoning(p, body)
    check body{"reasoning_effort"}.getStr == "high"

suite "api: applyReasoning — deepseek":
  test "low disables thinking, sets temperature 0":
    var body = %*{"stream": true}
    let p = Profile(name: "test.model", family: "deepseek", model: "model",
                    reasoning: "low")
    applyReasoning(p, body)
    check body{"thinking"}{"type"}.getStr == "disabled"
    check body{"temperature"}.getFloat == 0.0

  test "medium enables thinking, effort low":
    var body = %*{"stream": true}
    let p = Profile(name: "test.model", family: "deepseek", model: "model",
                    reasoning: "medium")
    applyReasoning(p, body)
    check body{"thinking"}{"type"}.getStr == "enabled"
    check body{"reasoning_effort"}.getStr == "low"
    check body{"temperature"}.getFloat == 0.0

  test "high enables thinking, effort medium":
    var body = %*{"stream": true}
    let p = Profile(name: "test.model", family: "deepseek", model: "model",
                    reasoning: "high")
    applyReasoning(p, body)
    check body{"thinking"}{"type"}.getStr == "enabled"
    check body{"reasoning_effort"}.getStr == "medium"
    check body{"temperature"}.getFloat == 0.0

suite "api: applyReasoning — minimax":
  test "low disables thinking":
    var body = %*{"stream": true}
    let p = Profile(name: "test.model", family: "minimax", model: "model",
                    reasoning: "low")
    applyReasoning(p, body)
    check body{"chat_template_kwargs"}{"enable_thinking"}.getBool == false

  test "medium enables thinking":
    var body = %*{"stream": true}
    let p = Profile(name: "test.model", family: "minimax", model: "model",
                    reasoning: "medium")
    applyReasoning(p, body)
    check body{"chat_template_kwargs"}{"enable_thinking"}.getBool == true

  test "high enables thinking":
    var body = %*{"stream": true}
    let p = Profile(name: "test.model", family: "minimax", model: "model",
                    reasoning: "high")
    applyReasoning(p, body)
    check body{"chat_template_kwargs"}{"enable_thinking"}.getBool == true

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
