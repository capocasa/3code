import std/[unittest, os, strutils]
import threecode

suite "parseActions":
  test "bash block":
    let s = "Some prose.\n\n```bash\nls -la\n```\nTrailing."
    let a = parseActions(s)
    check a.len == 1
    check a[0].kind == akBash
    check a[0].body.strip == "ls -la"

  test "write block":
    let s = "src/foo.nim\n```\necho \"hi\"\n```\n"
    let a = parseActions(s)
    check a.len == 1
    check a[0].kind == akWrite
    check a[0].path == "src/foo.nim"
    check a[0].body == "echo \"hi\"\n"

  test "patch block with one edit":
    let s = """src/foo.nim
```
<<<<<<< SEARCH
old
=======
new
>>>>>>> REPLACE
```
"""
    let a = parseActions(s)
    check a.len == 1
    check a[0].kind == akPatch
    check a[0].path == "src/foo.nim"
    check a[0].edits.len == 1
    check a[0].edits[0][0] == "old\n"
    check a[0].edits[0][1] == "new\n"

  test "patch with multiple edits":
    let s = """README.md
```
<<<<<<< SEARCH
one
=======
1
>>>>>>> REPLACE
<<<<<<< SEARCH
two
=======
2
>>>>>>> REPLACE
```
"""
    let a = parseActions(s)
    check a.len == 1
    check a[0].kind == akPatch
    check a[0].edits.len == 2

  test "mixed actions in one reply":
    let s = """Plan:

```bash
mkdir -p src
```

src/foo.nim
```
let x = 1
```

Done.
"""
    let a = parseActions(s)
    check a.len == 2
    check a[0].kind == akBash
    check a[1].kind == akWrite

  test "looksLikePath rejects prose":
    check not looksLikePath("Here is the plan")
    check not looksLikePath("```")
    check looksLikePath("src/foo.nim")
    check looksLikePath("README.md")
    check looksLikePath("a/b/c.txt")

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
    let (r, code) = runAction(Action(kind: akWrite, path: p, body: "hi\n"))
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
    let (r, code) = runAction(Action(kind: akPatch, path: p, edits: @[("two", "TWO")]))
    check readFile(p) == "one TWO three\n"
    check "patched" in r
    check code == 0
    removeDir(tmp)

  test "runAction akPatch reports unmatched":
    let tmp = getTempDir() / "3code_test_" & $getCurrentProcessId() & "_p2"
    createDir(tmp)
    let p = tmp / "a.txt"
    writeFile(p, "hello\n")
    let (r, code) = runAction(Action(kind: akPatch, path: p, edits: @[("nope", "x")]))
    check "did not match" in r
    check code != 0
    check readFile(p) == "hello\n"
    removeDir(tmp)
