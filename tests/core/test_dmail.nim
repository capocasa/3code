## D-mail: model-initiated context pruning. The harness tags assistant
## messages with `[checkpoint N]` markers (kimi family only), and a
## `dmail(checkpoint, message)` tool call truncates the conversation to
## just before that checkpoint and appends the dmail as a user message.

import std/[json, strutils, unittest]
import threecode/turns

proc assistantMsg(content: string): JsonNode =
  %*{"role": "assistant", "content": content}

suite "checkpoint tagging":
  test "tags string content":
    let m = assistantMsg("hello")
    tagCheckpoint(m, 3)
    check m{"content"}.getStr == "[checkpoint 3]\nhello"

  test "skips null content (tool-call-only messages)":
    let m = %*{"role": "assistant", "content": newJNull(),
               "tool_calls": %*[]}
    tagCheckpoint(m, 0)
    check m{"content"}.kind == JNull

  test "skips missing content":
    let m = %*{"role": "assistant"}
    tagCheckpoint(m, 0)
    check m{"content"} == nil

suite "revert history":
  test "truncates before the tagged assistant message":
    var msgs = %*[
      %*{"role": "system", "content": "sys"},
      %*{"role": "user", "content": "task"},
      assistantMsg("[checkpoint 0]\nfirst"),
      %*{"role": "tool", "tool_call_id": "a", "content": "huge output"},
      assistantMsg("[checkpoint 1]\nsecond"),
      %*{"role": "tool", "tool_call_id": "b", "content": "more output"},
      assistantMsg("[checkpoint 2]\nthird, asks for dmail"),
      %*{"role": "tool", "tool_call_id": "c", "content": "dmail ack"},
    ]
    check revertHistory(msgs, 1)
    # Everything from "[checkpoint 1]" onward is gone; the tool result
    # after checkpoint 0's message is kept (its owner survives the cut).
    check msgs.len == 4
    check msgs[^1]{"role"}.getStr == "tool"
    check msgs[^1]{"tool_call_id"}.getStr == "a"

  test "picks the latest matching checkpoint":
    var msgs = %*[
      %*{"role": "system", "content": "sys"},
      %*{"role": "user", "content": "task"},
      assistantMsg("[checkpoint 0]\nfirst"),
      assistantMsg("[checkpoint 0]\nfirst again"),
      assistantMsg("[checkpoint 1]\nsecond"),
    ]
    check revertHistory(msgs, 0)
    check msgs.len == 3

  test "unknown checkpoint leaves the conversation untouched":
    var msgs = %*[
      %*{"role": "system", "content": "sys"},
      %*{"role": "user", "content": "task"},
      assistantMsg("[checkpoint 0]\nfirst"),
    ]
    check not revertHistory(msgs, 7)
    check msgs.len == 3

  test "tool result before the marker is kept with its owner":
    # Keeping a prefix never orphans a tool result: the assistant owner
    # sits immediately before it and survives the cut too.
    var msgs = %*[
      %*{"role": "system", "content": "sys"},
      %*{"role": "user", "content": "task"},
      %*{"role": "assistant", "content": newJNull(),
         "tool_calls": %*[{"id": "a"}]},
      %*{"role": "tool", "tool_call_id": "a", "content": "out"},
      assistantMsg("[checkpoint 1]\nsecond"),
    ]
    check revertHistory(msgs, 1)
    check msgs.len == 4
    check msgs[^1]{"role"}.getStr == "tool"
    check msgs[^2]{"tool_calls"} != nil
