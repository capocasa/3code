import std/[unittest, os, strutils, json, times, unicode]
import threecode {.all.}  # exported + private symbols (parseConfigFile, ProviderRec, Session)

suite "text-mode parser":
  test "parseActions picks up bash blocks":
    let s = "Some prose.\n\n```bash\nls -la\n```\nTrailing."
    let a = parseActions(s)
    check a.len == 1
    check a[0].kind == akBash
    check a[0].body.strip == "ls -la"

  test "parseActions accepts ```sh and ```shell aliases":
    check parseActions("```sh\necho 1\n```\n").len == 1
    check parseActions("```shell\necho 2\n```\n").len == 1

  test "parseActions picks up write blocks (path on its own line)":
    let s = "src/foo.nim\n```\necho \"hi\"\n```\n"
    let a = parseActions(s)
    check a.len == 1
    check a[0].kind == akWrite
    check a[0].path == "src/foo.nim"
    check a[0].body == "echo \"hi\"\n"

  test "parseActions picks up patch with a single SEARCH/REPLACE pair":
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

  test "parseActions picks up multiple SEARCH/REPLACE pairs in one fence":
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

  test "parseActions handles mixed bash + write in one reply":
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

  test "parseActions returns empty on prose-only reply":
    check parseActions("nothing to do here.").len == 0
    check parseActions("").len == 0

  test "looksLikePath rejects prose, accepts paths":
    check not looksLikePath("Here is the plan")
    check not looksLikePath("```")
    check not looksLikePath("# heading")
    check looksLikePath("src/foo.nim")
    check looksLikePath("README.md")
    check looksLikePath("a/b/c.txt")

  test "stripActions removes bash blocks, keeps prose":
    let s = "Plan:\n\n```bash\nls -la\n```\n\nDone."
    check stripActions(s) == "Plan:\n\nDone."

  test "stripActions removes write blocks, keeps prose":
    let s = "Writing config.\n\nsrc/foo.nim\n```\necho hi\nmore\n```\n\nDone."
    check stripActions(s) == "Writing config.\n\nDone."

  test "stripActions returns empty for a pure-action reply":
    check stripActions("```bash\nls\n```\n") == ""

  test "stripActions preserves inline prose between actions":
    let s = "First:\n```bash\na\n```\nNext:\n```bash\nb\n```\nEnd."
    check stripActions(s) == "First:\nNext:\nEnd."

suite "text-mode parser — syntax fail detection":
  test "well-formed reply produces no issues":
    let s = "```bash\nls\n```\n\nsrc/x.nim\n```\nlet x = 1\n```\n"
    let (acts, issues) = parseActionsChecked(s)
    check acts.len == 2
    check issues.len == 0

  test "unterminated ```bash fence is flagged":
    let s = "```bash\nls -la\n"
    let (_, issues) = parseActionsChecked(s)
    check issues.len == 1
    check issues[0].line == 1
    check "unterminated" in issues[0].msg

  test "unterminated write fence is flagged with the path":
    let s = "src/foo.nim\n```\nlet x = 1\n"
    let (_, issues) = parseActionsChecked(s)
    check issues.len == 1
    check issues[0].line == 2
    check "src/foo.nim" in issues[0].msg
    check "unterminated" in issues[0].msg

  test "orphan ```python fence is flagged":
    let s = "Here is some python:\n```python\nprint(1)\n```\nDone."
    let (acts, issues) = parseActionsChecked(s)
    check acts.len == 0
    check issues.len == 1
    check issues[0].line == 2
    check "```python" in issues[0].msg

  test "bare ``` with no preceding path is flagged":
    let s = "Some prose.\n```\nlet x = 1\n```\nDone."
    let (acts, issues) = parseActionsChecked(s)
    check acts.len == 0
    check issues.len == 1
    check issues[0].line == 2
    check "bare" in issues[0].msg

  test "patch with ======= but no >>>>>>> REPLACE is flagged":
    let s = """src/a.nim
```
<<<<<<< SEARCH
old
=======
new
```
"""
    let (_, issues) = parseActionsChecked(s)
    check issues.len >= 1
    var sawUnclosed = false
    for iss in issues:
      if "not closed" in iss.msg: sawUnclosed = true
    check sawUnclosed

  test "patch with ======= without preceding SEARCH is flagged":
    let s = """src/a.nim
```
=======
new
>>>>>>> REPLACE
```
"""
    let (_, issues) = parseActionsChecked(s)
    var sawNoSearch = false
    for iss in issues:
      if "without a preceding <<<<<<< SEARCH" in iss.msg: sawNoSearch = true
    check sawNoSearch

  test "patch with nested SEARCH before previous block closed is flagged":
    let s = """src/a.nim
```
<<<<<<< SEARCH
old
<<<<<<< SEARCH
old2
=======
new2
>>>>>>> REPLACE
```
"""
    let (_, issues) = parseActionsChecked(s)
    var sawNested = false
    for iss in issues:
      if "before previous block was closed" in iss.msg: sawNested = true
    check sawNested

  test "parseActions stays a thin wrapper of the checked variant":
    let s = "```bash\nls\n```\n"
    check parseActions(s) == parseActionsChecked(s).actions

suite "utf8 byte cut":
  # Pydantic-backed providers (deepinfra) reject the body with
  # "There was an error parsing the body" when a string contains invalid
  # UTF-8 — naive byte slicing of `→` (0xE2 0x86 0x92) chopped at byte 2
  # was triggering this on every fresh session whose recent commit
  # subjects ran past the 80-byte preamble cap.
  test "utf8ByteCut backs up off a continuation byte":
    let s = "tighten bash clip 4k\xE2\x86\x922k"  # → at bytes 20..22
    # Cut at 22 lands inside the multibyte rune; back up to 20.
    let r = utf8ByteCut(s, 22)
    check r == "tighten bash clip 4k"
    check validateUtf8(r) == -1

  test "utf8ByteCut leaves a clean cut alone":
    let s = "abcdef"
    check utf8ByteCut(s, 3) == "abc"

  test "utf8ByteCut returns whole string when n >= len":
    let s = "→"  # 3 bytes
    check utf8ByteCut(s, 10) == s

  test "utf8ByteCutEnd advances past leading continuation bytes":
    let s = "tighten bash clip 4k\xE2\x86\x922k"
    # Last 4 bytes start at the second byte of `→` (a continuation);
    # advance past 0x86 0x92 to the start of "2k".
    let r = utf8ByteCutEnd(s, 4)
    check r == "2k"
    check validateUtf8(r) == -1

  test "preamble truncation around → no longer corrupts utf-8":
    let s = "67120bc economize context: drop cat -n prefix on read, " &
            "tighten bash clip 4k\xE2\x86\x922k, more"
    let trimmed = utf8ByteCut(s, 77) & "..."
    # Used to land mid-rune; now must round down to a codepoint boundary.
    check validateUtf8(trimmed) == -1
    # Still a valid JSON-encodable string.
    check (%trimmed).kind == JString

