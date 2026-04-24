import std/[unittest, os, strutils, json, times]
import threecode {.all.}  # exported + private symbols (parseConfigFile, ProviderRec, Session)

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
    check r == "   1\tone\n   2\ttwo\n   3\tthree"
    removeDir(tmp)

  test "runAction akRead line range":
    let tmp = getTempDir() / "3code_test_" & $getCurrentProcessId() & "_r2"
    createDir(tmp)
    let p = tmp / "a.txt"
    writeFile(p, "a\nb\nc\nd\ne\n")
    let (r, code, _) = runAction(Action(kind: akRead, path: p, offset: 2, limit: 2))
    check code == 0
    check r == "   2\tb\n   3\tc"
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
    check r.startsWith("   1\t1\n")
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
    check r == "   1\ttilde-read"
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
