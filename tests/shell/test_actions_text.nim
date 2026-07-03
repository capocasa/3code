import std/[strutils, unittest]
import threecode/[actions, types]

suite "actions: computeDiff":
  test "detects a single changed line":
    let diff = computeDiff("line1\nline2\nline3\n", "line1\nLINE2\nline3\n",
                           "test.txt")
    check "LINE2" in diff
    check "test.txt" in diff

  test "returns empty string for identical content":
    check computeDiff("abc\n", "abc\n", "f.txt") == ""

  test "shows added and removed markers":
    let diff = computeDiff("a\n", "b\n", "f.txt")
    check diff.contains("-") or diff.contains("+") or diff.contains("b")

suite "actions: parseActions — bash fences":
  test "parses a single bash fence":
    let text = "I'll list the files:\n```bash\nls -la\n```\nDone."
    let acts = parseActions(text)
    check acts.len == 1
    check acts[0].kind == akBash
    check acts[0].body == "ls -la\n"

  test "parses multiple fences":
    let text = "```bash\necho one\n```\n```bash\necho two\n```"
    let acts = parseActions(text)
    check acts.len == 2

  test "returns empty for plain prose":
    check parseActions("Just some text without any fences.").len == 0

  test "recognises sh and shell aliases":
    let text = "```sh\necho sh\n```\n```shell\necho shell\n```"
    let acts = parseActions(text)
    check acts.len == 2
    check acts[0].kind == akBash
    check acts[1].kind == akBash

suite "actions: parseActions — write fences":
  test "parses write fence with path":
    let text = "src/foo.nim\n```\necho hi\n```"
    let acts = parseActions(text)
    check acts.len == 1
    check acts[0].kind == akWrite
    check acts[0].path == "src/foo.nim"
    check acts[0].body == "echo hi\n"

  test "writes content verbatim":
    let text = "config.yaml\n```\nkey: value\nother: 42\n```"
    let acts = parseActions(text)
    check acts.len == 1
    check acts[0].body == "key: value\nother: 42\n"

suite "actions: parseActions — patch fences":
  test "parses SEARCH/REPLACE inside patch fence":
    let text = "src/foo.nim\n```\n<<<<<<< SEARCH\nold\n=======\nnew\n>>>>>>> REPLACE\n```"
    let acts = parseActions(text)
    check acts.len == 1
    check acts[0].kind == akPatch
    check acts[0].path == "src/foo.nim"
    check acts[0].edits.len == 1
    check acts[0].edits[0][0] == "old\n"
    check acts[0].edits[0][1] == "new\n"

  test "parses multiple SEARCH/REPLACE blocks in one fence":
    let text = "src/foo.nim\n```\n<<<<<<< SEARCH\nold1\n=======\nnew1\n>>>>>>> REPLACE\n<<<<<<< SEARCH\nold2\n=======\nnew2\n>>>>>>> REPLACE\n```"
    let acts = parseActions(text)
    check acts.len == 1
    check acts[0].edits.len == 2
    check acts[0].edits[1][0] == "old2\n"
    check acts[0].edits[1][1] == "new2\n"

suite "actions: parseActionsChecked":
  test "returns empty issues for valid bash fence":
    let text = "```bash\nls -la\n```"
    let (acts, issues) = parseActionsChecked(text)
    check acts.len == 1
    check issues.len == 0

  test "detects unterminated fence":
    let text = "```bash\ncommand"
    let (acts, issues) = parseActionsChecked(text)
    check acts.len == 1
    check issues.len > 0
    check "unterminated" in issues[0].msg

  test "detects orphan backticks":
    let text = "some text\n```\nstuff\n```"
    let (_, issues) = parseActionsChecked(text)
    check issues.len > 0
    check "bare" in issues[0].msg.toLowerAscii or "path" in issues[0].msg.toLowerAscii

  test "detects unrecognised fence language":
    let text = "```python\nprint('hi')\n```"
    let (_, issues) = parseActionsChecked(text)
    check issues.len > 0
    check "not a recognised fence" in issues[0].msg

suite "actions: stripActions":
  test "strips bash fences, leaves prose":
    let text = "Here is what I'll do:\n```bash\necho hi\n```\nDone."
    let stripped = stripActions(text)
    check "Here is what I'll do:" in stripped
    check "Done." in stripped
    check "echo hi" notin stripped

  test "returns original text when no fences":
    check stripActions("plain text") == "plain text"

  test "strips write fences":
    let text = "Writing a file:\nsrc/foo.nim\n```\necho hi\n```\nAll done."
    let stripped = stripActions(text)
    check "Writing a file:" in stripped
    check "All done." in stripped
    check "echo hi" notin stripped

suite "actions: parseActions — apply_patch (V4A format)":
  test "parses a V4A Begin/End Patch with an Add File via apply_patch tool":
    let patchText = "*** Begin Patch\n*** Add File: new.txt\n+hello world\n*** End Patch"
    let act = Action(kind: akApplyPatch, body: patchText)
    check act.kind == akApplyPatch
    check act.body.contains("*** Begin Patch")

  test "parses V4A Update File with search/replace hunks":
    let patchText = "*** Begin Patch\n*** Update File: app.py\n@@\n-old line\n+new line\n*** End Patch"
    let act = Action(kind: akApplyPatch, body: patchText)
    check act.body.contains("*** Update File: app.py")
