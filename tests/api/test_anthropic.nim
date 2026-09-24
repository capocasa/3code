## Unit tests for the Anthropic Messages wire translation (anthropic.nim):
## request body, SSE event fan-out, non-streaming reply, and the
## generation-dependent thinking configuration. Transport-level behavior
## (streamHttp over a real socket) lives in tests/stream/test_streaming_sse.nim.

import std/[json, unittest]
import threecode/[anthropic, api, types]

suite "anthropic body translation":
  let p = Profile(name: "anthropic.claude-sonnet-5",
                  model: "claude-sonnet-5", family: "claude")

  test "system extracted, tools flattened, max_tokens required":
    let openAi = %*{
      "model": "claude-sonnet-5",
      "messages": [
        {"role": "system", "content": "you are 3code"},
        {"role": "user", "content": "hi"}
      ],
      "tools": [
        {"type": "function",
         "function": {"name": "bash", "description": "run",
                      "parameters": {"type": "object",
                                     "properties": {"command": {"type": "string"}}}}}
      ],
      "max_tokens": 32768,
      "tool_choice": "auto",
      "stream": true,
      "reasoning_effort": "medium"
    }
    let j = parseJson(anthropicBody(p, openAi))
    check j{"system"}.getStr == "you are 3code"
    check "system" notin j{"messages"}[0]
    check j{"messages"}[0]{"role"}.getStr == "user"
    check j{"messages"}[0]{"content"}[0]{"type"}.getStr == "text"
    check j{"max_tokens"}.getInt == 32768
    check j{"tools"}[0]{"name"}.getStr == "bash"
    check j{"tools"}[0]{"input_schema"}{"properties"}.kind == JObject
    check "function" notin j{"tools"}[0]
    check j{"tool_choice"}{"type"}.getStr == "auto"
    check j{"stream"}.getBool == true
    # never a sampling param on the claude family (4.6+/5.x reject them)
    check "temperature" notin j
    check "top_p" notin j
    # adaptive thinking with an effort knob; no budget on 5.x
    check j{"thinking"}{"type"}.getStr == "adaptive"
    check j{"thinking"}{"display"}.getStr == "summarized"
    check j{"output_config"}{"effort"}.getStr == "medium"
    check "budget_tokens" notin j{"thinking"}
    check "reasoning_effort" notin j

  test "tool loop history: tool_results merge into one user turn":
    let openAi = %*{
      "model": "claude-sonnet-5",
      "messages": [
        {"role": "user", "content": "run it"},
        {"role": "assistant", "content": "",
         "tool_calls": [
           {"id": "toolu_1", "type": "function",
            "function": {"name": "bash", "arguments": "{\"command\":\"ls\"}"}},
           {"id": "toolu_2", "type": "function",
            "function": {"name": "read", "arguments": "{\"path\":\"a\"}"}}
         ]},
        {"role": "tool", "tool_call_id": "toolu_1", "content": "file-a"},
        {"role": "tool", "tool_call_id": "toolu_2", "content": "line1"}
      ],
      "max_tokens": 32768,
      "reasoning_effort": "medium"
    }
    let j = parseJson(anthropicBody(p, openAi))
    check j{"messages"}.len == 3
    let assistant = j{"messages"}[1]
    check assistant{"role"}.getStr == "assistant"
    let blocks = assistant{"content"}
    check blocks[0]{"type"}.getStr == "tool_use"
    check blocks[0]{"id"}.getStr == "toolu_1"
    check blocks[0]{"input"}{"command"}.getStr == "ls"
    check blocks[1]{"type"}.getStr == "tool_use"
    # empty content placeholder is dropped when tool_calls carry the turn
    check blocks.len == 2
    let results = j{"messages"}[2]
    check results{"role"}.getStr == "user"
    check results{"content"}.len == 2
    check results{"content"}[0]{"type"}.getStr == "tool_result"
    check results{"content"}[0]{"tool_use_id"}.getStr == "toolu_1"
    check results{"content"}[0]{"content"}.getStr == "file-a"
    check results{"content"}[1]{"tool_use_id"}.getStr == "toolu_2"

  test "thinking blocks replay as the opening blocks of assistant turns":
    let openAi = %*{
      "model": "claude-sonnet-5",
      "messages": [
        {"role": "user", "content": "run it"},
        {"role": "assistant", "content": "", "reasoning_content": "plan it",
         "reasoning_blocks": [
           {"thinking": "plan it", "signature": "sig-abc"},
           {"redacted": "blob-xyz"}],
         "tool_calls": [
           {"id": "toolu_1", "type": "function",
            "function": {"name": "bash", "arguments": "{}"}}]},
        {"role": "tool", "tool_call_id": "toolu_1", "content": "ok"}
      ],
      "max_tokens": 32768,
      "reasoning_effort": "high"
    }
    let j = parseJson(anthropicBody(p, openAi))
    let blocks = j{"messages"}[1]{"content"}
    check blocks[0]{"type"}.getStr == "thinking"
    check blocks[0]{"signature"}.getStr == "sig-abc"
    check blocks[0]{"thinking"}.getStr == "plan it"
    check blocks[1]{"type"}.getStr == "redacted_thinking"
    check blocks[1]{"data"}.getStr == "blob-xyz"
    check blocks[2]{"type"}.getStr == "tool_use"

  test "missing thinking blocks drop thinking on manual-mode models":
    # claude-haiku-4-5 uses budget mode, where the final assistant turn
    # of a continued tool loop MUST open with a thinking block; without
    # a replayable one the request degrades to thinking-off instead of
    # a 400.
    let haiku = Profile(name: "anthropic.claude-haiku-4-5",
                        model: "claude-haiku-4-5", family: "claude")
    let openAi = %*{
      "model": "claude-haiku-4-5",
      "messages": [
        {"role": "user", "content": "run it"},
        {"role": "assistant", "content": "",
         "tool_calls": [
           {"id": "toolu_1", "type": "function",
            "function": {"name": "bash", "arguments": "{}"}}]},
        {"role": "tool", "tool_call_id": "toolu_1", "content": "ok"}
      ],
      "max_tokens": 32768,
      "reasoning_effort": "medium"
    }
    let j = parseJson(anthropicBody(haiku, openAi))
    check "thinking" notin j
    check "output_config" notin j

  test "haiku budget mode outside a tool loop":
    let haiku = Profile(name: "anthropic.claude-haiku-4-5",
                        model: "claude-haiku-4-5", family: "claude")
    let openAi = %*{
      "model": "claude-haiku-4-5",
      "messages": [
        {"role": "user", "content": "hi"}
      ],
      "max_tokens": 32768,
      "reasoning_effort": "high"
    }
    let j = parseJson(anthropicBody(haiku, openAi))
    check j{"thinking"}{"type"}.getStr == "enabled"
    check j{"thinking"}{"budget_tokens"}.getInt == 16_384
    check j{"thinking"}{"display"}.getStr == "summarized"

  test "tiny max_tokens degrades manual thinking instead of a 400":
    # budget_tokens must leave room for the answer inside max_tokens; a
    # 1-token verify ping cannot fit any budget.
    let haiku = Profile(name: "anthropic.claude-haiku-4-5",
                        model: "claude-haiku-4-5", family: "claude")
    let openAi = %*{
      "model": "claude-haiku-4-5",
      "messages": [{"role": "user", "content": "ping"}],
      "max_tokens": 1}
    check "thinking" notin parseJson(anthropicBody(haiku, openAi))

  test "reasoning off maps per generation":
    let off = %*{
      "model": "claude-sonnet-5",
      "messages": [
        {"role": "user", "content": "hi"},
        {"role": "assistant", "content": "done", "reasoning_content": "hmm",
         "reasoning_blocks": [{"thinking": "hmm", "signature": "s"}]},
        {"role": "user", "content": "go"}],
      "max_tokens": 32768,
      "reasoning_effort": "off"}
    # sonnet-5 (adaptive always-on) accepts disabled; recorded thinking
    # blocks are not replayed while thinking is off
    let jOff = parseJson(anthropicBody(p, off))
    check jOff{"thinking"}{"type"}.getStr == "disabled"
    check jOff{"messages"}[1]{"content"}[0]{"type"}.getStr == "text"
    check jOff{"messages"}[1]{"content"}.len == 1
    # manual-mode 4.5 models just omit the field
    let haiku = Profile(name: "anthropic.claude-haiku-4-5",
                        model: "claude-haiku-4-5", family: "claude")
    check "thinking" notin parseJson(anthropicBody(haiku, off))
    # Opus 5.5 rejects disabled; off degrades to no thinking config
    # (thinking stays on at the model default)
    let opus = Profile(name: "anthropic.claude-opus-5-5",
                       model: "claude-opus-5-5", family: "claude")
    let jo = parseJson(anthropicBody(opus, off))
    check "thinking" notin jo
    check "output_config" notin jo

  test "opus 5.5 asks for drop_block under the binding beta":
    let openAi = %*{
      "model": "claude-opus-5-5",
      "messages": [{"role": "user", "content": "hi"}],
      "max_tokens": 65536,
      "reasoning_effort": "xhigh"}
    let opus = Profile(name: "anthropic.claude-opus-5-5",
                       model: "claude-opus-5-5", family: "claude")
    let j = parseJson(anthropicBody(opus, openAi))
    check j{"thinking"}{"type"}.getStr == "adaptive"
    check j{"thinking"}{"block_binding"}{"prefix_mismatch_behavior"}.getStr ==
      "drop_block"
    check j{"output_config"}{"effort"}.getStr == "xhigh"
    # sonnet-5 never runs the prefix check: no block_binding
    let openAi5 = %*{
      "model": "claude-sonnet-5",
      "messages": [{"role": "user", "content": "hi"}],
      "max_tokens": 65536,
      "reasoning_effort": "high"}
    let j5 = parseJson(anthropicBody(p, openAi5))
    check "block_binding" notin j5{"thinking"}

  test "consecutive assistant messages merge (interrupted turn)":
    let openAi = %*{
      "model": "claude-sonnet-5",
      "messages": [
        {"role": "user", "content": "go"},
        {"role": "assistant", "content": "partial"},
        {"role": "assistant", "content": "more"}
      ],
      "max_tokens": 32768}
    let j = parseJson(anthropicBody(p, openAi))
    check j{"messages"}.len == 2
    check j{"messages"}[1]{"content"}.len == 2

