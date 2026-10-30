## Wire-level assertions for vision content: whatever else a family's
## request builder does (deepseek's reasoning knobs are the motivating
## case — thinking.type/reasoning_effort plus the reasoning_content
## backfill it demands on assistant history), the user message's image
## content array must reach the endpoint verbatim. Uses the httpStub
## transport, which records the outgoing body in `lastHttpStubBody`.
##
## Compiled with `-d:httpStub` via test_http_nonstream.nims.

import std/[json, os, strutils, unittest]
import threecode/[api, types]

suite "vision content on the wire (deepseek)":

  setup:
    streamingEnabled = false
    resetHttpStubIdx()
    lastHttpStubBody = ""

  teardown:
    streamingEnabled = true
    closeCachedStreamConn()

  proc okReply(name: string) =
    let path = getTempDir() / name
    writeFile(path, """[{
      "choices": [{"index": 0, "message": {"content": "ok"},
        "finish_reason": "stop"}],
      "usage": {"prompt_tokens": 10, "completion_tokens": 3, "total_tokens": 13}
    }]""")
    putEnv("THREECODE_HTTP_STUB_RESPONSES", path)

  let dataUri = "data:image/jpeg;base64,/9j/4AAQSkZJRgABAQ"

  proc imageTurn(): JsonNode =
    %*[
      {"role": "user", "content": "look"},
      {"role": "assistant", "content": "reading it"},
      {"role": "user", "content": [
        {"type": "text", "text": "attached: tiny.png (image read)"},
        {"type": "image_url", "image_url": {"url": dataUri}}]}]

  test "first-party deepseek sends image blocks with its thinking knobs":
    # deepseek.deepseek-flash is curated vision; its request carries
    # thinking.type + temperature 0.0 and backfills reasoning_content on
    # assistant history. None of that may flatten the image content
    # array.
    okReply("tc_vision_ds_first.json")
    let p = Profile(name: "deepseek.deepseek-flash",
                    url: "https://api.deepseek.com/v1", key: "k",
                    model: "deepseek-flash", family: "deepseek",
                    reasoning: "low")
    var usage: Usage
    discard callModel(p, imageTurn(), usage, 0)
    let body = parseJson(lastHttpStubBody)
    check body{"thinking"}{"type"}.getStr == "disabled"
    check body{"temperature"}.getFloat == 0.0
    let msgs = body{"messages"}
    check msgs.len == 3
    check msgs[1]{"reasoning_content"}.getStr == ""
    let content = msgs[2]{"content"}
    check content.kind == JArray
    check content.len == 2
    check content[0]{"type"}.getStr == "text"
    check "attached: tiny.png" in content[0]{"text"}.getStr
    check content[1]{"type"}.getStr == "image_url"
    check content[1]{"image_url"}{"url"}.getStr == dataUri

  test "hosted deepseek (vLLM surface) sends image blocks too":
    # The hosted stacks get reasoning_effort instead of thinking.type;
    # same invariant for the image content.
    okReply("tc_vision_ds_hosted.json")
    let p = Profile(name: "openrouter.deepseek/deepseek-v4.1-flash",
                    url: "https://openrouter.ai/api/v1", key: "k",
                    model: "deepseek/deepseek-v4.1-flash",
                    family: "deepseek", reasoning: "low")
    var usage: Usage
    discard callModel(p, imageTurn(), usage, 0)
    let body = parseJson(lastHttpStubBody)
    check body{"reasoning_effort"}.getStr == "none"
    check body{"thinking"} == nil
    let content = body{"messages"}[2]{"content"}
    check content.kind == JArray
    check content[1]{"image_url"}{"url"}.getStr == dataUri
