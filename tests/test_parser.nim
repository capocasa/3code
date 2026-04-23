import std/[unittest, os, strutils, json]
import threecode

suite "actions":
  test "replaceFirst only replaces first occurrence":
    let (out1, ok) = replaceFirst("a X b X c", "X", "Y")
    check ok
    check out1 == "a Y b X c"
    let (_, miss) = replaceFirst("hello", "zzz", "q")
    check not miss

  test "runAction akWrite creates dirs and file":
    let tmp = getTempDir() / "3code_test_" & $getCurrentProcessId()
    removeDir(tmp)
    let p = tmp / "nested/dir/out.txt"
    let (r, code, _) = runAction(Action(kind: akWrite, path: p, body: "hi\n"))
    check fileExists(p)
    check readFile(p) == "hi\n"
    check "wrote" in r
    check code == 0
    removeDir(tmp)

  test "runAction akPatch applies exact match":
    let tmp = getTempDir() / "3code_test_" & $getCurrentProcessId() & "_p"
    createDir(tmp)
    let p = tmp / "a.txt"
    writeFile(p, "one two three\n")
    let (r, code, diff) = runAction(Action(kind: akPatch, path: p, edits: @[("two", "TWO")]))
    check readFile(p) == "one TWO three\n"
    check "patched" in r
    check code == 0
    check "-one two three" in diff
    check "+one TWO three" in diff
    removeDir(tmp)

  test "runAction akWrite produces diff for existing file":
    let tmp = getTempDir() / "3code_test_" & $getCurrentProcessId() & "_wd"
    createDir(tmp)
    let p = tmp / "a.txt"
    writeFile(p, "old\n")
    let (_, _, diff) = runAction(Action(kind: akWrite, path: p, body: "new\n"))
    check "-old" in diff
    check "+new" in diff
    removeDir(tmp)

  test "runAction akBash separates stdout and stderr":
    let (r, code, _) = runAction(Action(kind: akBash,
      body: "echo out; echo err >&2"))
    check code == 0
    check "out" in r
    check "[stderr]" in r
    check "err" in r

  test "runAction akBash preserves nonzero exit":
    let (r, code, _) = runAction(Action(kind: akBash, body: "false"))
    check code != 0
    check "[exit 1]" in r

  test "runAction akPatch rejects zero edits":
    let (r, code, _) = runAction(Action(kind: akPatch, path: "anything.txt"))
    check code != 0
    check "no edits" in r

  test "runAction akPatch reports unmatched":
    let tmp = getTempDir() / "3code_test_" & $getCurrentProcessId() & "_p2"
    createDir(tmp)
    let p = tmp / "a.txt"
    writeFile(p, "hello\n")
    let (r, code, _) = runAction(Action(kind: akPatch, path: p, edits: @[("nope", "x")]))
    check "did not match" in r
    check code != 0
    check readFile(p) == "hello\n"
    removeDir(tmp)

  test "toolCallToAction bash":
    let a = toolCallToAction("bash", %*{"command": "ls -la"})
    check a.kind == akBash
    check a.body == "ls -la"

  test "toolCallToAction write":
    let a = toolCallToAction("write", %*{
      "path": "src/foo.nim", "body": "echo 1\n"})
    check a.kind == akWrite
    check a.path == "src/foo.nim"
    check a.body == "echo 1\n"

  test "toolCallToAction patch single edit":
    let a = toolCallToAction("patch", %*{
      "path": "a.txt",
      "edits": [{"search": "old", "replace": "new"}]
    })
    check a.kind == akPatch
    check a.path == "a.txt"
    check a.edits.len == 1
    check a.edits[0][0] == "old"
    check a.edits[0][1] == "new"

  test "toolCallToAction patch multiple edits":
    let a = toolCallToAction("patch", %*{
      "path": "README.md",
      "edits": [
        {"search": "one", "replace": "1"},
        {"search": "two", "replace": "2"}
      ]
    })
    check a.kind == akPatch
    check a.edits.len == 2
    check a.edits[1][0] == "two"
    check a.edits[1][1] == "2"

  test "toolCallToAction patch tolerates missing edits":
    let a = toolCallToAction("patch", %*{"path": "x"})
    check a.kind == akPatch
    check a.edits.len == 0

  test "toolCallToAction read whole file":
    let a = toolCallToAction("read", %*{"path": "src/foo.nim"})
    check a.kind == akRead
    check a.path == "src/foo.nim"
    check a.offset == 0
    check a.limit == 0

  test "toolCallToAction read with range":
    let a = toolCallToAction("read", %*{
      "path": "a.txt", "offset": 10, "limit": 5})
    check a.kind == akRead
    check a.offset == 10
    check a.limit == 5

  test "runAction akRead whole file":
    let tmp = getTempDir() / "3code_test_" & $getCurrentProcessId() & "_r"
    createDir(tmp)
    let p = tmp / "a.txt"
    writeFile(p, "one\ntwo\nthree\n")
    let (r, code, _) = runAction(Action(kind: akRead, path: p))
    check code == 0
    check r == "one\ntwo\nthree\n"
    removeDir(tmp)

  test "runAction akRead line range":
    let tmp = getTempDir() / "3code_test_" & $getCurrentProcessId() & "_r2"
    createDir(tmp)
    let p = tmp / "a.txt"
    writeFile(p, "a\nb\nc\nd\ne\n")
    let (r, code, _) = runAction(Action(kind: akRead, path: p, offset: 2, limit: 2))
    check code == 0
    check r == "b\nc"
    removeDir(tmp)

  test "runAction akRead soft-caps unbounded reads at 2000 lines":
    let tmp = getTempDir() / "3code_test_" & $getCurrentProcessId() & "_rc"
    createDir(tmp)
    let p = tmp / "big.txt"
    var buf = ""
    for i in 1..3000:
      buf.add $i & "\n"
    writeFile(p, buf)
    let (r, code, _) = runAction(Action(kind: akRead, path: p))
    check code == 0
    check "file is 3000 lines" in r
    check "showed 2000 lines" in r
    check r.startsWith("1\n")
    removeDir(tmp)

  test "runAction akRead honors explicit limit above cap":
    let tmp = getTempDir() / "3code_test_" & $getCurrentProcessId() & "_rc2"
    createDir(tmp)
    let p = tmp / "big.txt"
    var buf = ""
    for i in 1..3000:
      buf.add $i & "\n"
    writeFile(p, buf)
    let (r, code, _) = runAction(
      Action(kind: akRead, path: p, offset: 1, limit: 2500))
    check code == 0
    check "file is 3000" notin r
    check r.splitLines.len == 2500
    removeDir(tmp)

  test "runAction akRead missing file":
    let (r, code, _) = runAction(Action(kind: akRead, path: "/nonexistent/xyz"))
    check code != 0
    check "does not exist" in r
