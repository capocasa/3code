# Impl 5: api.nim pure-logic tests

**New file:** `tests/test_api_pure.nim`
**Module:** `threecode/api`
**Procs covered:** parseUsage, classifyRetry, applyReasoning (which dispatches to applyGptOssReasoning, applyDeepseekReasoning, applyMinimaxReasoning — previously only applyGlmReasoning was tested).

## Approach

All three procs are pure logic: JSON in → value out. No network, no state, no filesystem.

`applyReasoning` dispatches on `Profile.family` — test each family branch. The existing `test_api.nim` already covers GLM reasoning; this file covers the remaining three families plus the two utility procs.

## Imports

```nim
import std/[json, unittest]
import threecode/[api, types]
```

## Test cases

### Suite: "api: parseUsage"

1. **"parses standard OpenAI usage object"**
   ```nim
   let u = parseUsage(%*{
     "prompt_tokens": 100,
     "completion_tokens": 50,
     "total_tokens": 150
   })
   check u.promptTokens == 100
   check u.completionTokens == 50
   check u.totalTokens == 150
   check u.cachedTokens == 0
   ```

2. **"parses cached tokens from prompt_tokens_details"**
   ```nim
   let u = parseUsage(%*{
     "prompt_tokens": 100,
     "completion_tokens": 50,
     "total_tokens": 150,
     "prompt_tokens_details": {"cached_tokens": 40}
   })
   check u.cachedTokens == 40
   ```

3. **"falls back to prompt_cache_hit_tokens (DeepSeek style)"**
   ```nim
   let u = parseUsage(%*{
     "prompt_tokens": 100,
     "completion_tokens": 50,
     "total_tokens": 150,
     "prompt_cache_hit_tokens": 60
   })
   check u.cachedTokens == 60
   ```

4. **"prefers prompt_tokens_details over flat field"**
   ```nim
   let u = parseUsage(%*{
     "prompt_tokens": 100,
     "completion_tokens": 50,
     "total_tokens": 150,
     "prompt_tokens_details": {"cached_tokens": 40},
     "prompt_cache_hit_tokens": 60
   })
   check u.cachedTokens == 40  # details wins
   ```

5. **"returns zeros for nil"**
   ```nim
   let u = parseUsage(nil)
   check u.promptTokens == 0
   check u.totalTokens == 0
   ```

6. **"returns zeros for non-object"**
   ```nim
   let u = parseUsage(newJArray())
   check u.promptTokens == 0
   ```

### Suite: "api: classifyRetry"

7. **"returns 'server' on exception"**
   ```nim
   let e = newException(CatchableError, "connection refused")
   check classifyRetry(e, 0) == "server"
   ```

8. **"returns 'rate' on 429"**
   ```nim
   check classifyRetry(nil, 429) == "rate"
   ```

9. **"returns 'server' on 500"**
   ```nim
   check classifyRetry(nil, 500) == "server"
   ```

10. **"returns 'server' on 502"**
    ```nim
    check classifyRetry(nil, 502) == "server"
    ```

11. **"returns 'server' on 503"**
    ```nim
    check classifyRetry(nil, 503) == "server"
    ```

12. **"returns empty string on 400"**
    ```nim
    check classifyRetry(nil, 400) == ""
    ```

13. **"returns empty string on 200"**
    ```nim
    check classifyRetry(nil, 200) == ""
    ```

14. **"exception takes priority over code"**
    ```nim
    let e = newException(CatchableError, "timeout")
    check classifyRetry(e, 429) == "server"  # exception wins
    ```

### Suite: "api: applyReasoning — gpt-oss"

15. **"sets reasoning_effort for gpt-oss"**
    ```nim
    var body = %*{"stream": true}
    let p = Profile(name: "test.model", family: "gpt-oss", model: "model",
                    reasoning: "high")
    applyReasoning(p, body)
    check body{"reasoning_effort"}.getStr == "high"
    ```

### Suite: "api: applyReasoning — deepseek"

16. **"low disables thinking, sets temperature 0"**
    ```nim
    var body = %*{"stream": true}
    let p = Profile(name: "test.model", family: "deepseek", model: "model",
                    reasoning: "low")
    applyReasoning(p, body)
    check body{"thinking"}{"type"}.getStr == "disabled"
    check body{"temperature"}.getFloat == 0.0
    ```

17. **"medium enables thinking, effort low"**
    ```nim
    var body = %*{"stream": true}
    let p = Profile(name: "test.model", family: "deepseek", model: "model",
                    reasoning: "medium")
    applyReasoning(p, body)
    check body{"thinking"}{"type"}.getStr == "enabled"
    check body{"reasoning_effort"}.getStr == "low"
    check body{"temperature"}.getFloat == 0.0
    ```

18. **"high enables thinking, effort medium"**
    ```nim
    var body = %*{"stream": true}
    let p = Profile(name: "test.model", family: "deepseek", model: "model",
                    reasoning: "high")
    applyReasoning(p, body)
    check body{"thinking"}{"type"}.getStr == "enabled"
    check body{"reasoning_effort"}.getStr == "medium"
    check body{"temperature"}.getFloat == 0.0
    ```

### Suite: "api: applyReasoning — minimax"

19. **"low disables thinking"**
    ```nim
    var body = %*{"stream": true}
    let p = Profile(name: "test.model", family: "minimax", model: "model",
                    reasoning: "low")
    applyReasoning(p, body)
    check body{"chat_template_kwargs"}{"enable_thinking"}.getBool == false
    ```

20. **"medium enables thinking"**
    ```nim
    var body = %*{"stream": true}
    let p = Profile(name: "test.model", family: "minimax", model: "model",
                    reasoning: "medium")
    applyReasoning(p, body)
    check body{"chat_template_kwargs"}{"enable_thinking"}.getBool == true
    ```

21. **"high enables thinking"**
    ```nim
    var body = %*{"stream": true}
    let p = Profile(name: "test.model", family: "minimax", model: "model",
                    reasoning: "high")
    applyReasoning(p, body)
    check body{"chat_template_kwargs"}{"enable_thinking"}.getBool == true
    ```

### Suite: "api: applyReasoning — unknown family"

22. **"no-op for unknown family"**
    ```nim
    var body = %*{"stream": true}
    let p = Profile(name: "test.model", family: "unknown", model: "model",
                    reasoning: "high")
    applyReasoning(p, body)
    check "thinking" notin body
    check "reasoning_effort" notin body
    check "chat_template_kwargs" notin body
    ```

## Notes

- The existing `test_api.nim` already covers `applyGlmReasoning` via `applyReasoning` — don't duplicate those. This file focuses on the three untested families plus the two utility procs.
- `applyReasoning` mutates the `body` JsonNode in place — use `var body` and check the mutated result.
- `classifyRetry` takes a `ref CatchableError` — pass `nil` when testing the code-only path.
- `parseUsage` returns a `Usage` object (from types.nim) with all-zero defaults.
