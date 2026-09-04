import std/[json, os, strutils, unittest]
import threecode/[actions, display, types, util]

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

  test "keeps long lines whole":
    let longCmd = "echo " & "a".repeat(100)
    check previewCmd(longCmd) == longCmd

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

  test "write shows path":
    let act = Action(kind: akWrite, path: "out.txt", body: "hello world!")
    check bannerFor(act) == "out.txt"

  test "patch shows path":
    let act = Action(kind: akPatch, path: "fix.nim")
    check bannerFor(act) == "fix.nim"

  test "plan banner is the title, not an item count":
    let act = Action(kind: akPlan, plan: @[PlanItem(text: "a", status: "pending")])
    check bannerFor(act) == "update plan"

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

suite "actions: toolCallToAction — kimi dispatch":
  test "kimi routes bash through the glm/qwen dispatcher":
    let act = toolCallToAction("kimi", "bash", %*{"command": "ls"})
    check act.kind == akBash
    check act.body == "ls"

  test "kimi routes read through the glm/qwen dispatcher":
    let act = toolCallToAction("kimi", "read", %*{"path": "a.txt"})
    check act.kind == akRead
    check act.path == "a.txt"

  test "kimi routes patch through the glm/qwen dispatcher":
    let act = toolCallToAction("kimi", "patch",
                               %*{"path": "f.nim", "edits": []})
    check act.kind == akPatch
    check act.path == "f.nim"

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

  test "binary before is not diffed":
    # Regression: cat-ing or sed -i on an ELF binary leaked raw bytes into
    # the model prompt via the auto-generated mutation diff.
    let before = "ELF\x00\x01\x02\x03binary\x00gunk\n" & "garbage\0\0\n"
    let d = computeDiff(before, "", "tools/hanging_server")
    check "suppressed" in d
    check '\0' notin d

  test "binary after is not diffed":
    let after = "\x00\x01\x02\x03\x00\x01\x02\x03\x00\x01\x02\x03\x00\x01\x02\x03"
    let d = computeDiff("", after, "bin/thing")
    check "suppressed" in d
    check '\0' notin d

suite "runAction write returns new contents":
  test "third tuple value is the file body, not a diff":
    let path = getTempDir() / "write_display_test.txt"
    writeFile(path, "old line\n")
    let act = Action(kind: akWrite, path: path, body: "brand new line\n")
    let (output, code, body) = runAction(act)
    defer: removeFile(path)
    check code == 0
    check "wrote" in output
    check body == "brand new line\n"
    check "old line" notin body

suite "write display uses compact head/tail, not a diff":
  test "no diff markers in rendered bytes":
    let body = "line one\nline two\nline three\n"
    let bytes = toolResultBytes(akWrite, "wrote x.txt (N bytes)", 0, 1, body)
    let s = $bytes
    check "line one" in s
    check "line three" in s
    check "@@ " notin s          # no unified-diff hunk header
    check "--- " notin s         # no diff file header
    check "+++ " notin s         # no diff file header

suite "actions: tool result not empty":
  test "patch returns non-empty result on success":
    let path = getTempDir() / "3code_patch_test.txt"
    writeFile(path, "alpha\nbeta\ngamma\n")
    let act = Action(kind: akPatch, path: path, edits: @[("beta", "beta2")])
    let (output, code, diff) = runAction(act, nil)
    check code == 0
    check output.len > 0

  test "applyPatch returns non-empty result on successful update":
    let path = getTempDir() / "3code_applypatch_test.txt"
    writeFile(path, "x\ny\nz\n")
    let act = Action(
      kind: akApplyPatch,
      body: "*** Begin Patch\n*** Update File: " & path & "\n@@\n x\n-y\n+y2\n z\n*** End Patch\n"
    )
    let (output, code, diff) = runAction(act, nil)
    check code == 0
    check output.len > 0
    check "updated" in output

suite "fuzzy patch matching":
  test "exact match unchanged":
    let (newText, ok, strategy) = fuzzyReplaceFirst(
      "alpha\nbeta\ngamma\n", "beta", "BETA")
    check ok
    check strategy == "exact"
    check newText == "alpha\nBETA\ngamma\n"

  test "indent mismatch still matches":
    let file = "def f():\n    if x:\n        return 1\n    return 2\n"
    let search = "if x:\n  return 1\n"
    let (newText, ok, strategy) = fuzzyReplaceFirst(file, search,
      "if x:\n  return 42\n")
    check ok
    check strategy == "indent"
    check "return 42" in newText
    check newText.contains("def f():")

  test "interior whitespace collapse matches":
    let file = "foo   bar\nbaz\n"
    let search = "foo bar\n"
    let (newText, ok, strategy) = fuzzyReplaceFirst(file, search, "qux\n")
    check ok
    check strategy == "whitespace"
    check newText == "qux\nbaz\n"

  test "no match returns not ok":
    let (newText, ok, strategy) = fuzzyReplaceFirst(
      "one\ntwo\n", "three", "x")
    check not ok
    check strategy == ""
    check newText == "one\ntwo\n"

  test "quoted-line-number prefix stripped":
    # The model copies `12  if x:` from read output (cat -n format).
    let file = "if x:\n  return 1\n"
    let search = "12  if x:\n13    return 1\n"
    let (_, ok, strategy) = fuzzyReplaceFirst(file, search, "y\n")
    check ok
    check strategy == "indent"

  test "real patch action lands via indent strategy":
    let path = getTempDir() / "3code_fuzzy_patch_test.txt"
    writeFile(path, "def f():\n    if x:\n        return 1\n")
    let act = Action(kind: akPatch, path: path,
      edits: @[("if x:\n  return 1\n", "if x:\n  return 99\n")])
    let (output, code, _) = runAction(act, nil)
    defer: removeFile(path)
    check code == 0
    # The replacement is re-anchored to the FILE's per-line indentation:
    # `return 99` lands at the 8-space nesting the matched line had.
    check readFile(path) == "def f():\n    if x:\n        return 99\n"
    check "indent" in output   # strategy note surfaced to the model

suite "semantic exit notes":
  test "grep exit 1 no output":
    let note = semanticExitNote("cd /repo && grep -n foo bar.py", 1, "")
    check "no matches" in note
    check "not an error" in note

  test "rg exit 1 via pipe qualifies on rg":
    let note = semanticExitNote("grep -rn zed src | rg specialthing", 1, "")
    check "no matches" in note

  test "diff exit 1":
    let note = semanticExitNote("diff a.txt b.txt", 1, "1c1\n< x\n---\n> y\n")
    check "files differ" in note

  test "test exit 1":
    let note = semanticExitNote("test -f /tmp/x", 1, "")
    check "condition is false" in note

  test "unrelated program exit 1 gets no note":
    check semanticExitNote("python -m pytest tests/", 1, "FAILURES") == ""

  test "exit codes other than 1 get no note":
    check semanticExitNote("grep foo bar", 2, "") == ""
    check semanticExitNote("grep foo bar", 0, "") == ""