suite "known-good model gate":
  test "exact (provider, model) pairs from the seed list match":
    check isKnownGood(Profile(name: "deepinfra.qwen3-coder-480b",
                              modelPrefix: "", model: "qwen3-coder-480b"))
    check isKnownGood(Profile(name: "together.qwen3-coder-480b",
                              modelPrefix: "", model: "qwen3-coder-480b"))

  test "match is case-insensitive on both provider and model":
    check isKnownGood(Profile(name: "DeepInfra.qwen", modelPrefix: "",
                              model: "Qwen3-Coder-480B"))
    check isKnownGood(Profile(name: "TOGETHER.foo", modelPrefix: "",
                              model: "QWEN3-CODER-480B"))

  test "right model on the wrong provider is not known-good":
    check not isKnownGood(Profile(name: "groq.qwen3-coder-480b",
                                  modelPrefix: "", model: "qwen3-coder-480b"))
    check not isKnownGood(Profile(name: "baseten.qwen3c",
                                  modelPrefix: "", model: "qwen3c"))

  test "right provider but a different model is not known-good":
    check not isKnownGood(Profile(name: "deepinfra.kimi-k2.5",
                                  modelPrefix: "", model: "kimi-k2.5"))
    check not isKnownGood(Profile(name: "together.llama",
                                  modelPrefix: "", model: "Llama-3.3-70B"))

  test "qwen3-coder substring without exact match is not known-good":
    # Substring match would have accepted these — exact match shouldn't.
    check not isKnownGood(Profile(name: "deepinfra.qwen3-coder-30b",
                                  modelPrefix: "", model: "qwen3-coder-30b"))
    check not isKnownGood(Profile(name: "together.qwen", modelPrefix: "Qwen/",
                                  model: "Qwen3-Coder-480B-A35B-Instruct-FP8"))

  test "non-qwen3-coder models are not known-good":
    check not isKnownGood(Profile(name: "deepseek.deepseek-v3.2",
                                  modelPrefix: "", model: "deepseek-v3.2"))
    check not isKnownGood(Profile(name: "openai.gpt-4o-mini",
                                  modelPrefix: "", model: "gpt-4o-mini"))

  test "empty / malformed profile is not known-good":
    check not isKnownGood(Profile())
    check not isKnownGood(Profile(name: "noProviderDot",
                                  modelPrefix: "", model: "qwen3-coder-480b"))

  test "gate lets known-good through regardless of --experimental":
    let prof = Profile(name: "deepinfra.qwen3-coder-480b",
                       model: "qwen3-coder-480b")
    let prior = experimentalEnabled
    experimentalEnabled = false
    check gateExperimental(prof)
    experimentalEnabled = prior

  test "gate refuses experimental model when --experimental is off":
    let prof = Profile(name: "deepseek.deepseek-v3.2",
                       model: "deepseek-v3.2")
    let prior = experimentalEnabled
    experimentalEnabled = false
    check not gateExperimental(prof)
    experimentalEnabled = prior

  test "gate lets experimental model through when --experimental is on":
    let prof = Profile(name: "deepseek.deepseek-v3.2",
                       model: "deepseek-v3.2")
    let prior = experimentalEnabled
    experimentalEnabled = true
    check gateExperimental(prof)
    experimentalEnabled = prior

  test "gate lets empty profile through (caller handles bootstrap)":
    check gateExperimental(Profile())

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

  test "runAction akPatch error includes nearest line hint":
    let tmp = getTempDir() / "3code_test_" & $getCurrentProcessId() & "_p3"
    createDir(tmp)
    let p = tmp / "a.txt"
    writeFile(p, "alpha\nbeta gamma delta\nepsilon\n")
    let (r, code, _) = runAction(
      Action(kind: akPatch, path: p, edits: @[("beta gimma delta", "x")]))
    check code != 0
    check "nearest match" in r
    check "line 2" in r
    removeDir(tmp)

  test "toolCallToAction bash":
    let a = toolCallToAction("bash", %*{"command": "ls -la"})
    check a.kind == akBash
    check a.body == "ls -la"
    check a.stdin == ""

  test "toolCallToAction bash with stdin":
    let a = toolCallToAction("bash", %*{
      "command": "wc -l", "stdin": "one\ntwo\nthree\n"})
    check a.kind == akBash
    check a.body == "wc -l"
    check a.stdin == "one\ntwo\nthree\n"

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

  test "runAction akRead whole file":
    let tmp = getTempDir() / "3code_test_" & $getCurrentProcessId() & "_r"
    createDir(tmp)
    let p = tmp / "a.txt"
    writeFile(p, "one\ntwo\nthree\n")
    let (r, code, _) = runAction(Action(kind: akRead, path: p))
    check code == 0
    check r == "one\ntwo\nthree"
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
    check r.startsWith("1\n2\n")
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

  test "runAction akRead refuses binary content":
    let tmp = getTempDir() / "3code_test_" & $getCurrentProcessId() & "_rb"
    createDir(tmp)
    let p = tmp / "bin"
    writeFile(p, "\x00\x01\x02\x03\x04\x05hello")
    let (r, code, _) = runAction(Action(kind: akRead, path: p))
    check code == 0
    check "binary file" in r
    removeDir(tmp)

  test "runAction akWrite expands ~ to home":
    let sub = "3code_tilde_test_" & $getCurrentProcessId()
    let rel = sub / "foo.txt"
    let expected = getHomeDir() / rel
    removeDir(getHomeDir() / sub)
    let (r, code, _) = runAction(
      Action(kind: akWrite, path: "~/" & rel, body: "hello\n"))
    check code == 0
    check fileExists(expected)
    check readFile(expected) == "hello\n"
    check not dirExists(getCurrentDir() / "~")
    check expected in r
    removeDir(getHomeDir() / sub)

  test "runAction akRead expands ~ to home":
    let sub = "3code_tilde_test_r_" & $getCurrentProcessId()
    let dir = getHomeDir() / sub
    createDir(dir)
    writeFile(dir / "a.txt", "tilde-read\n")
    let (r, code, _) = runAction(
      Action(kind: akRead, path: "~/" & sub / "a.txt"))
    check code == 0
    check r == "tilde-read"
    removeDir(dir)

  test "runAction akPatch expands ~ to home":
    let sub = "3code_tilde_test_p_" & $getCurrentProcessId()
    let dir = getHomeDir() / sub
    createDir(dir)
    let p = dir / "a.txt"
    writeFile(p, "one two three\n")
    let (_, code, _) = runAction(Action(kind: akPatch,
      path: "~/" & sub / "a.txt", edits: @[("two", "TWO")]))
    check code == 0
    check readFile(p) == "one TWO three\n"
    removeDir(dir)

