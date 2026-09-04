## D-mail: model-initiated context pruning. The harness tags assistant
## messages with a harness-local `checkpoint` field (kimi family only),
## and a `dmail(checkpoint, message)` tool call truncates the
## conversation to just before that checkpoint and appends the dmail as
## a user message. The tag never appears inside message content: an
## in-band marker is visible to the model, which echoes it back.

import std/[json, strutils, unittest]
import threecode/turns

proc assistantMsg(content: string; checkpoint = -1): JsonNode =
  result = %*{"role": "assistant", "content": content}
  if checkpoint >= 0:
    result["checkpoint"] = %checkpoint

suite "checkpoint tagging":
  test "tags with a checkpoint field, content untouched":
    let m = assistantMsg("hello")
    tagCheckpoint(m, 3)
    check m{"content"}.getStr == "hello"
    check m{"checkpoint"}.getInt == 3

  test "tags tool-call-only messages too":
    let m = %*{"role": "assistant", "content": newJNull(),
               "tool_calls": %*[]}
    tagCheckpoint(m, 0)
    check m{"content"}.kind == JNull
    check m{"checkpoint"}.getInt == 0

suite "revert history":
  test "truncates before the tagged assistant message":
    var msgs = %*[
      %*{"role": "system", "content": "sys"},
      %*{"role": "user", "content": "task"},
      assistantMsg("first", checkpoint = 0),
      %*{"role": "tool", "tool_call_id": "a", "content": "huge output"},
      assistantMsg("second", checkpoint = 1),
      %*{"role": "tool", "tool_call_id": "b", "content": "more output"},
      assistantMsg("third, asks for dmail", checkpoint = 2),
      %*{"role": "tool", "tool_call_id": "c", "content": "dmail ack"},
    ]
    check revertHistory(msgs, 1)
    # Everything from checkpoint 1 onward is gone; the tool result
    # after checkpoint 0's message is kept (its owner survives the cut).
    check msgs.len == 4
    check msgs[^1]{"role"}.getStr == "tool"
    check msgs[^1]{"tool_call_id"}.getStr == "a"

  test "picks the latest matching checkpoint":
    var msgs = %*[
      %*{"role": "system", "content": "sys"},
      %*{"role": "user", "content": "task"},
      assistantMsg("first", checkpoint = 0),
      assistantMsg("first again", checkpoint = 0),
      assistantMsg("second", checkpoint = 1),
    ]
    check revertHistory(msgs, 0)
    check msgs.len == 3

  test "unknown checkpoint leaves the conversation untouched":
    var msgs = %*[
      %*{"role": "system", "content": "sys"},
      %*{"role": "user", "content": "task"},
      assistantMsg("first", checkpoint = 0),
    ]
    check not revertHistory(msgs, 7)
    check msgs.len == 3

  test "tool result before the tag is kept with its owner":
    # Keeping a prefix never orphans a tool result: the assistant owner
    # sits immediately before it and survives the cut too.
    var msgs = %*[
      %*{"role": "system", "content": "sys"},
      %*{"role": "user", "content": "task"},
      %*{"role": "assistant", "content": newJNull(),
         "tool_calls": %*[{"id": "a"}]},
      %*{"role": "tool", "tool_call_id": "a", "content": "out"},
      assistantMsg("second", checkpoint = 1),
    ]
    check revertHistory(msgs, 1)
    check msgs.len == 4
    check msgs[^1]{"role"}.getStr == "tool"
    check msgs[^2]{"tool_calls"} != nil
