import std/[os, strutils, unittest]
import threecode/[actions, types, streamexec]

suite "streamexec: basic streaming":
  test "streams stdout lines":
    var lines: seq[string]
    let act = Action(kind: akBash, body: "echo hello && echo world")
    let (rawOut, rawErr, code) = runStreamingBash(act, nil,
      proc(line: string) = lines.add(line))
    check code == 0
    check lines == @["hello", "world"]
    check rawOut == "hello\nworld\n"
    check rawErr == ""

  test "handles empty output":
    var lines: seq[string]
    let act = Action(kind: akBash, body: "true")
    let (rawOut, _, code) = runStreamingBash(act, nil,
      proc(line: string) = lines.add(line))
    check code == 0
    check lines.len == 0
    check rawOut == ""

  test "handles single line without trailing newline":
    var lines: seq[string]
    let act = Action(kind: akBash, body: "printf 'no newline'")
    let (rawOut, _, code) = runStreamingBash(act, nil,
      proc(line: string) = lines.add(line))
    check code == 0
    check lines == @["no newline"]
    check rawOut == "no newline\n"

  test "preserves exit code":
    let act = Action(kind: akBash, body: "exit 42")
    let (_, _, code) = runStreamingBash(act, nil, nil)
    check code == 42

  test "exit code 1":
    let act = Action(kind: akBash, body: "false")
    let (_, _, code) = runStreamingBash(act, nil, nil)
    check code == 1

suite "streamexec: stderr handling":
  test "captures stderr separately":
    var lines: seq[string]
    let act = Action(kind: akBash, body: "echo out; echo err >&2")
    let (rawOut, rawErr, code) = runStreamingBash(act, nil,
      proc(line: string) = lines.add(line))
    check code == 0
    # With poStdErrToStdOut, stderr lines also appear in stdout stream
    check "out" in rawOut
    check "err" in rawErr

  test "stderr-only command":
    let act = Action(kind: akBash, body: "echo only_stderr >&2")
    let (_, rawErr, code) = runStreamingBash(act, nil, nil)
    check code == 0
    check rawErr.contains("only_stderr")

suite "streamexec: stdin piping":
  test "pipes stdin to command":
    let act = Action(kind: akBash, body: "cat", stdin: "hello from stdin\n")
    var lines: seq[string]
    let (rawOut, _, code) = runStreamingBash(act, nil,
      proc(line: string) = lines.add(line))
    check code == 0
    check "hello from stdin" in rawOut

  test "empty stdin does not hang":
    let act = Action(kind: akBash, body: "echo done", stdin: "")
    let (rawOut, _, code) = runStreamingBash(act, nil, nil)
    check code == 0
    check rawOut.contains("done")

suite "streamexec: env vars":
  test "PAGER is set to cat":
    let act = Action(kind: akBash, body: "echo $PAGER")
    let (rawOut, _, code) = runStreamingBash(act, nil, nil)
    check code == 0
    check rawOut.strip == "cat"

  test "TERM is set to dumb":
    let act = Action(kind: akBash, body: "echo $TERM")
    let (rawOut, _, code) = runStreamingBash(act, nil, nil)
    check code == 0
    check rawOut.strip == "dumb"

  test "NO_COLOR is set":
    let act = Action(kind: akBash, body: "echo $NO_COLOR")
    let (rawOut, _, code) = runStreamingBash(act, nil, nil)
    check code == 0
    check rawOut.strip == "1"

suite "streamexec: multi-line output":
  test "streams many lines":
    var lines: seq[string]
    let act = Action(kind: akBash, body: "seq 1 10")
    let (rawOut, _, code) = runStreamingBash(act, nil,
      proc(line: string) = lines.add(line))
    check code == 0
    check lines.len == 10
    check lines[0] == "1"
    check lines[9] == "10"
    check rawOut.count('\n') == 10

  test "streams output with delays between lines":
    var lines: seq[string]
    let act = Action(kind: akBash,
      body: "for i in 1 2 3; do echo \"line $i\"; sleep 0.1; done")
    let (_, _, code) = runStreamingBash(act, nil,
      proc(line: string) = lines.add(line))
    check code == 0
    check lines == @["line 1", "line 2", "line 3"]

suite "streamexec: special characters":
  test "handles output with special shell chars":
    var lines: seq[string]
    let act = Action(kind: akBash, body: "echo 'hello world' && echo 'a|b>c'")
    let (_, _, code) = runStreamingBash(act, nil,
      proc(line: string) = lines.add(line))
    check code == 0
    check "hello world" in lines
    check "a|b>c" in lines

  test "handles empty lines in output":
    var lines: seq[string]
    let act = Action(kind: akBash, body: "echo 'a'; echo ''; echo 'b'")
    let (_, _, code) = runStreamingBash(act, nil,
      proc(line: string) = lines.add(line))
    check code == 0
    check lines == @["a", "", "b"]

  test "handles unicode output":
    var lines: seq[string]
    let act = Action(kind: akBash, body: "echo '● ○ ◔ ◑ ◕'")
    let (_, _, code) = runStreamingBash(act, nil,
      proc(line: string) = lines.add(line))
    check code == 0
    check lines[0].contains("●")

