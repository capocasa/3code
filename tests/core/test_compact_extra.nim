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