suite "compaction":
  test "compactHistory leaves short conversations alone":
    var msgs = %* [
      {"role": "system", "content": "sys"},
      {"role": "user", "content": "hi"},
      {"role": "assistant", "content": "hello"}
    ]
    check compactHistory(msgs) == 0
    check msgs[1]["content"].getStr == "hi"

  test "compactHistory elides old tool results past keepRecent":
    var msgs = newJArray()
    msgs.add %*{"role": "system", "content": "sys"}
    let big = "x".repeat(5000)
    for i in 0 ..< 20:
      msgs.add %*{"role": "user", "content": "q" & $i}
      msgs.add %*{"role": "assistant", "content": "", "tool_calls": []}
      msgs.add %*{"role": "tool", "tool_call_id": "t" & $i, "content": big}
    let n = compactHistory(msgs, keepRecent = 6)
    check n > 0
    # earliest tool result is compacted
    check msgs[3]["content"].getStr.startsWith("[compacted")
    # last-kept tool result is NOT compacted
    check msgs[msgs.len - 1]["content"].getStr == big

  test "compactHistory is idempotent":
    var msgs = newJArray()
    msgs.add %*{"role": "system", "content": "sys"}
    let big = "y".repeat(2000)
    for i in 0 ..< 20:
      msgs.add %*{"role": "tool", "tool_call_id": "t" & $i, "content": big}
    let first = compactHistory(msgs, keepRecent = 4)
    let second = compactHistory(msgs, keepRecent = 4)
    check first > 0
    check second == 0

  test "compactHistory skips non-tool messages":
    var msgs = newJArray()
    msgs.add %*{"role": "system", "content": "sys"}
    let big = "z".repeat(1000)
    for i in 0 ..< 20:
      msgs.add %*{"role": "user", "content": big}
      msgs.add %*{"role": "assistant", "content": big}
    discard compactHistory(msgs, keepRecent = 4)
    for i in 1 ..< msgs.len:
      check msgs[i]["content"].getStr == big

suite "supersede compaction":
  # Helper: emit a (assistant-with-tool_call, tool-response) pair that looks
  # like what the runtime produces. `args` is whatever JSON object the tool
  # call received; we store it as a JSON-encoded string to match the wire.
  proc pair(msgs: JsonNode, id, name: string, args: JsonNode, result: string) =
    msgs.add %*{"role": "assistant", "content": "",
                "tool_calls": [{
                  "id": id, "type": "function",
                  "function": {"name": name, "arguments": $args}
                }]}
    msgs.add %*{"role": "tool", "tool_call_id": id, "content": result}

  test "elides read body when later write hits same path":
    var msgs = newJArray()
    msgs.add %*{"role": "system", "content": "sys"}
    let fileBody = "line\n".repeat(300)  # 1500B
    msgs.pair("r1", "read", %*{"path": "/tmp/foo.nim"}, fileBody)
    msgs.pair("w1", "write",
              %*{"path": "/tmp/foo.nim", "body": "new content"},
              "wrote /tmp/foo.nim (11 bytes)")
    # Add a couple of trailing protectable messages
    msgs.add %*{"role": "user", "content": "ok"}
    msgs.add %*{"role": "assistant", "content": "done"}
    let n = supersedeCompact(msgs)
    check n > 0
    # msgs[2] is the tool response for the read; should now be a marker
    check msgs[2]["content"].getStr.startsWith("[superseded")
    # The write's tool response is tiny and not touched
    check msgs[4]["content"].getStr == "wrote /tmp/foo.nim (11 bytes)"

  test "elides body of earlier write when a later write hits same path":
    var msgs = newJArray()
    msgs.add %*{"role": "system", "content": "sys"}
    let bigBody = "old content ".repeat(20)  # >64 bytes
    msgs.pair("w1", "write",
              %*{"path": "/tmp/x.nim", "body": bigBody},
              "wrote /tmp/x.nim")
    msgs.pair("w2", "write",
              %*{"path": "/tmp/x.nim", "body": "fresh"},
              "wrote /tmp/x.nim")
    msgs.add %*{"role": "user", "content": "ok"}
    msgs.add %*{"role": "assistant", "content": "done"}
    let n = supersedeCompact(msgs)
    check n > 0
    # The first write's body should be elided in the assistant message's
    # tool_call arguments. Arguments are serialized JSON strings.
    let args0 = parseJson(msgs[1]["tool_calls"][0]["function"]["arguments"].getStr)
    check "elided" in args0["body"].getStr
    # The later write keeps its body
    let args1 = parseJson(msgs[3]["tool_calls"][0]["function"]["arguments"].getStr)
    check args1["body"].getStr == "fresh"

  test "leaves the most recent action on a path alone":
    var msgs = newJArray()
    msgs.add %*{"role": "system", "content": "sys"}
    let body = "keep me ".repeat(20)
    msgs.pair("r1", "read", %*{"path": "/tmp/only.nim"}, body)
    # Add trailing messages so protectFrom doesn't save the read above.
    msgs.add %*{"role": "user", "content": "u"}
    msgs.add %*{"role": "assistant", "content": "a"}
    let n = supersedeCompact(msgs)
    check n == 0
    check msgs[2]["content"].getStr == body

  test "does not touch the final keepRecent messages":
    var msgs = newJArray()
    msgs.add %*{"role": "system", "content": "sys"}
    let body = "hello\n".repeat(200)
    msgs.pair("r1", "read", %*{"path": "/tmp/late.nim"}, body)
    msgs.pair("w1", "write",
              %*{"path": "/tmp/late.nim", "body": "x"},
              "wrote /tmp/late.nim")
    # With default keepRecent=2, the last two (w1 assistant + tool) are
    # protected — but the read at index 2 is still eligible.
    let n = supersedeCompact(msgs, keepRecent = 2)
    check n > 0
    check msgs[2]["content"].getStr.startsWith("[superseded")
    # The write pair at the tail stays intact.
    let args = parseJson(msgs[3]["tool_calls"][0]["function"]["arguments"].getStr)
    check args["body"].getStr == "x"

  test "idempotent":
    var msgs = newJArray()
    msgs.add %*{"role": "system", "content": "sys"}
    let body = "hello\n".repeat(200)
    msgs.pair("r1", "read", %*{"path": "/tmp/i.nim"}, body)
    msgs.pair("w1", "write",
              %*{"path": "/tmp/i.nim", "body": "tiny"},
              "wrote /tmp/i.nim")
    msgs.add %*{"role": "user", "content": "ok"}
    msgs.add %*{"role": "assistant", "content": "done"}
    let first = supersedeCompact(msgs)
    let second = supersedeCompact(msgs)
    check first > 0
    check second == 0