suite "streamexec: callback is optional":
  test "nil callback works":
    let act = Action(kind: akBash, body: "echo hello")
    let (rawOut, _, code) = runStreamingBash(act, nil, nil)
    check code == 0
    check rawOut == "hello\n"

  test "default callback is nil":
    let act = Action(kind: akBash, body: "echo hello")
    let (rawOut, _, code) = runStreamingBash(act, nil)
    check code == 0
    check rawOut == "hello\n"

suite "streamexec: file mutation snapshot":
  test "before-content snapshot for mutation commands":
    let tmpDir = getTempDir() / "3code_test_stream_" & $getCurrentProcessId()
    createDir(tmpDir)
    let filePath = tmpDir / "target.txt"
    writeFile(filePath, "original content\n")
    let act = Action(kind: akBash, body: "echo 'new content' > " & filePath)
    let (_, _, code) = runStreamingBash(act, nil, nil)
    check code == 0
    let content = readFile(filePath)
    check content == "new content\n"
    removeDir(tmpDir)

suite "runActionStreaming: non-bash delegation":
  test "delegates akRead to runAction":
    let act = Action(kind: akRead, path: "/nonexistent/path/file.txt")
    let (output, code, _) = runActionStreaming(act, nil, nil)
    check code == 1
    check "does not exist" in output or "error" in output

  test "delegates akWrite to runAction":
    let tmpDir = getTempDir() / "3code_test_stream_" & $getCurrentProcessId()
    createDir(tmpDir)
    let filePath = tmpDir / "test_write.txt"
    let act = Action(kind: akWrite, path: filePath, body: "hello")
    let (output, code, _) = runActionStreaming(act, nil, nil)
    check code == 0
    check "wrote" in output
    removeDir(tmpDir)

  test "delegates akPlan to runAction":
    let act = Action(kind: akPlan,
      plan: @[PlanItem(text: "step 1", status: "pending")])
    let (output, code, _) = runActionStreaming(act, nil, nil)
    check code == 0
    check "step 1" in output

  test "delegates akError to runAction":
    let act = Action(kind: akError, body: "something went wrong")
    let (output, code, _) = runActionStreaming(act, nil, nil)
    check code == 1
    check "something went wrong" in output

suite "runActionStreaming: bash post-processing":
  test "clips long output":
    let bigCmd = "python3 -c \"print('x' * 10000)\" 2>/dev/null || perl -e 'print \"x\" x 10000'"
    var lines: seq[string]
    let act = Action(kind: akBash, body: bigCmd)
    let (output, code, _) = runActionStreaming(act, nil,
      proc(line: string) = lines.add(line))
    check code == 0
    # Output should be clipped (body < raw 10000 chars)
    check output.len < 10000

  test "captures stderr with [stderr] prefix":
    let act = Action(kind: akBash, body: "echo out; echo err >&2")
    let (output, code, _) = runActionStreaming(act, nil, nil)
    check code == 0
    check "[stderr]" in output
    check "err" in output

  test "propagates non-zero exit code":
    let act = Action(kind: akBash, body: "exit 1")
    let (_, code, _) = runActionStreaming(act, nil, nil)
    check code == 1

suite "runActionStreaming: streaming callback fires":
  test "callback receives lines in order":
    var lines: seq[string]
    let act = Action(kind: akBash, body: "echo alpha; echo beta; echo gamma")
    discard runActionStreaming(act, nil,
      proc(line: string) = lines.add(line))
    check lines == @["alpha", "beta", "gamma"]

  test "callback fires for slow commands":
    var lines: seq[string]
    let act = Action(kind: akBash,
      body: "for i in 1 2 3; do echo \"slow_$i\"; sleep 0.1; done")
    discard runActionStreaming(act, nil,
      proc(line: string) = lines.add(line))
    check lines == @["slow_1", "slow_2", "slow_3"]

suite "runActionStreaming: read cache integration":
  test "short-circuits on unchanged full read":
    let cache = newReadCache()
    let tmpDir = getTempDir() / "3code_test_cache_" & $getCurrentProcessId()
    createDir(tmpDir)
    let filePath = tmpDir / "cached.txt"
    writeFile(filePath, "cached content\n")
    # Prime the cache
    let act1 = Action(kind: akRead, path: filePath)
    discard runAction(act1, cache)
    # Now read via bash cat — should short-circuit
    let act2 = Action(kind: akBash, body: "cat " & filePath)
    let (output, code, _) = runActionStreaming(act2, cache, nil)
    check code == 0
    check "unchanged" in output
    removeDir(tmpDir)
