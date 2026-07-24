## Unit tests for the non-streaming HTTP transport path (`callHttp`).
##
## Compiled with `-d:httpStub`: `callHttp` is replaced by `callHttpStub`,
## which serves canned JSON completions from a fixture file (one per call).
## These tests exercise the non-streaming path's body→assistantMsg
## reconstruction, usage parsing, retry categorization, and xml-tool-call
## promotion — without a network.
##
## The complement of `test_streaming_sse.nim` (which drives the real
## `streamHttp` recv loop against canned SSE): together the two cover the
## network/request layer for both transports. The provider stub
## (`-d:providerStub`) covers everything else; sum = full coverage.

import std/[json, os, strutils, unittest]
import threecode/[api, types]

suite "non-streaming body reconstruction (buildBatchAssistantMsg)":
  test "returns nil for a genuinely empty completion":
    check buildBatchAssistantMsg("", "", nil) == nil
    check buildBatchAssistantMsg("", "", newJArray()) == nil

  test "builds a content-only assistant message with reasoning_content":
    let msg = buildBatchAssistantMsg("hello world", "thinking", newJArray())
    check msg != nil
    check msg{"role"}.getStr == "assistant"
    check msg{"content"}.getStr == "hello world"
    check msg{"reasoning_content"}.getStr == "thinking"
    check "tool_calls" notin msg

  test "builds a tool-call assistant message":
    let tc = %*[{"id": "c1", "type": "function",
                 "function": {"name": "bash", "arguments": "{}"}}]
    let msg = buildBatchAssistantMsg("", "", tc)
    check msg != nil
    check msg{"tool_calls"}.len == 1
    check msg{"tool_calls"}[0]{"function"}{"name"}.getStr == "bash"