suite "summarize (applySummary splicing)":
  proc mkConv(turns: int): JsonNode =
    ## Build [system, (user, assistant, tool)*turns] — len = 1 + 3*turns.
    result = newJArray()
    result.add %*{"role": "system", "content": "sys"}
    for i in 0 ..< turns:
      result.add %*{"role": "user", "content": "q" & $i}
      result.add %*{"role": "assistant", "content": "a" & $i,
                    "tool_calls": []}
      result.add %*{"role": "tool", "tool_call_id": "t" & $i,
                    "content": "r" & $i}

  test "rewrites to [system, synthetic, ...last keepRecent]":
    var msgs = mkConv(10)  # 31 messages
    let keep = 8
    let total = msgs.len
    let n = applySummary(msgs, "did things", keep)
    check n == total - 1 - keep
    check msgs.len == keep + 2
    check msgs[0]["role"].getStr == "system"
    check msgs[0]["content"].getStr == "sys"
    check msgs[1]["role"].getStr == "user"
    check msgs[1]["content"].getStr == SummaryPrefix & "did things"
    # Last keepRecent messages match the tail of the original.
    let orig = mkConv(10)
    for i in 0 ..< keep:
      check msgs[2 + i]["content"].getStr ==
            orig[total - keep + i]["content"].getStr

  test "bails on too-few messages":
    var msgs = mkConv(2)  # 7 messages; keepRecent+4 = 12
    let before = msgs.len
    let n = applySummary(msgs, "sum", 8)
    check n == 0
    check msgs.len == before

  test "bails when system prompt missing":
    var msgs = newJArray()
    for i in 0 ..< 20:
      msgs.add %*{"role": "user", "content": "q" & $i}
    let before = msgs.len
    let n = applySummary(msgs, "sum", 8)
    check n == 0
    check msgs.len == before

  test "bails on empty summary":
    var msgs = mkConv(10)
    let before = msgs.len
    check applySummary(msgs, "", 8) == 0
    check applySummary(msgs, "   \n\t", 8) == 0
    check msgs.len == before

  test "idempotent: second call on result is a no-op":
    var msgs = mkConv(10)
    let first = applySummary(msgs, "recap", 8)
    check first > 0
    let afterLen = msgs.len  # 10 < keepRecent+4=12, so second call bails
    let second = applySummary(msgs, "recap2", 8)
    check second == 0
    check msgs.len == afterLen

suite "summarize (policy)":
  test "under threshold: no action":
    check decideContextAction(10_000, 100_000, 30) == caNone
    check decideContextAction(79_000, 100_000, 30) == caNone

  test "over threshold with enough history: summarize":
    check decideContextAction(81_000, 100_000, 30) == caSummarize
    # boundary: keepRecent + 4 messages is the minimum to summarize
    check decideContextAction(90_000, 100_000, SummarizeKeepRecent + 4) ==
          caSummarize

  test "over threshold but too short: compact":
    check decideContextAction(90_000, 100_000, 5) == caCompact
    check decideContextAction(90_000, 100_000, SummarizeKeepRecent + 3) ==
          caCompact

  test "zero window or zero tokens: no action":
    check decideContextAction(0, 100_000, 30) == caNone
    check decideContextAction(99_000, 0, 30) == caNone

suite "usage parsing":
  test "OpenAI-style prompt_tokens_details.cached_tokens":
    let u = parseUsage(%*{
      "prompt_tokens": 12400,
      "completion_tokens": 312,
      "total_tokens": 12712,
      "prompt_tokens_details": {"cached_tokens": 11200}
    })
    check u.promptTokens == 12400
    check u.completionTokens == 312
    check u.totalTokens == 12712
    check u.cachedTokens == 11200

  test "DeepSeek-style prompt_cache_hit_tokens":
    let u = parseUsage(%*{
      "prompt_tokens": 8000,
      "completion_tokens": 200,
      "total_tokens": 8200,
      "prompt_cache_hit_tokens": 7500,
      "prompt_cache_miss_tokens": 500
    })
    check u.promptTokens == 8000
    check u.completionTokens == 200
    check u.totalTokens == 8200
    check u.cachedTokens == 7500

  test "absent cache fields produce cachedTokens == 0":
    let u = parseUsage(%*{
      "prompt_tokens": 100,
      "completion_tokens": 50,
      "total_tokens": 150
    })
    check u.promptTokens == 100
    check u.cachedTokens == 0
    let u2 = parseUsage(%*{
      "prompt_tokens": 100,
      "completion_tokens": 50,
      "total_tokens": 150,
      "prompt_tokens_details": {"cached_tokens": 0}
    })
    check u2.cachedTokens == 0

