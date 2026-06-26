import std/[os, strutils, times, unittest]
import threecode/[actions, types, streamexec]

suite "streamexec: basic streaming":
  test "streams stdout lines":
    var lines: seq[string]
    let act = Action(kind: akBash, body: "echo hello && echo world")
    let (rawOut, code, _) = runStreamingBash(act, nil,
      proc(line: string) = lines.add(line))
    check code == 0
    check lines == @["hello", "world"]
    check rawOut == "hello\nworld\n"

  test "handles empty output":
    var lines: seq[string]
    let act = Action(kind: akBash, body: "true")
    let (rawOut, code, _) = runStreamingBash(act, nil,
      proc(line: string) = lines.add(line))
    check code == 0
    check lines.len == 0
    check rawOut == ""

  test "handles single line without trailing newline":
    var lines: seq[string]
    let act = Action(kind: akBash, body: "printf 'no newline'")
    let (rawOut, code, _) = runStreamingBash(act, nil,
      proc(line: string) = lines.add(line))
    check code == 0
    check lines == @["no newline"]
    check rawOut == "no newline\n"

  test "streams partial prompt before newline":
    var lines: seq[string]
    let act = Action(kind: akBash,
      body: "printf 'Prompt: waiting'; sleep 1; printf '\\nDone\\n'")
    let (rawOut, code, _) = runStreamingBash(act, nil,
      proc(line: string) = lines.add(line))
    check code == 0
    check lines == @["Prompt: waiting", "Done"]
    check rawOut == "Prompt: waiting\nDone\n"

  test "preserves very long single-line output":
    var lines: seq[string]
    let act = Action(kind: akBash,
      body: "python3 -c \"print('x' * 200000, end='')\"")
    let (rawOut, code, _) = runStreamingBash(act, nil,
      proc(line: string) = lines.add(line))
    check code == 0
    check rawOut.len == 200001
    check rawOut == repeat('x', 200000) & "\n"
    check lines.len == 1
    check lines[0] == repeat('x', 200000)

  test "preserves exit code":
    let act = Action(kind: akBash, body: "exit 42")
    let (_, code, _) = runStreamingBash(act, nil, nil)
    check code == 42

  test "exit code 1":
    let act = Action(kind: akBash, body: "false")
    let (_, code, _) = runStreamingBash(act, nil, nil)
    check code == 1

  test "cancelActiveTool stops streamed bash process tree promptly":
    let started = epochTime()
    var lines: seq[string]
    let act = Action(kind: akBash,
      body: "echo ready; sh -c 'sleep 30 & wait'")
    let (rawOut, code, _) = runStreamingBash(act, nil,
      proc(line: string) =
        lines.add(line)
        if line == "ready":
          cancelActiveTool())
    check "ready" in lines
    check rawOut.contains("ready")
    check code != 0
    check epochTime() - started < 5.0

suite "streamexec: stderr handling":
  test "stderr appears inline in stdout":
    var lines: seq[string]
    let act = Action(kind: akBash, body: "echo out; echo err >&2")
    let (rawOut, code, _) = runStreamingBash(act, nil,
      proc(line: string) = lines.add(line))
    check code == 0
    check "out" in rawOut
    check "err" in rawOut

  test "stderr-only command":
    let act = Action(kind: akBash, body: "echo only_stderr >&2")
    let (rawOut, code, _) = runStreamingBash(act, nil, nil)
    check code == 0
    check rawOut.contains("only_stderr")

suite "streamexec: stdin piping":
  test "pipes stdin to command":
    let act = Action(kind: akBash, body: "cat", stdin: "hello from stdin\n")
    var lines: seq[string]
    let (rawOut, code, _) = runStreamingBash(act, nil,
      proc(line: string) = lines.add(line))
    check code == 0
    check "hello from stdin" in rawOut

  test "empty stdin does not hang":
    let act = Action(kind: akBash, body: "echo done", stdin: "")
    let (rawOut, code, _) = runStreamingBash(act, nil, nil)
    check code == 0
    check rawOut.contains("done")

suite "streamexec: env vars":
  test "PAGER is set to cat":
    let act = Action(kind: akBash, body: "echo $PAGER")
    let (rawOut, code, _) = runStreamingBash(act, nil, nil)
    check code == 0
    check rawOut.strip == "cat"

  test "TERM is set to dumb":
    let act = Action(kind: akBash, body: "echo $TERM")
    let (rawOut, code, _) = runStreamingBash(act, nil, nil)
    check code == 0
    check rawOut.strip == "dumb"

  test "NO_COLOR is set":
    let act = Action(kind: akBash, body: "echo $NO_COLOR")
    let (rawOut, code, _) = runStreamingBash(act, nil, nil)
    check code == 0
    check rawOut.strip == "1"

