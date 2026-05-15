import std/[json, os, osproc, posix, strutils, unittest]
import tty_expect

proc ensureStubBinary(): string =
  let pid = $getCurrentProcessId()
  result = getTempDir() / ("3code_tty_stub_" & pid)
  if fileExists(result):
    return
  let cacheDir = getTempDir() / ("3code_tty_stub_cache_" & pid)
  createDir(cacheDir)
  let cmd = "nim c -d:ssl -d:providerStub --threads:on --path:src --nimcache:" &
    cacheDir.quoteShell & " -o:" & result.quoteShell & " src/threecode.nim"
  let (outp, code) = execCmdEx(cmd)
  doAssert code == 0, outp

proc newFixture(name: string): string =
  result = getTempDir() / ("3code_tty_" & name & "_" & $getCurrentProcessId())
  if dirExists(result):
    removeDir(result)
  createDir(result)
  createDir(result / "data")
  createDir(result / "run")

proc writeConfiguredProvider(root: string) =
  createDir(root / "xdg" / "3code")
  writeFile(root / "xdg" / "3code" / "config", """
[settings]
current = "stub.stub-model"
search-url = "http://127.0.0.1:1/?q="

[provider]
name = "stub"
url = "stub://provider"
key = "stub"
family = "glm"
models = "stub-model"
""")

proc toolCall(id, name: string, args: JsonNode): JsonNode =
  %*{
    "id": id,
    "type": "function",
    "function": {
      "name": name,
      "arguments": $args
    }
  }

proc writeStubResponses(root: string, responses: JsonNode) =
  writeFile(root / "run" / "stub_responses.json", $responses)

proc stubEnv(root: string): seq[EnvVar] =
  @[
    (key: "TERM", val: "xterm-256color"),
    (key: "PATH", val: getEnv("PATH")),
    (key: "HOME", val: root),
    (key: "XDG_CONFIG_HOME", val: root / "xdg"),
    (key: "XDG_DATA_HOME", val: root / "data"),
  ]

proc startStub(root: string; args: openArray[string] = ["-x", "-i"]): TtySession =
  newTtySession(ensureStubBinary(), args = args, cwd = root / "run",
                env = stubEnv(root), cols = 80, rows = 24)

proc hasStackedTokenBars(frame: TtyFrame): bool =
  var prevWasBar = false
  for row in frame.rows:
    let isBar = ("↑" in row or "↓" in row or "↻" in row) and "s" in row
    if isBar and prevWasBar:
      return true
    prevWasBar = isBar
  false

proc answerWithoutMultilineEcho(frame: TtyFrame): bool =
  var hasAnswer = false
  var hasContinuation = false
  for row in frame.rows:
    if "The multiline answer" in row:
      hasAnswer = true
    if "  test" in row:
      hasContinuation = true
  hasAnswer and not hasContinuation