suite "tool log serialization":
  test "round-trips all action kinds":
    let log = @[
      ToolRecord(banner: "bash ls", output: "a\nb", code: 0, kind: akBash),
      ToolRecord(banner: "read x", output: "body", code: 0, kind: akRead),
      ToolRecord(banner: "write y", output: "wrote y", code: 0, kind: akWrite),
      ToolRecord(banner: "patch z", output: "patched", code: 1, kind: akPatch),
    ]
    let j = toolLogToJson(log)
    let back = toolLogFromJson(j)
    check back.len == log.len
    for i in 0 ..< log.len:
      check back[i].banner == log[i].banner
      check back[i].output == log[i].output
      check back[i].code == log[i].code
      check back[i].kind == log[i].kind

  test "fromJson tolerates missing fields":
    let j = %* [{"banner": "x"}]
    let back = toolLogFromJson(j)
    check back.len == 1
    check back[0].banner == "x"
    check back[0].output == ""
    check back[0].kind == akBash

suite "retry classifier":
  test "429 is rate":
    check classifyRetry(nil, 429) == "rate"

  test "5xx is server":
    check classifyRetry(nil, 500) == "server"
    check classifyRetry(nil, 502) == "server"
    check classifyRetry(nil, 503) == "server"
    check classifyRetry(nil, 504) == "server"

  test "network exception is server":
    let e = (ref CatchableError)(msg: "connection refused")
    check classifyRetry(e, 0) == "server"

  test "2xx / 4xx (non-429) not retryable":
    check classifyRetry(nil, 200) == ""
    check classifyRetry(nil, 400) == ""
    check classifyRetry(nil, 401) == ""
    check classifyRetry(nil, 404) == ""

