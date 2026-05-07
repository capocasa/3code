import std/[json, os, strutils, unittest]
import threecode/[session, types]

suite "session: usageFromJson":
  test "parses all fields":
    let j = %*{"promptTokens": 100, "completionTokens": 50,
               "totalTokens": 150, "cachedTokens": 30}
    let u = usageFromJson(j)
    check u.promptTokens == 100
    check u.completionTokens == 50
    check u.totalTokens == 150
    check u.cachedTokens == 30

  test "returns zeros for nil":
    let u = usageFromJson(nil)
    check u.promptTokens == 0
    check u.totalTokens == 0

suite "session: firstUserMessage":
  test "extracts first user message, strips preamble":
    let msgs = %*[
      {"role": "system", "content": "You are helpful."},
      {"role": "user", "content": "<session_context>\ncwd: /tmp\n</session_context>\n\nHello"},
      {"role": "assistant", "content": "Hi"},
      {"role": "user", "content": "Bye"}
    ]
    check firstUserMessage(msgs) == "Hello"

  test "returns empty for empty array":
    check firstUserMessage(newJArray()) == ""

suite "session: renderSession → loadSessionFile round-trip":
  var tmp: string

  setup:
    tmp = getTempDir() / "3code-test-session.3log"

  teardown:
    if fileExists(tmp): removeFile(tmp)

  proc roundTrip(sess: Session, msgs: JsonNode): (Session, JsonNode) =
    let text = renderSession(sess, msgs)
    writeFile(tmp, text)
    loadSessionFile(tmp)

  test "round-trips a simple user/assistant conversation":
    let sess = Session(created: "20250101T120000", profileName: "test",
                       cwd: "/tmp")
    let msgs = %*[
      {"role": "system", "content": "You are helpful."},
      {"role": "user", "content": "Hello"},
      {"role": "assistant", "content": "Hi there"}
    ]
    let (ls, lm) = roundTrip(sess, msgs)
    check ls.created == "20250101T120000"
    check ls.profileName == "test"
    check ls.cwd == "/tmp"
    # System is backfilled by loader
    check lm.len == 3
    check lm[0]["role"].getStr == "system"
    check lm[1]["role"].getStr == "user"
    check lm[1]["content"].getStr == "Hello"
    check lm[2]["role"].getStr == "assistant"
    check lm[2]["content"].getStr == "Hi there"

  test "round-trips assistant with tool_calls":
    let sess = Session(created: "20250101T120000", profileName: "test",
                       cwd: "/tmp")
    let msgs = %*[
      {"role": "system", "content": "sys"},
      {"role": "user", "content": "run ls"},
      {"role": "assistant", "content": "",
       "tool_calls": [{"id": "call_1", "type": "function",
                        "function": {"name": "bash",
                                     "arguments": "{\"command\": \"ls -la\"}"}}]},
      {"role": "tool", "tool_call_id": "call_1", "content": "file.txt"}
    ]
    let (ls, lm) = roundTrip(sess, msgs)
    check lm.len == 4
    check lm[0]["role"].getStr == "system"
    check lm[1]["role"].getStr == "user"
    # assistant with tool_calls
    let a = lm[2]
    check a["role"].getStr == "assistant"
    let tcs = a["tool_calls"]
    check tcs.len == 1
    check tcs[0]["function"]["name"].getStr == "bash"
    check "ls -la" in tcs[0]["function"]["arguments"].getStr
    # tool result
    check lm[3]["role"].getStr == "tool"
    check lm[3]["content"].getStr == "file.txt"
    # toolLog should have one entry
    check ls.toolLog.len == 1

  test "round-trips write action":
    let sess = Session(created: "20250101T120000", profileName: "test",
                       cwd: "/tmp")
    let msgs = %*[
      {"role": "system", "content": "sys"},
      {"role": "user", "content": "write a file"},
      {"role": "assistant", "content": "",
       "tool_calls": [{"id": "call_w", "type": "function",
                        "function": {"name": "write",
                                     "arguments": "{\"path\": \"src/foo.nim\", \"body\": \"echo 1\\n\"}"}}]},
      {"role": "tool", "tool_call_id": "call_w", "content": "wrote 7 bytes"}
    ]
    let (_, lm) = roundTrip(sess, msgs)
    let args = parseJson(lm[2]["tool_calls"][0]["function"]["arguments"].getStr)
    check args["path"].getStr == "src/foo.nim"
    check args["body"].getStr == "echo 1"

  test "round-trips patch action":
    let sess = Session(created: "20250101T120000", profileName: "test",
                       cwd: "/tmp")
    let msgs = %*[
      {"role": "system", "content": "sys"},
      {"role": "user", "content": "patch it"},
      {"role": "assistant", "content": "",
       "tool_calls": [{"id": "call_p", "type": "function",
                        "function": {"name": "patch",
                                     "arguments": "{\"path\": \"a.nim\", \"edits\": [{\"search\": \"old\", \"replace\": \"new\"}]}"}}]},
      {"role": "tool", "tool_call_id": "call_p", "content": "patched 1 edit"}
    ]
    let (_, lm) = roundTrip(sess, msgs)
    let args = parseJson(lm[2]["tool_calls"][0]["function"]["arguments"].getStr)
    check args["path"].getStr == "a.nim"
    check args["edits"][0]["search"].getStr == "old"
    check args["edits"][0]["replace"].getStr == "new"

  test "round-trips usage/tokens":
    let sess = Session(created: "20250101T120000", profileName: "test",
                       cwd: "/tmp")
    let msgs = %*[
      {"role": "system", "content": "sys"},
      {"role": "user", "content": "hi"},
      {"role": "assistant", "content": "yo",
       "usage": {"promptTokens": 200, "completionTokens": 100,
                 "totalTokens": 300, "cachedTokens": 50, "elapsed": 5}}
    ]
    let (ls, _) = roundTrip(sess, msgs)
    check ls.usage.totalTokens == 300
    check ls.usage.promptTokens == 200
    check ls.usage.cachedTokens == 50

  test "round-trips reasoning_content":
    let sess = Session(created: "20250101T120000", profileName: "test",
                       cwd: "/tmp")
    let msgs = %*[
      {"role": "system", "content": "sys"},
      {"role": "user", "content": "think"},
      {"role": "assistant", "content": "answer",
       "reasoning_content": "thinking..."}
    ]
    let (_, lm) = roundTrip(sess, msgs)
    check lm[2]["content"].getStr == "answer"
    check lm[2]["reasoning_content"].getStr == "thinking..."

  test "round-trips session_context / project_notes preamble":
    let sess = Session(created: "20250101T120000", profileName: "test",
                       cwd: "/tmp")
    let content = "<session_context>\ncwd: /tmp\n</session_context>\n\n<project_notes>\n# Notes\n</project_notes>\n\nactual message"
    let msgs = %*[
      {"role": "system", "content": "sys"},
      {"role": "user", "content": content}
    ]
    let (_, lm) = roundTrip(sess, msgs)
    check lm[1]["content"].getStr == content

  test "round-trips plan items (update_plan/todo tool)":
    let sess = Session(created: "20250101T120000", profileName: "test",
                       cwd: "/tmp")
    let msgs = %*[
      {"role": "system", "content": "sys"},
      {"role": "user", "content": "plan"},
      {"role": "assistant", "content": "",
       "tool_calls": [{"id": "call_plan", "type": "function",
                        "function": {"name": "update_plan",
                                     "arguments": "{\"items\": [{\"text\": \"step 1\", \"status\": \"completed\"}, {\"text\": \"step 2\", \"status\": \"pending\"}]}"}}]},
      {"role": "tool", "tool_call_id": "call_plan", "content": "plan updated"}
    ]
    let (ls, lm) = roundTrip(sess, msgs)
    let args = parseJson(lm[2]["tool_calls"][0]["function"]["arguments"].getStr)
    check args["items"].len == 2
    check args["items"][0]["text"].getStr == "step 1"
    check args["items"][0]["status"].getStr == "completed"
    check args["items"][1]["text"].getStr == "step 2"
    # plan should also be rebuilt on the session
    check ls.plan.len == 2

suite "session: sessionIdFromPath":
  test "strips .3log extension":
    check sessionIdFromPath("/some/dir/20250101T120000.3log") == "20250101T120000"

  test "returns full name when no extension":
    check sessionIdFromPath("/some/dir/my-session") == "my-session"