suite "real tty stub-provider sessions":
  test "main shakedown covers tools, streaming, nonstream, and continued input":
    let root = newFixture("dialog")
    writeConfiguredProvider(root)
    writeFile(root / "run" / "source.txt", "alpha\nbeta\n")
    writeStubResponses(root, %*[
      {
        "role": "assistant",
        "content": "Streaming shakedown before tools.",
        "tool_calls": [
          toolCall("call_plan", "update_plan", %*{
            "items": [{"text": "exercise tools", "status": "in_progress"}]}),
          toolCall("call_bash", "bash", %*{
            "command": "for i in 1 2 3; do echo bash-stream-$i; sleep 0.1; done"}),
          toolCall("call_read", "read", %*{"path": "source.txt"}),
          toolCall("call_write", "write", %*{
            "path": "written.txt", "body": "first\n"}),
          toolCall("call_patch", "patch", %*{
            "path": "written.txt",
            "edits": [{"search": "first", "replace": "second"}]}),
          toolCall("call_apply", "apply_patch", %*{
            "input": "*** Begin Patch\n*** Add File: applied.txt\n+applied\n*** End Patch\n"}),
          toolCall("call_search", "web_search", %*{"query": "dummy"}),
          toolCall("call_fetch", "web_fetch", %*{"url": "http://127.0.0.1:1/"})
        ]
      },
      {
        "role": "assistant",
        "content": "Nonstream answer after tools.",
        "stream": false
      },
      {
        "role": "assistant",
        "content": "Still alive after shakedown.",
        "stream": false
      }
    ])

    let tty = startStub(root)
    defer: tty.close()
    tty.expect "❯"
    tty.send "exercise tools\n"
    tty.expectInHistory "Streaming shakedown before tools."
    tty.expectInHistory "bash-stream-1"
    tty.expectInHistory "bash-stream-2"
    tty.expectInHistory "bash-stream-3"
    tty.expectInHistory "Nonstream answer after tools."
    tty.expectSnapshot(["Streaming shakedown before tools."])
    tty.expectSnapshot(["Nonstream answer after tools."])
    tty.drain(500)
    check not tty.exited
    tty.send "one more\n"
    tty.expectInHistory "Still alive after shakedown."
    tty.expectTokenBarStable()
    tty.expectNoPromptRowText([
      "Streaming shakedown before tools.",
      "Nonstream answer after tools.",
      "Still alive after shakedown."
    ])
    tty.expectNoReasoningTickerRows()
    tty.expectNoOrphanSpinnerRows()
    tty.ctrlD()
    tty.expectExit 0

    check fileExists(root / "run" / "written.txt")
    check readFile(root / "run" / "written.txt") == "second\n"
    check fileExists(root / "run" / "applied.txt")

  test "buffered input during tool keeps prior assistant text intact":
    let root = newFixture("buffered")
    writeConfiguredProvider(root)
    writeStubResponses(root, %*[
      {
        "role": "assistant",
        "content": "yes it is",
        "tool_calls": [
          toolCall("call_slow", "bash", %*{
            "command": "sleep 0.8; printf tool-finished"})
        ]
      },
      {"role": "assistant", "content": "The second answer"}
    ])

    let tty = startStub(root)
    defer: tty.close()
    tty.expect "❯"
    tty.send "this is a test\n"
    tty.expectInHistory "yes it is"
    tty.send "and another\n"
    tty.expectInHistory "❯ and another"
    tty.expectInHistory "The second answer"
    tty.expectNeverInHistory "… The"
    tty.expectSnapshot(["yes it is", "❯ and another"])
    tty.expectNoFrame(hasStackedTokenBars)
    tty.ctrlD()
    tty.expectExit 0

  test "buffered multiline input survives autoprompt replay":
    let root = newFixture("buffered_multiline")
    writeConfiguredProvider(root)
    writeStubResponses(root, %*[
      {
        "role": "assistant",
        "content": "and this too",
        "tool_calls": [
          toolCall("call_slow", "bash", %*{
            "command": "sleep 0.8; printf tool-finished"})
        ]
      },
      {
        "role": "assistant",
        "reasoning_content": "The hidden thought should not stay visible",
        "content": "The multiline answer"
      },
      {"role": "assistant", "content": "still running"}
    ])

    let tty = startStub(root)
    defer: tty.close()
    tty.expect "❯"
    tty.send "this is a test\n"
    tty.expectInHistory "and this too"
    tty.send "another"
    tty.send "\x1b[27;2;13~"
    tty.send "test\n"
    tty.expectInHistory "❯ another"
    tty.expectInHistory "  test"
    tty.expectInHistory "The multiline answer"
    tty.expectFrameSeries([
      """
...
❯ another
  test
...
""",
      """
...
The multiline answer
...
"""])
    tty.expectNeverInHistory "❯ another\n  … The"
    tty.expectNo "… The hidden"
    tty.expectNoPromptRowText(["The multiline answer", "still running"])
    tty.expectNoReasoningTickerRows()
    tty.expectNoOrphanSpinnerRows()
    tty.expectNoFrame(answerWithoutMultilineEcho)
    tty.expectNoFrame(hasStackedTokenBars)
    tty.drain(500)
    check not tty.exited
    tty.send "third prompt\n"
    tty.expectInHistory "still running"
    tty.ctrlD()
    tty.expectExit 0

  test "bootstrap wizard runs the first prompt after saving stub provider":
    let root = newFixture("wizard")
    writeStubResponses(root, %*[
      {"role": "assistant", "content": "first prompt executed"}
    ])

    let tty = startStub(root, ["-x", "-i", "first prompt"])
    defer: tty.close()
    tty.expect "api key"
    tty.send "stub\n"
    tty.expect "models"
    tty.send "stub-model\n"
    tty.expectInHistory "saved to"
    tty.expectInHistory "first prompt executed"
    tty.expectTokenBar(["↑100"])
    tty.ctrlD()
    tty.expectExit 0

    check fileExists(root / "xdg" / "3code" / "config")

  test "token bar includes context, up, down, cached, and elapsed time":
    let root = newFixture("tokens")
    writeConfiguredProvider(root)
    writeStubResponses(root, %*[
      {
        "role": "assistant",
        "content": "token details",
        "usage": {
          "promptTokens": 3200,
          "completionTokens": 64,
          "totalTokens": 3264,
          "cachedTokens": 1200
        }
      }
    ])

    let tty = startStub(root)
    defer: tty.close()
    tty.expect "❯"
    tty.send "tokens\n"
    tty.expectTokenBar(["○", "↑2.0k", "↻1.2k", "↓64", "0s"])
    tty.expectTokenBarStable()
    tty.send ":q\n"
    tty.expectExit 0

  test "smoke conversation runs tools":
    let root = newFixture("smoke")
    writeConfiguredProvider(root)
    writeStubResponses(root, %*[
      {
        "role": "assistant",
        "content": nil,
        "tool_calls": [
          toolCall("call_bash", "bash", %*{"command": "printf smoke-tool"})
        ]
      },
      {"role": "assistant", "content": "smoke done"}
    ])

    let tty = startStub(root)
    defer: tty.close()
    tty.expect "❯"
    tty.send "smoke\n"
    tty.expectInHistory "smoke-tool"
    tty.expectInHistory "smoke done"
    tty.ctrlD()
    tty.expectExit 0

  test "ctrl-c during a turn restores a usable prompt":
    let root = newFixture("ctrlc")
    writeConfiguredProvider(root)
    writeStubResponses(root, %*[
      {
        "role": "assistant",
        "content": "starting slow tool",
        "tool_calls": [
          toolCall("call_slow", "bash", %*{"command": "sleep 5; printf late"})
        ]
      },
      {"role": "assistant", "content": "after interrupt"}
    ])

    let tty = startStub(root)
    defer: tty.close()
    tty.expect "❯"
    tty.send "interrupt me\n"
    tty.expectInHistory "starting slow tool"
    tty.ctrlC()
    tty.expectInHistory "interrupted"
    tty.expect "❯"
    tty.expectNo "late"
    tty.send ":q\n"
    tty.expectExit 0
    tty.expectTerminalCleanup()

  test "sigterm emits terminal cleanup before signal exit":
    let root = newFixture("sigterm")
    writeConfiguredProvider(root)
    writeStubResponses(root, %*[
      {"role": "assistant", "content": "unused"}
    ])

    let tty = startStub(root)
    defer: tty.close()
    tty.expect "❯"
    tty.signal(SIGTERM)
    tty.expectExit 143
    tty.expectTerminalCleanup()