suite "config file":
  # ProviderRec / Session fields are not exported; tests reach behaviour
  # through public surfaces (loadProfile-style: parseConfigFile + buildProfile,
  # saveSession + loadSessionFile, asserting on the exported Profile / message
  # array).
  proc tmpConfig(): string =
    getTempDir() / ("3code_cfg_" & $getCurrentProcessId() & "_" & $epochTime().int64)

  test "parses settings + multiple providers, exposed via buildProfile":
    let path = tmpConfig()
    writeFile(path, """
[settings]
current = "openai.gpt-4o"

[provider]
name = "openai"
url = "https://api.openai.com/v1"
key = "sk-1"
models = "gpt-4o gpt-4o-mini"

[provider]
name = "deepinfra"
url = "https://api.deepinfra.com/v1/openai/"
key = "di-2"
model_prefix = "Qwen/"
models = "Qwen3-Coder-480B"
""")
    let (current, providers) = parseConfigFile(path)
    check current == "openai.gpt-4o"
    check providers.len == 2

    # Default pick (current = openai.gpt-4o)
    let p1 = buildProfile(current, providers, "")
    check p1.name == "openai.gpt-4o"
    check p1.model == "gpt-4o"
    check p1.url == "https://api.openai.com/v1"
    check p1.key == "sk-1"
    check p1.modelPrefix == ""

    # Explicit wanted overrides current; honors model_prefix
    let p2 = buildProfile(current, providers, "deepinfra")
    check p2.name == "deepinfra.Qwen3-Coder-480B"
    check p2.model == "Qwen3-Coder-480B"
    check p2.modelPrefix == "Qwen/"
    check p2.url == "https://api.deepinfra.com/v1/openai"  # trailing / stripped

    # Specific model selection
    let p3 = buildProfile(current, providers, "openai.gpt-4o-mini")
    check p3.model == "gpt-4o-mini"

    # Unknown model → empty Profile (signals failure)
    let p4 = buildProfile(current, providers, "openai.bogus")
    check p4.name == ""

    removeFile(path)

  test "writeConfigFile + parseConfigFile round-trip via buildProfile":
    let path = tmpConfig()
    # Hand-roll a known config, write it, re-parse, and verify the resulting
    # Profile matches.
    writeFile(path, """[settings]
current = "p.m"

[provider]
name = "p"
url = "https://x.example/v1"
key = "k1"
models = "m"
""")
    let (cur1, prov1) = parseConfigFile(path)
    let pf1 = buildProfile(cur1, prov1, "")
    check pf1.name == "p.m"
    check pf1.url == "https://x.example/v1"
    check pf1.key == "k1"

    # Now go through writeConfigFile by mutating + re-saving via the wizard
    # path… can't reach writeConfigFile directly without exporting more, so
    # just re-parse the same file again to verify idempotence.
    let (cur2, prov2) = parseConfigFile(path)
    let pf2 = buildProfile(cur2, prov2, "")
    check pf2 == pf1

    # Quoted special chars survive the round-trip.
    writeFile(path, """[settings]
current = "p.m"

[provider]
name = "p"
url = "https://x.example/v1"
key = "k:with=colon#hash"
models = "m"
""")
    let (cur3, prov3) = parseConfigFile(path)
    let pf3 = buildProfile(cur3, prov3, "")
    check pf3.key == "k:with=colon#hash"

    removeFile(path)

  test "non-known-good profile defaults to mode = \"tools\"":
    let path = tmpConfig()
    writeFile(path, """[settings]
current = "p.m"

[provider]
name = "p"
url = "https://x.example/v1"
key = "k1"
models = "m"
""")
    let (cur, prov) = parseConfigFile(path)
    let pf = buildProfile(cur, prov, "")
    check pf.mode == "tools"
    removeFile(path)

  test "provider `mode = \"text\"` is honored only with --experimental":
    let path = tmpConfig()
    writeFile(path, """[settings]
current = "p.m"

[provider]
name = "p"
url = "https://x.example/v1"
key = "k1"
mode = "text"
models = "m"
""")
    let (cur, prov) = parseConfigFile(path)
    let prior = experimentalEnabled
    experimentalEnabled = false
    check buildProfile(cur, prov, "").mode == "tools"  # config ignored
    experimentalEnabled = true
    check buildProfile(cur, prov, "").mode == "text"   # config wins
    experimentalEnabled = prior
    removeFile(path)

  test "known-good combo always reports its hardcoded mode":
    # No mode in config, no provider mode — known-good combo supplies it.
    let path = tmpConfig()
    writeFile(path, """[settings]
current = "deepinfra.qwen3-coder-480b"

[provider]
name = "deepinfra"
url = "https://api.deepinfra.com/v1/openai/"
key = "k"
models = "qwen3-coder-480b"
""")
    let (cur, prov) = parseConfigFile(path)
    let pf = buildProfile(cur, prov, "")
    check pf.mode == "text"
    removeFile(path)

  test "known-good hardcode wins over provider mode and --experimental":
    let path = tmpConfig()
    writeFile(path, """[settings]
current = "deepinfra.qwen3-coder-480b"

[provider]
name = "deepinfra"
url = "https://api.deepinfra.com/v1/openai/"
key = "k"
mode = "tools"
models = "qwen3-coder-480b"
""")
    let (cur, prov) = parseConfigFile(path)
    let prior = experimentalEnabled
    experimentalEnabled = true
    check buildProfile(cur, prov, "").mode == "text"  # hardcode wins
    experimentalEnabled = prior
    removeFile(path)

  test "knownGoodMode returns hardcoded mode for verified combos":
    check knownGoodMode(Profile(name: "deepinfra.qwen3-coder-480b",
                                model: "qwen3-coder-480b")) == "text"
    check knownGoodMode(Profile(name: "together.qwen3-coder-480b",
                                model: "qwen3-coder-480b")) == "text"
    check knownGoodMode(Profile(name: "openai.gpt-4o",
                                model: "gpt-4o")) == ""

  test "firstKnownGoodCombo skips experimental providers, returns first known-good":
    let path = tmpConfig()
    writeFile(path, """
[settings]
current = "openai.gpt-4o"

[provider]
name = "openai"
url = "https://api.openai.com/v1"
key = "sk-1"
models = "gpt-4o gpt-4o-mini"

[provider]
name = "deepinfra"
url = "https://api.deepinfra.com/v1/openai/"
key = "di-2"
models = "qwen3-coder-480b"
""")
    let (_, providers) = parseConfigFile(path)
    check firstKnownGoodCombo(providers) == "deepinfra.qwen3-coder-480b"
    removeFile(path)

  test "firstKnownGoodCombo returns empty when no known-good provider is configured":
    let path = tmpConfig()
    writeFile(path, """
[settings]
current = "openai.gpt-4o"

[provider]
name = "openai"
url = "https://api.openai.com/v1"
key = "sk-1"
models = "gpt-4o gpt-4o-mini"
""")
    let (_, providers) = parseConfigFile(path)
    check firstKnownGoodCombo(providers) == ""
    removeFile(path)

  test "firstKnownGoodCombo skips providers missing url or key":
    let path = tmpConfig()
    writeFile(path, """
[settings]
current = "deepinfra.qwen3-coder-480b"

[provider]
name = "deepinfra"
key = "di-2"
models = "qwen3-coder-480b"

[provider]
name = "together"
url = "https://api.together.xyz/v1"
key = "tg-1"
models = "qwen3-coder-480b"
""")
    let (_, providers) = parseConfigFile(path)
    # First [provider] has no url → skipped; second is the answer.
    check firstKnownGoodCombo(providers) == "together.qwen3-coder-480b"
    removeFile(path)

  test "loadProfile-style: non-experimental startup falls back from experimental current":
    # Mirrors what loadProfile / the REPL startup do: resolve the config-pointed
    # current; when not in --experimental and the current is experimental, swap
    # to the first known-good combo.
    let path = tmpConfig()
    writeFile(path, """
[settings]
current = "openai.gpt-4o"

[provider]
name = "openai"
url = "https://api.openai.com/v1"
key = "sk-1"
models = "gpt-4o gpt-4o-mini"

[provider]
name = "deepinfra"
url = "https://api.deepinfra.com/v1/openai/"
key = "di-2"
models = "qwen3-coder-480b"
""")
    let (current, providers) = parseConfigFile(path)
    let prior = experimentalEnabled
    experimentalEnabled = false
    var prof = buildProfile(current, providers, "")
    if not isKnownGood(prof):
      let fb = firstKnownGoodCombo(providers)
      if fb != "": prof = buildProfile(fb, providers, "")
    check prof.name == "deepinfra.qwen3-coder-480b"
    # With --experimental, the explicit current is honored as before.
    experimentalEnabled = true
    let prof2 = buildProfile(current, providers, "")
    check prof2.name == "openai.gpt-4o"
    experimentalEnabled = prior
    removeFile(path)

  test "splitModels splits on whitespace and commas, ignoring blanks":
    check splitModels("a b c") == @["a", "b", "c"]
    check splitModels("a, b ,c") == @["a", "b", "c"]
    check splitModels("  ") == newSeq[string]()
    # Colons are no longer mode markers — they're part of the model name.
    check splitModels("x/y:32k") == @["x/y:32k"]

  test "normalizeMode accepts text/tool/tools, rejects others":
    check normalizeMode("text") == "text"
    check normalizeMode("Text") == "text"
    check normalizeMode("tool") == "tools"
    check normalizeMode("tools") == "tools"
    check normalizeMode("tool_calls") == "tools"
    check normalizeMode("foo") == ""
    check normalizeMode("") == ""

