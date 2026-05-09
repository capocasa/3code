import std/[json, strutils, unittest]
import threecode/[compact, types]

suite "compact: compactHistory":
  test "compacts old tool messages":
    let msgs = %*[
      {"role": "system", "content": "sys"},
      {"role": "user", "content": "hi"},
      {"role": "tool", "tool_call_id": "c1",
       "content": "A very long tool result that is definitely longer than the compacted marker threshold of about fifty characters so it should get replaced"},
      {"role": "assistant", "content": "ok"},
      {"role": "user", "content": "bye"},
      {"role": "assistant", "content": "done"}
    ]
    let n = compactHistory(msgs, keepRecent = 2)
    check n == 1
    check msgs[2]["content"].getStr.startsWith("[compacted")

  test "does not compact recent messages":
    let msgs = %*[
      {"role": "system", "content": "sys"},
      {"role": "user", "content": "hi"},
      {"role": "assistant", "content": "done"}
    ]
    check compactHistory(msgs, keepRecent = 3) == 0

  test "does not compact non-tool messages":
    let msgs = %*[
      {"role": "system", "content": "sys"},
      {"role": "user", "content": "hi"},
      {"role": "assistant", "content": "a very long assistant message that is definitely much much longer than the threshold"},
      {"role": "user", "content": "bye"},
      {"role": "assistant", "content": "done"}
    ]
    check compactHistory(msgs, keepRecent = 2) == 0

  test "returns 0 for nil":
    check compactHistory(nil) == 0

  test "returns 0 for non-array":
    check compactHistory(newJObject()) == 0

  test "skips already-compacted messages":
    let msgs = %*[
      {"role": "system", "content": "sys"},
      {"role": "tool", "content": "[compacted — tool output elided]"},
      {"role": "user", "content": "hi"},
      {"role": "assistant", "content": "done"}
    ]
    check compactHistory(msgs, keepRecent = 2) == 0

  test "skips short tool messages":
    let msgs = %*[
      {"role": "system", "content": "sys"},
      {"role": "tool", "content": "short"},
      {"role": "user", "content": "hi"},
      {"role": "assistant", "content": "done"}
    ]
    check compactHistory(msgs, keepRecent = 2) == 0

suite "compact: supersedeCompact":
  test "supersedes earlier read when later write exists":
    let msgs = %*[
      {"role": "system", "content": "sys"},
      {"role": "user", "content": "read then write"},
      {"role": "assistant", "content": "",
       "tool_calls": [{"id": "c1", "type": "function",
                        "function": {"name": "read",
                                     "arguments": "{\"path\": \"a.nim\"}"}}]},
      {"role": "tool", "tool_call_id": "c1",
       "content": "const x = 1\n# this is a very long file with lots of content that exceeds the threshold marker length so it should be superseded"},
      {"role": "assistant", "content": "",
       "tool_calls": [{"id": "c2", "type": "function",
                        "function": {"name": "write",
                                     "arguments": "{\"path\": \"a.nim\", \"body\": \"const x = 2\\n\"}"}}]},
      {"role": "tool", "tool_call_id": "c2", "content": "wrote 12 bytes"},
      {"role": "user", "content": "thanks"}
    ]
    let n = supersedeCompact(msgs, keepRecent = 2)
    check n >= 1
    check msgs[3]["content"].getStr.startsWith("[superseded")

  test "supersedes earlier write when later write exists":
    let longBody = "const x = 1\n# a very long body that is much much longer than the threshold so it should get superseded by the later write to the same file path"
    let args1 = $(%*{"path": "a.nim", "body": longBody})
    let args2 = $(%*{"path": "a.nim", "body": "const x = 2\n"})
    let msgs = %*[
      {"role": "system", "content": "sys"},
      {"role": "user", "content": "write twice"},
      {"role": "assistant", "content": "",
       "tool_calls": [{"id": "c1", "type": "function",
                        "function": {"name": "write",
                                     "arguments": args1}}]},
      {"role": "tool", "tool_call_id": "c1", "content": "wrote 100 bytes"},
      {"role": "assistant", "content": "",
       "tool_calls": [{"id": "c2", "type": "function",
                        "function": {"name": "write",
                                     "arguments": args2}}]},
      {"role": "tool", "tool_call_id": "c2", "content": "wrote 12 bytes"},
      {"role": "user", "content": "thanks"}
    ]
    let n = supersedeCompact(msgs, keepRecent = 2)
    check n >= 1
    # The earlier write's body in the tool_call should be elided
    let readArgs = parseJson(msgs[2]["tool_calls"][0]["function"]["arguments"].getStr)
    check "body" in readArgs
    check "elided" in readArgs["body"].getStr

  test "does not supersede recent messages":
    let msgs = %*[
      {"role": "system", "content": "sys"},
      {"role": "user", "content": "do stuff"},
      {"role": "assistant", "content": "",
       "tool_calls": [{"id": "c1", "type": "function",
                        "function": {"name": "write",
                                     "arguments": "{\"path\": \"a.nim\", \"body\": \"const x = 1\\n\"}"}}]},
      {"role": "tool", "tool_call_id": "c1", "content": "wrote 12 bytes"}
    ]
    check supersedeCompact(msgs, keepRecent = 2) == 0

  test "returns 0 for nil":
    check supersedeCompact(nil) == 0

  test "returns 0 for array with fewer than 3 messages":
    check supersedeCompact(%*[{"role": "system", "content": "sys"}]) == 0

suite "compact: applySummary":
  test "collapses middle messages into summary":
    let msgs = %*[
      {"role": "system", "content": "sys"},
      {"role": "user", "content": "u1"},
      {"role": "assistant", "content": "a1"},
      {"role": "user", "content": "u2"},
      {"role": "assistant", "content": "a2"},
      {"role": "user", "content": "u3"},
      {"role": "assistant", "content": "a3"},
      {"role": "user", "content": "u4"},
      {"role": "assistant", "content": "a4"},
      {"role": "user", "content": "u5"},
      {"role": "assistant", "content": "a5"},
      {"role": "user", "content": "u6"},
      {"role": "assistant", "content": "a6"}
    ]
    let collapsed = applySummary(msgs, "summary text", keepRecent = 4)
    check collapsed > 0
    check msgs.len == 6  # system + summary_user + 4 recent
    check msgs[0]["role"].getStr == "system"
    check msgs[1]["role"].getStr == "user"
    check msgs[1]["content"].getStr.contains("summary text")
    check msgs[2]["content"].getStr == "u5"  # kept: u5, a5, u6, a6

  test "returns 0 for too few messages":
    let msgs = %*[
      {"role": "system", "content": "sys"},
      {"role": "user", "content": "hi"}
    ]
    check applySummary(msgs, "summary", keepRecent = 2) == 0

  test "returns 0 for empty summary":
    let msgs = %*[
      {"role": "system", "content": "sys"},
      {"role": "user", "content": "u1"},
      {"role": "assistant", "content": "a1"},
      {"role": "user", "content": "u2"},
      {"role": "assistant", "content": "a2"},
      {"role": "user", "content": "u3"},
      {"role": "assistant", "content": "a3"},
      {"role": "user", "content": "u4"}
    ]
    check applySummary(msgs, "", keepRecent = 4) == 0
