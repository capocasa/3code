import std/[json, strutils, unittest]
import threecode/[actions, types, util]

suite "actions: stripHarmonyChannel":
  test "strips <|channel|> suffix":
    let act = toolCallToAction("gpt-oss", "shell<|channel|>commentary",
                               %*{"cmd": ["bash", "-lc", "ls"]})
    check act.kind == akBash
    check act.body == "ls"

  test "no suffix returns tool unchanged":
    let act = toolCallToAction("gpt-oss", "shell",
                               %*{"cmd": ["bash", "-lc", "echo hi"]})
    check act.kind == akBash
    check act.body == "echo hi"

suite "actions: previewCmd":
  test "shows first line stripped":
    check previewCmd("  ls -la\nother") == "ls -la"

  test "truncates long lines":
    let longCmd = "echo " & "a".repeat(100)
    let p = previewCmd(longCmd)
    check p.len <= 66
    check p.endsWith("…")

  test "short command unchanged":
    check previewCmd("git status") == "git status"

suite "actions: bannerFor":
  test "bash shows preview":
    let act = Action(kind: akBash, body: "ls -la /tmp")
    check "ls -la /tmp" in bannerFor(act)

  test "read shows path":
    let act = Action(kind: akRead, path: "src/main.nim")
    check bannerFor(act) == "src/main.nim"

  test "read with range shows line numbers":
    let act = Action(kind: akRead, path: "foo.txt", offset: 10, limit: 5)
    let b = bannerFor(act)
    check "foo.txt" in b
    check "10" in b

  test "write shows path and size":
    let act = Action(kind: akWrite, path: "out.txt", body: "hello world!")
    let b = bannerFor(act)
    check "out.txt" in b
    check "B" in b

  test "patch shows path":
    let act = Action(kind: akPatch, path: "fix.nim")
    check bannerFor(act) == "fix.nim"

  test "plan shows item count":
    let act = Action(kind: akPlan, plan: @[PlanItem(text: "a", status: "pending")])
    check "(1 item)" in bannerFor(act)

  test "plan shows plural items":
    let act = Action(kind: akPlan,
                     plan: @[PlanItem(text: "a", status: "pending"),
                             PlanItem(text: "b", status: "pending")])
    check "(2 items)" in bannerFor(act)

  test "webSearch shows query":
    let act = Action(kind: akWebSearch, body: "nim lang")
    check bannerFor(act) == "nim lang"

  test "webFetch shows url":
    let act = Action(kind: akWebFetch, body: "https://example.com")
    check bannerFor(act) == "https://example.com"

  test "clear shows message":
    let act = Action(kind: akClear)
    check bannerFor(act) == "context cleared"

  test "error shows tool name":
    let act = Action(kind: akError, path: "browse_web")
    check "browse_web" in bannerFor(act)

suite "actions: toolCallToAction — read":
  test "parses read with offset and limit":
    let act = toolCallToAction("glm", "read",
                               %*{"path": "a.txt", "offset": 5, "limit": 10})
    check act.kind == akRead
    check act.path == "a.txt"
    check act.offset == 5
    check act.limit == 10

  test "read defaults offset and limit to zero":
    let act = toolCallToAction("glm", "read", %*{"path": "a.txt"})
    check act.kind == akRead
    check act.offset == 0
    check act.limit == 0

suite "actions: toolCallToAction — clear":
  test "clear produces akClear":
    let act = toolCallToAction("glm", "clear", %*{})
    check act.kind == akClear

suite "actions: toolCallToAction — web_search / web_fetch":
  test "web_search on glm":
    let act = toolCallToAction("glm", "web_search", %*{"query": "nim lang"})
    check act.kind == akWebSearch
    check act.body == "nim lang"

  test "web_fetch on glm":
    let act = toolCallToAction("glm", "web_fetch",
                               %*{"url": "https://example.com"})
    check act.kind == akWebFetch
    check act.body == "https://example.com"

suite "actions: computeDiff edge cases":
  test "empty before, non-empty after":
    let d = computeDiff("", "new content\n", "new.txt")
    check "new content" in d

  test "non-empty before, empty after":
    let d = computeDiff("old content\n", "", "del.txt")
    check "old content" in d

  test "multi-line diff shows context":
    let before = "line1\nline2\nline3\nline4\n"
    let after  = "line1\nLINE2\nline3\nLINE4\n"
    let d = computeDiff(before, after, "multi.txt")
    check "LINE2" in d
    check "LINE4" in d
