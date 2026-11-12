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

  test "sheds an oversized batched tool run so the rebuild fits the cap":
    # Incident shape (zaicode glm-5.3-flash, 2026-11-12): one assistant
    # reply batched ~1900 tool calls, the results ballooned the prompt
    # past the route's limit, and the collapse kept the whole run because
    # the pairing snap-back pins results to their owning assistant. The
    # retry 400'd exactly like the original call and the session was
    # bricked. The retained tail must also fit a byte cap.
    var msgs = newJArray()
    msgs.add %*{"role": "system", "content": "sys"}
    msgs.add %*{"role": "user", "content": "kickoff"}
    var tcs = newJArray()
    for i in 0 ..< 300:
      tcs.add %*{"id": "c" & $i, "type": "function",
                 "function": {"name": "bash",
                             "arguments": "{\"cmd\":\"probe " & $i &
                                          "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}"}}
    msgs.add %*{"role": "assistant", "content": "", "tool_calls": tcs}
    for i in 0 ..< 300:
      msgs.add %*{"role": "tool", "tool_call_id": "c" & $i,
                  "content": repeat("x", 8192)}
    msgs.add %*{"role": "user", "content": "continue"}
    let collapsed = applySummary(msgs, "recap", keepRecent = 4)
    check collapsed > 100
    check len($msgs) <= SummarizeTailCapBytes
    check msgs[0]{"role"}.getStr == "system"
    check SummaryPrefix in msgs[1]{"content"}.getStr
    check msgs[^1]{"content"}.getStr == "continue"
    for m in msgs:
      if m{"role"}.getStr == "tool":
        var found = false
        for prev in msgs:
          let tcs = prev{"tool_calls"}
          if tcs == nil: continue
          for tc in tcs:
            if tc{"id"}.getStr == m{"tool_call_id"}.getStr: found = true
        check found

  test "sheds down to the newest message when each tail entry busts the cap":
    var msgs = newJArray()
    msgs.add %*{"role": "system", "content": "sys"}
    for i in 1..10:
      msgs.add %*{"role": "user", "content": repeat("y", 200_000) & " " & $i}
    let collapsed = applySummary(msgs, "recap", keepRecent = 4)
    check collapsed == 8  # 6 from the middle + 2 shed from the tail head
    check msgs.len == 4   # system + synthetic + the two newest messages
    check msgs[^1]{"content"}.getStr.endsWith("10")
    check msgs[^2]{"content"}.getStr.endsWith("9")

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
