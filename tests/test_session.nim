import std/[json, os, osproc, strutils, times, unittest]
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

suite "session: session lock acquire/release":
  # Unique fake session per test so we never touch real sessions and tests
  # don't race each other.
  var tmpPath: string
  var activeBefore: string

  setup:
    activeBefore = activeLockPath
    tmpPath = getTempDir() / ("3code-test-lock-" & $epochTime().int64 & ".3log")

  teardown:
    if activeLockPath != "": releaseActiveSessionLock()
    # Restore prior global so one test's acquire can't leak into another.
    activeLockPath = activeBefore
    if fileExists(tmpPath): removeFile(tmpPath)
    let lp = sessionLockPathFor(tmpPath)
    if fileExists(lp): removeFile(lp)

  test "acquire creates the lock file holding our pid":
    acquireSessionLock(tmpPath)
    let lp = sessionLockPathFor(tmpPath)
    check fileExists(lp)
    check readFile(lp).strip == $getCurrentProcessId()
    check activeLockPath == lp

  test "acquiring a held lock raises SessionLocked with guidance":
    acquireSessionLock(tmpPath)
    let lp = sessionLockPathFor(tmpPath)
    var msg = ""
    try:
      acquireSessionLock(tmpPath)
      fail()
    except SessionLocked as e:
      msg = e.msg
    # message names the session id, the lock file path, the owner pid,
    # and tells the user how to clear a stale lock
    check sessionIdFromPath(tmpPath) in msg
    check lp in msg
    check $getCurrentProcessId() in msg
    check "stale" in msg.toLowerAscii

  test "releaseSessionLock removes the file":
    acquireSessionLock(tmpPath)
    let lp = sessionLockPathFor(tmpPath)
    check fileExists(lp)
    releaseSessionLock(tmpPath)
    check not fileExists(lp)
    check activeLockPath == ""

  test "releaseActiveSessionLock removes the held file":
    acquireSessionLock(tmpPath)
    let lp = sessionLockPathFor(tmpPath)
    check activeLockPath == lp
    releaseActiveSessionLock()
    check not fileExists(lp)
    check activeLockPath == ""

  test "release of a never-held lock is a no-op":
    releaseSessionLock(tmpPath)
    check activeLockPath == ""

  test "acquire on empty path is a no-op":
    acquireSessionLock("")
    check activeLockPath == ""

  # ---- stale-lock recovery (cross-platform) -------------------------------
  # A lock left behind by a crashed/killed 3code must be reclaimed and
  # acquisition must succeed, not refuse.

  test "stale lock whose owner pid is dead is auto-deleted and acquired":
    # Produce a genuinely-dead pid: spawn a trivial child, wait for it to exit,
    # then write its (now-reaped) pid into the lock as if a 3code had died.
    let sleepCmd = when defined(windows): "cmd /c exit 0" else: "true"
    var p = startProcess(sleepCmd, options = {poEvalCommand})
    let deadPid = p.processID()
    discard p.waitForExit()
    p.close()
    # Sanity: the pid we recorded really is dead. (Extremely unlikely to have
    # been reused instantly, but guard the test's own assumption.)
    check deadPid != getCurrentProcessId()

    let lp = sessionLockPathFor(tmpPath)
    createDir(parentDir(lp))
    writeFile(lp, $deadPid)
    check fileExists(lp)

    # Acquisition should reclaim the stale lock and succeed.
    acquireSessionLock(tmpPath)
    check activeLockPath == lp
    # Our pid now owns it.
    check readFile(lp).strip == $getCurrentProcessId()

  test "corrupt lock (non-numeric pid) is reclaimed and acquired":
    let lp = sessionLockPathFor(tmpPath)
    createDir(parentDir(lp))
    writeFile(lp, "not-a-pid")
    check fileExists(lp)
    # Must not crash; treat unparseable pid as stale and move on.
    acquireSessionLock(tmpPath)
    check activeLockPath == lp
    check readFile(lp).strip == $getCurrentProcessId()

  test "empty lock file is reclaimed and acquired":
    let lp = sessionLockPathFor(tmpPath)
    createDir(parentDir(lp))
    writeFile(lp, "")
    check fileExists(lp)
    acquireSessionLock(tmpPath)
    check activeLockPath == lp
    check readFile(lp).strip == $getCurrentProcessId()
