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

import std/[json, os, strutils, times, unittest]
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
    Profile(name: "zai.glm-4.7", url: "https://api.z.ai/api/paas/v4",
            key: "stub-key", model: "glm-4.7", family: "glm",
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
    # A 200 with an unparseable body is a transport/protocol error.
    # callModel promotes any 200 that produced no assistant message to a
    # NetworkHealthError and backs off, so the malformed 200 is retried
    # rather than dead-ending as an `HttpError (code 200)`. A following 401
    # (not retryable) terminates after the retry. The key assertion is that
    # the terminating error is the 401, proving the malformed 200 was
    # retried, and that the non-streaming path never hands back a *silent*
    # empty reply.
    writeResponses("tc_http_badbody.json", """[
      {"status": 200, "body": "this is not json at all"},
      {"status": 401, "body": "{\"error\":\"unauthorized\"}"}
    ]""")
    var usage: Usage
    var raisedCode = 0
    var isHttpErr = false
    try:
      discard callModel(glmProfile(),
        %*[{"role": "user", "content": "go"}], usage, 0)
    except HttpError as e:
      isHttpErr = true
      raisedCode = e.code
    except ApiError:
      discard
    check isHttpErr
    check raisedCode == 401

  test "200 carrying an inline error object (no choices) retries, then a 401 terminates":
    # A 200 OK whose body is a JSON object with an `error` field and no
    # `choices` (z.ai's overloaded message slips through on some paths) is
    # the same transport anomaly shape: statusCode 200, no assistant message.
    # callModel promotes it to a NetworkHealthError and retries; a following
    # 401 terminates.
    writeResponses("tc_http_200_errbody.json", """[
      {"error": {"message": "overloaded", "type": "server_error"}},
      {"status": 401, "body": "{\"error\":\"unauthorized\"}"}
    ]""")
    var usage: Usage
    var raisedCode = 0
    var isHttpErr = false
    try:
      discard callModel(glmProfile(),
        %*[{"role": "user", "content": "go"}], usage, 0)
    except HttpError as e:
      isHttpErr = true
      raisedCode = e.code
    except ApiError:
      discard
    check isHttpErr
    check raisedCode == 401

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

  test "200 with empty message and no finish_reason retries, then a 401 terminates":
    # The genuinely-empty case (no content, no finish_reason) is a transport
    # anomaly: callModel promotes it to a NetworkHealthError and backs off,
    # preserving the layer separation (empty-content auto-handling lives in
    # the turn loop, transport anomalies live here). A following 401 is not
    # retryable, so it terminates after the retry. The raised error must be
    # the 401 HttpError, proving the empty 200 was retried rather than
    # surfaced immediately as a dead-end "empty reply ... (code 200)".
    writeResponses("tc_http_empty_noFR.json", """[
      {"choices": [{"index": 0, "message": {"content": "", "reasoning_content": ""}}],
       "usage": {"prompt_tokens": 5, "completion_tokens": 0, "total_tokens": 5}},
      {"status": 401, "body": "{\"error\":\"unauthorized\"}"}
    ]""")
    var usage: Usage
    var raisedCode = 0
    var raisedMsg = ""
    var isHttpErr = false
    try:
      discard callModel(glmProfile(),
        %*[{"role": "user", "content": "go"}], usage, 0)
    except HttpError as e:
      isHttpErr = true
      raisedCode = e.code
      raisedMsg = e.msg
    except ApiError:
      discard
    # The empty 200 was retried, so the terminating error is the 401, not a
    # 200 HttpError carrying the empty-reply message.
    check isHttpErr
    check raisedCode == 401
    check "unauthorized" in raisedMsg

  test "empty 200 retries with backoff then recovers when content arrives":
    # The fix in action: an empty 200 (no content, no finish_reason) is
    # promoted to a NetworkHealthError and retried with backoff. When a
    # later response carries real content, callModel returns it instead of
    # dead-ending on the first empty reply.
    writeResponses("tc_http_empty_recover.json", """[
      {"choices": [{"index": 0, "message": {"content": "", "reasoning_content": ""}}],
       "usage": {"prompt_tokens": 5, "completion_tokens": 0, "total_tokens": 5}},
      {"choices": [{"index": 0, "message": {"content": "RECOVERED", "reasoning_content": ""},
        "finish_reason": "stop"}],
       "usage": {"prompt_tokens": 5, "completion_tokens": 1, "total_tokens": 6}}
    ]""")
    var usage: Usage
    let msg = callModel(glmProfile(),
      %*[{"role": "user", "content": "go"}], usage, 0)
    check msg != nil
    check msg{"content"}.getStr == "RECOVERED"

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
  # nvidia z-ai/glm-5.3 leaks <tool_call> chat-template tags into content
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
    # nvidia.z-ai/glm-5.3 is the known-good combo with xmlToolCalls=true.
    let p = Profile(name: "nvidia.z-ai/glm-5.3", url: "https://x/v1",
                    key: "stub-key", model: "z-ai/glm-5.3", family: "glm",
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

suite "retry-now through the shared retry block":
  # The `:retry` contract, at the layer that owns it: a stale command is
  # cleared at callModel entry, a mid-loop command aborts the attempt as
  # the RetryNowMsg marker and resends immediately (no backoff, curve
  # reset), and a command during a live backoff skips the remaining wait
  # and retries now with the curve reset — the next failure backs off
  # from the short end again, not where the skipped wait left it.
  var savedStreaming: bool

  setup:
    savedStreaming = streamingEnabled
    streamingEnabled = false
    resetHttpStubIdx()
    resetRetryLevels()
    clearRetryNow()
    clearInterrupted()

  teardown:
    streamingEnabled = savedStreaming
    closeCachedStreamConn()
    clearRetryNow()
    clearInterrupted()

  proc writeResponses(name, json: string) =
    let path = getTempDir() / name
    writeFile(path, json)
    putEnv("THREECODE_HTTP_STUB_RESPONSES", path)

  proc glmProfile(): Profile =
    Profile(name: "zai.glm-4.7", url: "https://api.z.ai/api/paas/v4",
            key: "stub-key", model: "glm-4.7", family: "glm",
            reasoning: "on")

  proc retryAfter(ms: int) {.thread.} =
    sleep ms
    requestTurnRetry("test-timer")

  test "a stale command (no request in flight) does nothing":
    # requestTurnRetry before the call = the command landed during a
    # tool call or between turns. callModel clears it at entry, so the
    # first canned response is used, not aborted-and-resent.
    requestTurnRetry("test-stale")
    writeResponses("tc_retrynow_stale.json", """[
      {"choices": [{"index": 0, "message": {"content": "FIRST"},
        "finish_reason": "stop"}]},
      {"choices": [{"index": 0, "message": {"content": "SECOND"},
        "finish_reason": "stop"}]}
    ]""")
    var usage: Usage
    let msg = callModel(glmProfile(),
      %*[{"role": "user", "content": "go"}], usage, 0)
    check msg != nil
    check msg{"content"}.getStr == "FIRST"

  test "an aborted attempt (RetryNowMsg) resends immediately, no backoff":
    # First response is a canned `:retry` abort; the second succeeds. A
    # backoff here would cost >= 1s (any level), so finishing far under
    # that proves the resend was immediate.
    writeResponses("tc_retrynow_marker.json", """[
      {"failure": "retry-now"},
      {"choices": [{"index": 0, "message": {"content": "AFTER_CTRL_R"},
        "finish_reason": "stop"}]}
    ]""")
    var usage: Usage
    let t0 = epochTime()
    let msg = callModel(glmProfile(),
      %*[{"role": "user", "content": "go"}], usage, 0)
    let elapsed = epochTime() - t0
    check msg != nil
    check msg{"content"}.getStr == "AFTER_CTRL_R"
    check elapsed < 0.9
    # The marker path consumed the flag; it must not leak into the next
    # call's first attempt.
    check not isRetryNow()

  test "a press during the backoff wait retries now":
    # First response is a 429 (backoff >= 1s at any level). A timer
    # fires `:retry` 300ms in; the wait breaks, the resend takes the
    # second response, and the whole call finishes far under the full
    # backoff. The press is consumed, not left armed.
    writeResponses("tc_retrynow_backoff.json", """[
      {"failure": "429", "body": "{\"error\":\"rate limit\"}"},
      {"choices": [{"index": 0, "message": {"content": "SKIPPED_WAIT"},
        "finish_reason": "stop"}]}
    ]""")
    var usage: Usage
    var timer: Thread[int]
    createThread(timer, retryAfter, 300)
    let t0 = epochTime()
    let msg = callModel(glmProfile(),
      %*[{"role": "user", "content": "go"}], usage, 0)
    let elapsed = epochTime() - t0
    joinThread(timer)
    check msg != nil
    check msg{"content"}.getStr == "SKIPPED_WAIT"
    check elapsed < 0.9
    check not isRetryNow()

  test "the skip resets the backoff curve for later failures":
    # Same skip as above; then a second call whose first response is a
    # 429 followed by a 401. The skip reset the curve, so that 429 waits
    # the level-0 1s. Had the skip kept the curve (the old semantics:
    # the level inc below the skipped wait executed), the same 429 would
    # wait the level-1 2s — the < 1.9 bound is the discriminator, and
    # >= 0.9 proves a real level-0 wait ran rather than no wait.
    writeResponses("tc_retrynow_resetcurve.json", """[
      {"failure": "429", "body": "{\"error\":\"rate limit\"}"},
      {"choices": [{"index": 0, "message": {"content": "ONE"},
        "finish_reason": "stop"}]},
      {"failure": "429", "body": "{\"error\":\"rate limit\"}"},
      {"failure": "401", "body": "{\"error\":\"unauthorized\"}"}
    ]""")
    var usage: Usage
    var timer: Thread[int]
    createThread(timer, retryAfter, 300)
    let t0 = epochTime()
    let msg1 = callModel(glmProfile(),
      %*[{"role": "user", "content": "go"}], usage, 0)
    let skipElapsed = epochTime() - t0
    joinThread(timer)
    check msg1 != nil
    check skipElapsed < 0.9
    # Second call: level-0 429 wait (~1s, not the kept-curve 2s), then
    # the 401 terminates.
    let t1 = epochTime()
    var raisedCode = 0
    try:
      discard callModel(glmProfile(),
        %*[{"role": "user", "content": "go"}], usage, 0)
    except HttpError as e:
      raisedCode = e.code
    let fullElapsed = epochTime() - t1
    check raisedCode == 401
    check fullElapsed >= 0.9
    check fullElapsed < 1.9

  test "a full wait after a skip incs normally":
    # The skip flag is per failure: attempt one's skipped wait resets the
    # curve, attempt two's FULL wait (no second `:retry`) must inc it.
    # Call two proves the inc ran: its 429 waits the level-1 2s, not the
    # level-0 1s a stale skip flag (reset instead of inc) would leave.
    writeResponses("tc_retrynow_skipthenfull.json", """[
      {"failure": "429", "body": "{\"error\":\"rate limit\"}"},
      {"failure": "429", "body": "{\"error\":\"rate limit\"}"},
      {"choices": [{"index": 0, "message": {"content": "DONE"},
        "finish_reason": "stop"}]},
      {"failure": "429", "body": "{\"error\":\"rate limit\"}"},
      {"failure": "401", "body": "{\"error\":\"unauthorized\"}"}
    ]""")
    var usage: Usage
    var timer: Thread[int]
    createThread(timer, retryAfter, 300)
    let msg = callModel(glmProfile(),
      %*[{"role": "user", "content": "go"}], usage, 0)
    joinThread(timer)
    check msg != nil
    check msg{"content"}.getStr == "DONE"
    let t1 = epochTime()
    var raisedCode = 0
    try:
      discard callModel(glmProfile(),
        %*[{"role": "user", "content": "go"}], usage, 0)
    except HttpError as e:
      raisedCode = e.code
    let fullElapsed = epochTime() - t1
    check raisedCode == 401
    check fullElapsed >= 1.9

  test "the marker resend resets the curve too":
    # The other retry-now consumption site: the data-less resend. Call
    # one takes a full 429 wait (no timer) and succeeds, leaving
    # rateRetryLevel = 1 under both semantics. Call two is a marker
    # resend ("retry-now" fixture) followed by success — the retry-now
    # branch must zero the level. Call three proves it: its 429 waits
    # the level-0 1s, not the level-1 2s, then the 401 terminates.
    writeResponses("tc_retrynow_marker_reset.json", """[
      {"failure": "429", "body": "{\"error\":\"rate limit\"}"},
      {"choices": [{"index": 0, "message": {"content": "ONE"},
        "finish_reason": "stop"}]},
      {"failure": "retry-now"},
      {"choices": [{"index": 0, "message": {"content": "TWO"},
        "finish_reason": "stop"}]},
      {"failure": "429", "body": "{\"error\":\"rate limit\"}"},
      {"failure": "401", "body": "{\"error\":\"unauthorized\"}"}
    ]""")
    var usage: Usage
    discard callModel(glmProfile(),
      %*[{"role": "user", "content": "go"}], usage, 0)  # full 1s wait
    discard callModel(glmProfile(),
      %*[{"role": "user", "content": "go"}], usage, 0)  # marker: no wait
    let t1 = epochTime()
    var raisedCode = 0
    try:
      discard callModel(glmProfile(),
        %*[{"role": "user", "content": "go"}], usage, 0)
    except HttpError as e:
      raisedCode = e.code
    let fullElapsed = epochTime() - t1
    check raisedCode == 401
    check fullElapsed >= 0.9
    check fullElapsed < 1.9
