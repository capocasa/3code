import std/[json, strutils, unittest]
import threecode/compact

suite "compact: applySummary":
  test "collapses middle, preserves system + keepRecent tail":
    var msgs = newJArray()
    msgs.add %*{"role": "system", "content": "sys"}
    for i in 1..10:
      msgs.add %*{"role": "user", "content": "msg " & $i}
    let collapsed = applySummary(msgs, "recap of earlier turns", keepRecent = 4)
    check collapsed == 6
    check msgs.len == 6  # system + synthetic + 4 tail
    check msgs[0]{"role"}.getStr == "system"
    check msgs[1]{"role"}.getStr == "user"
    check SummaryPrefix in msgs[1]{"content"}.getStr
    check msgs[2]{"content"}.getStr == "msg 7"  # tail starts at 7
    check msgs[5]{"content"}.getStr == "msg 10"

  test "refuses to run with too few messages":
    var msgs = newJArray()
    msgs.add %*{"role": "system", "content": "sys"}
    for i in 1..3:
      msgs.add %*{"role": "user", "content": "msg " & $i}
    check applySummary(msgs, "recap", keepRecent = 4) == 0

  test "refuses to run with no system prompt":
    var msgs = newJArray()
    for i in 1..10:
      msgs.add %*{"role": "user", "content": "msg " & $i}
    check applySummary(msgs, "recap", keepRecent = 4) == 0

  test "refuses empty summary":
    var msgs = newJArray()
    msgs.add %*{"role": "system", "content": "sys"}
    for i in 1..10:
      msgs.add %*{"role": "user", "content": "msg " & $i}
    check applySummary(msgs, "", keepRecent = 4) == 0

  test "does not start the retained suffix on an orphan tool result":
    # keepRecent=2 would otherwise land on result(B) of a parallel [A,B]
    # batch, which Kimi 400s as `tool_call_id is not found`.
    var msgs = newJArray()
    msgs.add %*{"role": "system", "content": "sys"}
    for i in 1..6:
      msgs.add %*{"role": "user", "content": "msg " & $i}
    msgs.add %*{"role": "assistant", "content": "",
                "tool_calls": [
                  {"id": "A", "type": "function",
                   "function": {"name": "bash", "arguments": "{}"}},
                  {"id": "B", "type": "function",
                   "function": {"name": "bash", "arguments": "{}"}}
                ]}
    msgs.add %*{"role": "tool", "tool_call_id": "A", "content": "a"}
    msgs.add %*{"role": "tool", "tool_call_id": "B", "content": "b"}
    # 1 system + 6 users + assistant + 2 tools = 10; keepRecent=2 would
    # start at the last two (A result, B result) without the snap-back.
    let collapsed = applySummary(msgs, "recap", keepRecent = 2)
    check collapsed > 0
    check msgs[0]{"role"}.getStr == "system"
    check msgs[1]{"role"}.getStr == "user"
    check msgs[^3]{"role"}.getStr == "assistant"
    check msgs[^2]{"tool_call_id"}.getStr == "A"
    check msgs[^1]{"tool_call_id"}.getStr == "B"
    for m in msgs:
      if m{"role"}.getStr == "tool":
        var found = false
        for prev in msgs:
          let tcs = prev{"tool_calls"}
          if tcs == nil: continue
          for tc in tcs:
            if tc{"id"}.getStr == m{"tool_call_id"}.getStr: found = true
        check found