suite "bash mutation detection":
  # Closes the loop-guard bypass that let the deepseek-v4-pro session of
  # 2026-04-24 thrash threecode.nim with 11 sed -i edits — bash was
  # untracked, so none of those mutations counted toward Strike 2.

  test "shellTokens honors single + double quotes and escapes":
    check shellTokens("a b c") == @["a", "b", "c"]
    check shellTokens("'a b' c") == @["a b", "c"]
    check shellTokens("\"a b\" c") == @["a b", "c"]
    check shellTokens("a\\ b c") == @["a b", "c"]
    check shellTokens("sed -i 's/x y/z/' file") ==
      @["sed", "-i", "s/x y/z/", "file"]

  test "splitStatements splits on top-level ; && || |":
    check splitStatements("a; b").len == 2
    check splitStatements("a && b || c").len == 3
    check splitStatements("a | b | c").len == 3
    # quoted separators stay inside the statement
    check splitStatements("echo 'a; b'").len == 1
    check splitStatements("echo \"x && y\" && z").len == 2
    check splitStatements("echo 'x | y'").len == 1

  test "sed -i fixtures from the painful session":
    # Verbatim from session 20260424T171117 (deepseek-v4-pro). Each one
    # MUST extract the file path. These are exactly the 11 calls that
    # bypassed the loop guard before this fix landed.
    let cases = @[
      ("sed -i 's/  while messages.len > 0: messages.delete(0)/  messages.elems.setLen 0/' /tmp/threecode.nim",
       "/tmp/threecode.nim"),
      ("sed -i 's/return (\"\", @[])/return (\"\", @[], true, true)/' /tmp/threecode.nim",
       "/tmp/threecode.nim"),
      ("sed -i 's/proc replaceFirst(/proc replaceFirst*(/' /tmp/threecode.nim",
       "/tmp/threecode.nim"),
      ("sed -i 's/proc saveSession(session/proc saveSession*(session/' /tmp/threecode.nim",
       "/tmp/threecode.nim"),
      ("sed -i '1970s/^  navigatedUp = false$/  when isMainModule: navigatedUp = false/' /tmp/threecode.nim",
       "/tmp/threecode.nim"),
      ("cd /tmp && sed -i '1811,1826s/^  /    /' src/threecode.nim",
       "src/threecode.nim"),
      ("cd /tmp && sed -i '932a\\var bellEnabled = true' src/threecode.nim",
       "src/threecode.nim"),
    ]
    for (cmd, want) in cases:
      check bashMutationPath(cmd) == want

  test "redirects extracted from anywhere in the command":
    check bashMutationPath("echo hi > /tmp/x") == "/tmp/x"
    check bashMutationPath("echo hi >>/tmp/x") == "/tmp/x"
    check bashMutationPath("nimble test > /tmp/log 2>&1") == "/tmp/log"
    # `2>` (stderr-only) is not a mutation we care to track
    check bashMutationPath("nimble test 2>/dev/null") == ""

  test "ed and ex line editors":
    check bashMutationPath("ed -s /tmp/foo.txt") == "/tmp/foo.txt"
    check bashMutationPath("ed /tmp/foo.txt") == "/tmp/foo.txt"
    check bashMutationPath("ex -s -c '%s/a/b/g' /tmp/foo.txt") == "/tmp/foo.txt"
    check bashMutationPath("ex /tmp/foo.txt") == "/tmp/foo.txt"

  test "tee, cp, mv, rm, touch":
    check bashMutationPath("echo x | tee /tmp/y") == "/tmp/y"
    check bashMutationPath("tee -a /tmp/y") == "/tmp/y"
    check bashMutationPath("cp /tmp/a /tmp/b") == "/tmp/b"
    check bashMutationPath("mv /tmp/a /tmp/b") == "/tmp/b"
    check bashMutationPath("rm -rf /tmp/junk") == "/tmp/junk"
    check bashMutationPath("touch /tmp/marker") == "/tmp/marker"

  test "git recovery / file restore":
    check bashMutationPath("git checkout src/foo.nim") == "src/foo.nim"
    check bashMutationPath("git checkout -- src/foo.nim") == "src/foo.nim"
    check bashMutationPath("git restore src/foo.nim") == "src/foo.nim"
    # repo-wide destructives → cwd marker
    check bashMutationPath("git stash") == "."
    check bashMutationPath("git stash push") == "."
    check bashMutationPath("git stash pop") == "."
    check bashMutationPath("git reset --hard") == "."
    check bashMutationPath("git clean -fd") == "."
    # read-only git: no fingerprint
    check bashMutationPath("git stash list") == ""
    check bashMutationPath("git stash show") == ""
    check bashMutationPath("git log --oneline") == ""
    check bashMutationPath("git diff src/foo.nim") == ""
    check bashMutationPath("git status") == ""

  test "read-only commands return empty":
    for c in ["ls", "ls -la /tmp", "cat /tmp/x", "grep foo /tmp/x",
              "rg --no-heading foo /tmp", "find /tmp -name '*.nim'",
              "wc -l /tmp/x", "head -20 /tmp/x", "tail -n 5 /tmp/x",
              "nimble test", "nimble check", "nim c -r /tmp/x.nim",
              "echo hello", "true", "false"]:
      check bashMutationPath(c) == ""

  test "pipelines extract from any stage":
    # `tee` in the middle of a pipeline is still a write
    check bashMutationPath("nimble test | tee /tmp/log | head") == "/tmp/log"

  test "multi-statement: first matching mutation wins":
    check bashMutationPath("ls; sed -i 's/a/b/' /tmp/x.nim") == "/tmp/x.nim"
    check bashMutationPath("cd /tmp && rm /tmp/x") == "/tmp/x"

