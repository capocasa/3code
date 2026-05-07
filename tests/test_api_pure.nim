import std/[json, unittest]
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