suite "anthropic SSE translation":
  test "full tool-loop stream fans out to OpenAI chunks":
    var st: AnthropicStreamState
    var chunks: seq[string]
    for payload in @[
      """{"type":"message_start","message":{"usage":{"input_tokens":10,"cache_read_input_tokens":5,"cache_creation_input_tokens":2}}}""",
      """{"type":"content_block_start","index":0,"content_block":{"type":"thinking"}}""",
      """{"type":"content_block_delta","index":0,"delta":{"thinking_delta":{"thinking":"plan"}}}""",
      """{"type":"content_block_delta","index":0,"delta":{"signature_delta":{"signature":"sig-1"}}}""",
      """{"type":"content_block_stop","index":0}""",
      """{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_9","name":"bash"}}""",
      """{"type":"content_block_delta","index":1,"delta":{"input_json_delta":{"partial_json":"{\"command\":"}}}""",
      """{"type":"content_block_delta","index":1,"delta":{"input_json_delta":{"partial_json":"\"ls\"}"}}}""",
      """{"type":"content_block_stop","index":1}""",
      """{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":7,"output_tokens_details":{"thinking_tokens":4}}}""",
      """{"type":"message_stop"}"""
    ]:
      chunks.add translateAnthropicEvent(st, payload)
    check chunks[^1] == "[DONE]"
    var sawText = false
    var sawThink = false
    var sawFinish, sawUsage = false
    var toolStart: JsonNode
    var args = ""
    var lastUsage: JsonNode
    var closedBlock: JsonNode
    for c in chunks[0 ..< ^1]:
      let j = parseJson(c)
      if j{"usage"} != nil:
        sawUsage = true
        lastUsage = j{"usage"}
      if j{"choices"} == nil: continue
      let fr = j{"choices"}[0]{"finish_reason"}
      if fr != nil and fr.kind == JString:
        sawFinish = true
        check fr.getStr == "tool_calls"
      let d = j{"choices"}[0]{"delta"}
      if d{"content"}.getStr("").len > 0: sawText = true
      if d{"reasoning_content"}.getStr("").len > 0: sawThink = true
      if d{"reasoning_block"} != nil: closedBlock = d{"reasoning_block"}
      let tcs = d{"tool_calls"}
      if tcs != nil and tcs.kind == JArray and tcs.len > 0:
        if tcs[0]{"id"}.getStr("") != "": toolStart = tcs[0]
        args &= tcs[0]{"function"}{"arguments"}.getStr("")
    check sawThink and sawFinish and sawUsage
    check lastUsage != nil
    check lastUsage{"prompt_tokens"}.getInt == 17  # 10+5+2
    check lastUsage{"completion_tokens"}.getInt == 7
    check lastUsage{"total_tokens"}.getInt == 24
    check lastUsage{"completion_tokens_details"}{"reasoning_tokens"}.getInt == 4
    check toolStart != nil
    check toolStart{"id"}.getStr == "toolu_9"
    check toolStart{"function"}{"name"}.getStr == "bash"
    check args == "{\"command\":\"ls\"}"
    # the closed thinking block round-trips as (thinking, signature)
    check closedBlock != nil
    check closedBlock{"thinking"}.getStr == "plan"
    check closedBlock{"signature"}.getStr == "sig-1"

  test "two thinking blocks in one turn close separately":
    # 5.x progress updates between tool calls: each block accumulates
    # by content-block index and closes on its own content_block_stop.
    var st: AnthropicStreamState
    var chunks: seq[string]
    for payload in @[
      """{"type":"content_block_start","index":0,"content_block":{"type":"thinking"}}""",
      """{"type":"content_block_delta","index":0,"delta":{"thinking_delta":{"thinking":"first"}}}""",
      """{"type":"content_block_delta","index":0,"delta":{"signature_delta":{"signature":"s1"}}}""",
      """{"type":"content_block_stop","index":0}""",
      """{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"t","name":"bash"}}""",
      """{"type":"content_block_stop","index":1}""",
      """{"type":"content_block_start","index":2,"content_block":{"type":"redacted_thinking","data":"opaque"}}""",
      """{"type":"content_block_stop","index":2}"""
    ]:
      chunks.add translateAnthropicEvent(st, payload)
    var blocks: seq[JsonNode]
    for c in chunks:
      let d = parseJson(c){"choices"}[0]{"delta"}
      if d{"reasoning_block"} != nil: blocks.add d{"reasoning_block"}
    check blocks.len == 2
    check blocks[0]{"thinking"}.getStr == "first"
    check blocks[0]{"signature"}.getStr == "s1"
    check blocks[1]{"redacted"}.getStr == "opaque"

  test "error event passes through for the in-band check":
    var st: AnthropicStreamState
    let payload = """{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"""
    let chunks = translateAnthropicEvent(st, payload)
    check chunks == @[payload]

  test "stop_reason mapping":
    for (sr, want) in @[("max_tokens", "length"),
                       ("model_context_window_exceeded", "length"),
                       ("refusal", "content_filter"),
                       ("pause_turn", "stop")]:
      var st: AnthropicStreamState
      var mapped = ""
      let payload = $(%*{"type": "message_delta",
                         "delta": {"stop_reason": sr},
                         "usage": {"output_tokens": 1}})
      for c in translateAnthropicEvent(st, payload):
        let j = parseJson(c)
        if j{"choices"} == nil: continue
        let fr = j{"choices"}[0]{"finish_reason"}
        if fr != nil: mapped = fr.getStr
      check mapped == want