suite "non-streaming callModel via httpStub":
  # Each test writes its own fixture and rewinds the stub cursor. callModel
  # routes to callHttp because streamingEnabled is false (set in setup).
  var savedStreaming: bool

  setup:
    savedStreaming = streamingEnabled
    streamingEnabled = false
    resetHttpStubIdx()

  teardown:
    streamingEnabled = savedStreaming
    closeCachedStreamConn()

  proc writeResponses(name, json: string) =
    let path = getTempDir() / name
    writeFile(path, json)
    putEnv("THREECODE_HTTP_STUB_RESPONSES", path)

  proc glmProfile(): Profile =
    Profile(name: "zai.glm-4.7-flash", url: "https://api.z.ai/api/paas/v4",
            key: "stub-key", model: "glm-4.7-flash", family: "glm",
            reasoning: "on")

  test "content round-trips through the non-streaming path":
    writeResponses("tc_http_content.json", """[{
      "choices": [{"index": 0, "message": {"content": "BATCH_OK",
        "reasoning_content": "planning the reply"}, "finish_reason": "stop"}],
      "usage": {"prompt_tokens": 10, "completion_tokens": 3, "total_tokens": 13}
    }]""")
    var usage: Usage
    let msg = callModel(glmProfile(),
      %*[{"role": "user", "content": "say BATCH_OK"}], usage, 0)
    check msg != nil
    check msg{"content"}.getStr == "BATCH_OK"
    check msg{"reasoning_content"}.getStr == "planning the reply"
    check usage.totalTokens == 13
    check usage.completionTokens == 3

  test "tool_calls round-trip and parse":
    writeResponses("tc_http_tools.json", """[{
      "choices": [{"index": 0, "message": {"content": null,
        "tool_calls": [{"id": "call_1", "type": "function",
          "function": {"name": "bash",
            "arguments": "{\"command\":\"echo HELLO\"}"}}]},
        "finish_reason": "tool_calls"}],
      "usage": {"prompt_tokens": 20, "completion_tokens": 8, "total_tokens": 28}
    }]""")
    var usage: Usage
    let msg = callModel(glmProfile(),
      %*[{"role": "user", "content": "run echo HELLO"}], usage, 0)
    check msg != nil
    check msg{"tool_calls"}.len == 1
    let args = msg{"tool_calls"}[0]{"function"}{"arguments"}.getStr
    check parseJson(args){"command"}.getStr == "echo HELLO"
    check usage.totalTokens == 28

  test "cached tokens parsed from prompt_tokens_details":
    writeResponses("tc_http_cached.json", """[{
      "choices": [{"index": 0, "message": {"content": "x"}, "finish_reason": "stop"}],
      "usage": {"prompt_tokens": 100, "completion_tokens": 1, "total_tokens": 101,
        "prompt_tokens_details": {"cached_tokens": 42}}
    }]""")
    var usage: Usage
    discard callModel(glmProfile(),
      %*[{"role": "user", "content": "x"}], usage, 0)
    check usage.cachedTokens == 42

  test "429 then success retries through the shared retry block":
    # First response is a 429 (retryable as 'rate'); second succeeds. The
    # backoff sleep is real, so cap it by keeping retry count low — the
    # default rate backoff for level 0 is 1s.
    writeResponses("tc_http_retry.json", """[
      {"failure": "429", "body": "{\"error\":\"rate limit\"}"},
      {"choices": [{"index": 0, "message": {"content": "AFTER_RETRY"},
        "finish_reason": "stop"}],
       "usage": {"prompt_tokens": 5, "completion_tokens": 2, "total_tokens": 7}}
    ]""")
    var usage: Usage
    let msg = callModel(glmProfile(),
      %*[{"role": "user", "content": "go"}], usage, 0)
    check msg != nil
    check msg{"content"}.getStr == "AFTER_RETRY"

  test "malformed 200 body is retried then surfaces an error, not an empty reply":
    # A 200 with an unparseable body is a transport/protocol error. The first
    # attempt surfaces it; retryCategory treats an empty-assistant transport
    # error as a retryable server error, so it retries. The key assertion is
    # that the non-streaming path never hands back a *silent* empty reply —
    # the streaming bug — it surfaces a real ApiError. Use a 401 (not
    # retryable) after the first malformed 200 so this terminates fast while
    # still exercising the parse-error branch.
    writeResponses("tc_http_badbody.json", """[
      {"status": 200, "body": "this is not json at all"},
      {"status": 401, "body": "{\"error\":\"unauthorized\"}"}
    ]""")
    var usage: Usage
    expect(ApiError):
      discard callModel(glmProfile(),
        %*[{"role": "user", "content": "go"}], usage, 0)

  test "200 with empty message but finish_reason returns a msg, not an error":
    # Empty-content auto-handling is now a turn-loop concern, not a
    # transport-layer one. A 200 with a well-formed but empty message that
    # still carries a finish_reason (length/content_filter/stop) is NOT a
    # transport error: callModel returns a minimal assistant message tagged
    # with finish_reason so runTurns can branch on it (escalate max_tokens on
    # "length", steer on "stop", terminal on "content_filter"). Only the
    # case with no content AND no finish_reason stays a transport error.
    writeResponses("tc_http_empty.json", """[
      {"choices": [{"index": 0, "message": {"content": "", "reasoning_content": ""},
        "finish_reason": "length"}],
       "usage": {"prompt_tokens": 5, "completion_tokens": 0, "total_tokens": 5}}
    ]""")
    var usage: Usage
    let msg = callModel(glmProfile(),
      %*[{"role": "user", "content": "go"}], usage, 0)
    check msg != nil
    check msg{"content"}.getStr == ""
    check msg{"finish_reason"}.getStr == "length"

  test "200 with empty message and no finish_reason surfaces a transport error":
    # The genuinely-empty case (no content, no finish_reason) stays a
    # transport-level error so callModel's network retry block handles it,
    # preserving the layer separation: empty-content auto-handling lives in
    # the turn loop, transport anomalies live here. A following 401
    # terminates after the retry.
    writeResponses("tc_http_empty_noFR.json", """[
      {"choices": [{"index": 0, "message": {"content": "", "reasoning_content": ""}}],
       "usage": {"prompt_tokens": 5, "completion_tokens": 0, "total_tokens": 5}},
      {"status": 401, "body": "{\"error\":\"unauthorized\"}"}
    ]""")
    var usage: Usage
    expect(ApiError):
      discard callModel(glmProfile(),
        %*[{"role": "user", "content": "go"}], usage, 0)

  test "non-retryable status surfaces its error body immediately":
    # 401 is not retryable, so it surfaces on the first attempt — fast, and
    # the error body must reach the user rather than an empty reply.
    writeResponses("tc_http_401.json", """[
      {"status": 401, "body": "{\"error\":\"unauthorized\"}"}
    ]""")
    var usage: Usage
    var raised = false
    try:
      discard callModel(glmProfile(),
        %*[{"role": "user", "content": "go"}], usage, 0)
    except ApiError as e:
      raised = true
      check e.msg.find("unauthorized") >= 0
    check raised

  test "200 with choices[0].error surfaces the provider message":
    # OpenRouter non-streaming provider error: 200 OK with the error
    # embedded in choices[0].error and finish_reason "error". Use a 400
    # (non-retryable) so it surfaces on the first attempt without needing
    # a second stub response for the retry backoff.
    writeResponses("tc_http_200_choice_error.json", """[{
      "choices": [{"index": 0, "message": {"content": ""},
        "finish_reason": "error",
        "error": {"code": 400, "message": "Provider disconnected mid-stream"}}],
      "usage": {"prompt_tokens": 5, "completion_tokens": 0, "total_tokens": 5}
    }]""")
    var usage: Usage
    var raised = false
    try:
      discard callModel(glmProfile(),
        %*[{"role": "user", "content": "go"}], usage, 0)
    except ApiError as e:
      raised = true
      check "Provider disconnected mid-stream" in e.msg
    check raised

  test "200 with top-level error and finish_reason error surfaces the message":
    # Variant: the error is at the top level (j.error) with finish_reason
    # "error" and choices present. Use a 400 (non-retryable) so it surfaces
    # on the first attempt without needing a second stub response.
    writeResponses("tc_http_200_toplevel_error.json", """[{
      "error": {"code": 400, "message": "Rate limit exceeded"},
      "choices": [{"index": 0, "delta": {"content": ""},
        "finish_reason": "error"}]
    }]""")
    var usage: Usage
    var raised = false
    try:
      discard callModel(glmProfile(),
        %*[{"role": "user", "content": "go"}], usage, 0)
    except ApiError as e:
      raised = true
      check "Rate limit exceeded" in e.msg
    check raised