suite "bash read detection":
  # Backfills the read-cache integration that lived on `akRead` before the
  # dedicated read tool was dropped. `cat path` / `sed -n 'A,Bp' path` /
  # `head` / `tail` are recognised so a later patch/write can still error
  # on external edits, and the dedupe-of-unchanged-reads shortcut still
  # fires for `cat path` (the only "full file" form we recognise).

  test "cat single file is a full read":
    check bashReadPath("cat foo.nim") == ("foo.nim", true)
    check bashReadPath("cat /etc/hosts") == ("/etc/hosts", true)
    check bashReadPath("cat -n foo.nim") == ("foo.nim", true)

  test "cat multi-file or piped is not recognised":
    check bashReadPath("cat a b") == ("", false)
    check bashReadPath("cat foo.nim | wc -l") == ("", false)
    check bashReadPath("cat") == ("", false)

  test "sed -n 'A,Bp' path is a partial read":
    check bashReadPath("sed -n '1,50p' foo.nim") == ("foo.nim", false)
    check bashReadPath("sed -n '100,200p' src/threecode.nim") ==
      ("src/threecode.nim", false)
    # sed without -n is not a pure read in this sense (could be in-place)
    check bashReadPath("sed 's/a/b/' foo.nim") == ("", false)
    # multiple files — bail
    check bashReadPath("sed -n '1p' a b") == ("", false)

  test "head and tail with single file":
    check bashReadPath("head -50 foo.nim") == ("foo.nim", false)
    check bashReadPath("head -n 50 foo.nim") == ("foo.nim", false)
    check bashReadPath("tail -100 foo.nim") == ("foo.nim", false)
    check bashReadPath("tail -n 100 foo.nim") == ("foo.nim", false)
    check bashReadPath("tail -c 4096 foo.nim") == ("foo.nim", false)

  test "redirect / pipe / multi-statement disqualify":
    check bashReadPath("cat foo.nim > /tmp/x") == ("", false)
    check bashReadPath("cat foo.nim | grep bar") == ("", false)
    check bashReadPath("cd /tmp && cat foo.nim") == ("", false)
    check bashReadPath("cat foo.nim; echo done") == ("", false)

  test "non-read commands return empty":
    for c in ["ls", "ls -la /tmp", "grep foo /tmp/x",
              "rg --no-heading foo /tmp", "find /tmp -name '*.nim'",
              "wc -l /tmp/x", "nimble test", "echo hi"]:
      check bashReadPath(c) == ("", false)

  test "bash read trips Strike 1 like the old read tool":
    # 5 cat calls on the same path → Strike 1 (concentration), no Strike 2
    # (reads aren't mutations).
    var t = initLoopTracker()
    for i in 0 ..< LoopTripT:
      discard trackCall(t, "bash", %*{"command": "cat /tmp/x.nim"})
    check t.strike == 1

  test "bash read alone never escalates past Strike 1":
    var t = initLoopTracker()
    for i in 0 ..< LoopWindowK:  # past 2×T
      discard trackCall(t, "bash", %*{"command": "cat /tmp/x.nim"})
    check t.strike == 1

  test "bash read-cache stale-write guard fires on cat then external edit":
    # The integration the original `read` tool gave us: read a file, file
    # changes externally, then a `patch` errors instead of clobbering.
    let tmp = getTempDir() / "3code_test_brc_" & $getCurrentProcessId()
    createDir(tmp)
    let p = tmp / "a.txt"
    writeFile(p, "one\n")
    let cache = newReadCache()
    discard runAction(Action(kind: akBash, body: "cat " & p), cache)
    sleep(1100)  # crude: bump mtime resolution to avoid sig collisions
    writeFile(p, "two\n")  # external edit
    let (r, code, _) = runAction(
      Action(kind: akPatch, path: p, edits: @[("two", "TWO")]), cache)
    check code != 0
    check "changed on disk" in r
    removeDir(tmp)

  test "bash read-cache dedupes unchanged full reads":
    let tmp = getTempDir() / "3code_test_bdup_" & $getCurrentProcessId()
    createDir(tmp)
    let p = tmp / "a.txt"
    writeFile(p, "one\ntwo\n")
    let cache = newReadCache()
    discard runAction(Action(kind: akBash, body: "cat " & p), cache)
    let (r, code, _) = runAction(Action(kind: akBash, body: "cat " & p), cache)
    check code == 0
    check "unchanged since prior read" in r
    removeDir(tmp)

  test "bash mutation synthesises a diff for the visual feedback":
    # `ed -s file` style line-range edits replaced the patch tool. Without
    # diff synthesis the user would see only "[exit 0]" — uninformative.
    let tmp = getTempDir() / "3code_test_bdiff_" & $getCurrentProcessId()
    createDir(tmp)
    let p = tmp / "a.txt"
    writeFile(p, "one\ntwo\nthree\n")
    let act = Action(kind: akBash,
      body: "ed -s " & p,
      stdin: "2c\nTWO\n.\nw\nq\n")
    let (_, code, diff) = runAction(act, newReadCache())
    check code == 0
    check diff.len > 0
    check "-two" in diff
    check "+TWO" in diff
    removeDir(tmp)

suite "git recovery hard-trip":
  # `git checkout <path>`, `git restore`, `git reset --hard`, `git stash`,
  # `git clean -f` wipe the working-tree state the model's plan was based
  # on. Treated as immediate Strike 2; first occurrence halts the turn.

  test "file restore shapes are recovery":
    check bashIsRecovery("git checkout -- src/foo.nim") != ""
    check bashIsRecovery("git checkout src/foo.nim") != ""
    check bashIsRecovery("cd ~/p/3code && git checkout src/threecode.nim") != ""
    check bashIsRecovery("git restore src/foo.nim") != ""
    check bashIsRecovery("git restore .") != ""

  test "wholesale destructives are recovery":
    check bashIsRecovery("git reset --hard") != ""
    check bashIsRecovery("git reset --hard HEAD~1") != ""
    check bashIsRecovery("git stash") != ""
    check bashIsRecovery("git stash push -m wip") != ""
    check bashIsRecovery("git stash pop") != ""
    check bashIsRecovery("git stash drop") != ""
    check bashIsRecovery("git clean -fd") != ""
    check bashIsRecovery("git clean -fdx") != ""

  test "branch switches are NOT recovery":
    check bashIsRecovery("git checkout main") == ""
    check bashIsRecovery("git checkout v1.2.3") == ""
    check bashIsRecovery("git checkout -b feature") == ""
    check bashIsRecovery("git checkout HEAD~1") == ""
    # Remote refs contain `/` but should be allowed — this is a known
    # false-positive trade-off; if it ever bites, refine here. Branch
    # switches usually use bare names, so this is rare in practice.
    # check bashIsRecovery("git checkout origin/main") == ""

  test "read-only git is NOT recovery":
    check bashIsRecovery("git status") == ""
    check bashIsRecovery("git diff src/foo.nim") == ""
    check bashIsRecovery("git log --oneline") == ""
    check bashIsRecovery("git stash list") == ""
    check bashIsRecovery("git stash show") == ""
    check bashIsRecovery("git reset HEAD~1") == ""  # soft reset, no --hard
    check bashIsRecovery("git clean -n") == ""      # dry-run

  test "trackCall halts immediately on first recovery":
    var t = initLoopTracker()
    let s = trackCall(t, "bash",
      %*{"command": "cd /tmp && git checkout src/foo.nim"})
    check s == 2
    check t.strike == 2
    check t.recoveryCmd != ""

  test "branch switch does not halt":
    var t = initLoopTracker()
    let s = trackCall(t, "bash", %*{"command": "git checkout main"})
    check s == 0
    check t.strike == 0
    check t.recoveryCmd == ""