suite "anthropic non-streaming translation":
  test "message with thinking, text, and tool_use":
    let msg = %*{
      "id": "msg_1", "type": "message", "role": "assistant",
      "content": [
        {"type": "thinking", "thinking": "hmm", "signature": "sig-2"},
        {"type": "text", "text": "Running it."},
        {"type": "tool_use", "id": "toolu_3", "name": "bash",
         "input": {"command": "ls"}}
      ],
      "stop_reason": "tool_use",
      "usage": {"input_tokens": 9, "output_tokens": 4,
                "cache_read_input_tokens": 3,
                "output_tokens_details": {"thinking_tokens": 2}}
    }
    let j = translateAnthropicResponse($msg)
    let m = j{"choices"}[0]{"message"}
    check m{"content"}.getStr == "Running it."
    check m{"reasoning_content"}.getStr == "hmm"
    check m{"reasoning_blocks"}[0]{"thinking"}.getStr == "hmm"
    check m{"reasoning_blocks"}[0]{"signature"}.getStr == "sig-2"
    check m{"tool_calls"}[0]{"id"}.getStr == "toolu_3"
    check parseJson(m{"tool_calls"}[0]{"function"}{"arguments"}.getStr){"command"}.getStr == "ls"
    check j{"choices"}[0]{"finish_reason"}.getStr == "tool_calls"
    check j{"usage"}{"prompt_tokens"}.getInt == 12
    check j{"usage"}{"total_tokens"}.getInt == 16
    check j{"usage"}{"prompt_tokens_details"}{"cached_tokens"}.getInt == 3
    check j{"usage"}{"completion_tokens_details"}{"reasoning_tokens"}.getInt == 2