suite "streamexec: multi-line output":
  test "streams many lines":
    var lines: seq[string]
    let act = Action(kind: akBash, body: "seq 1 10")
    let (rawOut, code, _) = runStreamingBash(act, nil,
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
    let (_, code, _) = runStreamingBash(act, nil,
      proc(line: string) = lines.add(line))
    check code == 0
    check lines == @["line 1", "line 2", "line 3"]

suite "streamexec: special characters":
  test "handles output with special shell chars":
    var lines: seq[string]
    let act = Action(kind: akBash, body: "echo 'hello world' && echo 'a|b>c'")
    let (_, code, _) = runStreamingBash(act, nil,
      proc(line: string) = lines.add(line))
    check code == 0
    check "hello world" in lines
    check "a|b>c" in lines

  test "handles empty lines in output":
    var lines: seq[string]
    let act = Action(kind: akBash, body: "echo 'a'; echo ''; echo 'b'")
    let (_, code, _) = runStreamingBash(act, nil,
      proc(line: string) = lines.add(line))
    check code == 0
    check lines == @["a", "", "b"]

  test "handles unicode output":
    var lines: seq[string]
    let act = Action(kind: akBash, body: "echo '● ○ ◔ ◑ ◕'")
    let (_, code, _) = runStreamingBash(act, nil,
      proc(line: string) = lines.add(line))
    check code == 0
    check lines[0].contains("●")

suite "streamexec: binary output suppression":
  test "suppresses streaming callback after NUL byte":
    var lines: seq[string]
    let act = Action(kind: akBash, body: "printf 'before\\n\\x00binary\\x00garbage\\nafter\\n'")
    let (rawOut, code, _) = runStreamingBash(act, nil,
      proc(line: string) = lines.add(line))
    check code == 0
    check "before" in lines
    # Once binary content starts, no further lines stream to the callback.
    check "after" notin lines
    # rawOut still collects everything for accurate post-hoc byte count.
    check '\x00' in rawOut

suite "streamexec: callback is optional":
  test "nil callback works":
    let act = Action(kind: akBash, body: "echo hello")
    let (rawOut, code, _) = runStreamingBash(act, nil, nil)
    check code == 0
    check rawOut == "hello\n"

  test "default callback is nil":
    let act = Action(kind: akBash, body: "echo hello")
    let (rawOut, code, _) = runStreamingBash(act, nil)
    check code == 0
    check rawOut == "hello\n"

suite "streamexec: file mutation snapshot":
  test "before-content snapshot for mutation commands":
    let tmpDir = getTempDir() / "3code_test_stream_" & $getCurrentProcessId()
    createDir(tmpDir)
    let filePath = tmpDir / "target.txt"
    writeFile(filePath, "original content\n")
    let act = Action(kind: akBash, body: "echo 'new content' > " & filePath)
    let (_, code, _) = runStreamingBash(act, nil, nil)
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

  test "merges stderr inline with stdout":
    let act = Action(kind: akBash, body: "echo out; echo err >&2")
    let (output, code, _) = runActionStreaming(act, nil, nil)
    check code == 0
    check "[stderr]" notin output
    check "out" in output
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

suite "streamexec: no external timeout dependency":
  # Regression: bash execution wrapped the command in `exec timeout
  # --foreground {cap}s sh ...`, relying on GNU `timeout`. That binary is
  # absent on stock macOS, so every bash tool call failed with
  # "exec: timeout: not found". The fix enforces the cap natively (a
  # watchdog thread signals the process group) and no longer shells out to
  # `timeout`. These tests guard both the plain-execution path and the native
  # cap on all platforms.
  test "runAction runs bash without shelling out to `timeout`":
    let act = Action(kind: akBash, body: "echo native-exec-ok")
    let (o, code, _) = runAction(act)
    check code == 0
    check "native-exec-ok" in o

  test "native timeout kills a runaway command (exit 124)":
    let act = Action(kind: akBash, body: "sleep 30", timeoutSecs: 2)
    let started = epochTime()
    let (o, code, _) = runAction(act)
    let elapsed = epochTime() - started
    check code == 124
    check elapsed < 6.0
    check "timed out" in o

  test "native timeout via streaming path (exit 124)":
    let act = Action(kind: akBash, body: "sleep 30", timeoutSecs: 2)
    let started = epochTime()
    let (o, code, _) = runActionStreaming(act, nil, nil)
    let elapsed = epochTime() - started
    check code == 124
    check elapsed < 6.0
    check "timed out" in o

when defined(windows):
  suite "streamexec: Windows bash resolution":
    # On a clean CI runner no installer has run, so the bundled MSYS2 is
    # absent and resolveBash() returns "". That is the documented contract
    # (the startup guard hard-fails on it); assert it here rather than
    # depending on the runner shipping bash at the bundle path.
    test "resolveBash returns empty when no bundled bash":
      cachedBash = ""  # defeat the threadvar cache
      check resolveBash() == ""

    test "runStreamingBash fails cleanly when no bundled bash":
      cachedBash = ""
      let act = Action(kind: akBash, body: "echo hello")
      let (_, code, _) = runStreamingBash(act, nil, nil)
      check code == 127