suite "non-streaming xml tool_call promotion":
  # nvidia z-ai/glm4.7 leaks <tool_call> chat-template tags into content
  # instead of the tool_calls field. The shared post-success promotion in
  # callModel lifts them to synthetic tool_calls for BOTH transports.
  var savedStreaming: bool

  setup:
    savedStreaming = streamingEnabled
    streamingEnabled = false
    resetHttpStubIdx()

  teardown:
    streamingEnabled = savedStreaming
    closeCachedStreamConn()

  proc writeResponses(name, json: string) =
    let path = getTempDir() / name
    writeFile(path, json)
    putEnv("THREECODE_HTTP_STUB_RESPONSES", path)

  test "leaked <tool_call> in content is promoted on the non-streaming path":
    writeResponses("tc_http_xml.json", """[{
      "choices": [{"index": 0, "message": {"content":
        "Sure. <tool_call>bash<arg_key>command</arg_key><arg_value>ls -la</arg_value></tool_call> done."},
        "finish_reason": "stop"}],
      "usage": {"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15}
    }]""")
    # nvidia.z-ai/glm4.7 is the known-good combo with xmlToolCalls=true.
    let p = Profile(name: "nvidia.z-ai/glm4.7", url: "https://x/v1",
                    key: "stub-key", model: "z-ai/glm4.7", family: "glm",
                    reasoning: "on")
    var usage: Usage
    let msg = callModel(p,
      %*[{"role": "user", "content": "run ls -la"}], usage, 0)
    check msg != nil
    check msg{"tool_calls"}.len == 1
    let args = msg{"tool_calls"}[0]{"function"}{"arguments"}.getStr
    check parseJson(args){"command"}.getStr == "ls -la"
    # The promoted block is stripped from content.
    check "<tool_call>" notin msg{"content"}.getStr