suite "claudecode (Claude subscription) wire":
  let p = Profile(name: "claudecode.claude-sonnet-5",
                  model: "claude-sonnet-5", family: "claude")

  test "the Claude Code line leads the system blocks":
    let openAi = %*{
      "model": "claude-sonnet-5",
      "messages": [
        {"role": "system", "content": "you are the Claude edition of 3code"},
        {"role": "user", "content": "hi"}
      ],
      "max_tokens": 32768,
      "reasoning_effort": "medium"}
    let j = parseJson(anthropicBody(p, openAi))
    check j{"system"}.kind == JArray
    check j{"system"}[0]{"text"}.getStr ==
      "You are Claude Code, Anthropic's official CLI for Claude."
    check j{"system"}[1]{"text"}.getStr == "you are the Claude edition of 3code"
    check j{"thinking"}{"type"}.getStr == "adaptive"

  test "api-key anthropic keeps a plain string system":
    let keyed = Profile(name: "anthropic.claude-sonnet-5",
                        model: "claude-sonnet-5", family: "claude")
    let openAi = %*{
      "model": "claude-sonnet-5",
      "messages": [
        {"role": "system", "content": "you are 3code"},
        {"role": "user", "content": "hi"}],
      "max_tokens": 32768}
    let j = parseJson(anthropicBody(keyed, openAi))
    check j{"system"}.kind == JString
    check j{"system"}.getStr == "you are 3code"

  test "requestUrl pins api.anthropic.com for the subscription twin":
    check requestUrl(p) == "https://api.anthropic.com/v1"
    check endpointUrl(p, responses = false, streaming = true) ==
      "https://api.anthropic.com/v1/messages"
