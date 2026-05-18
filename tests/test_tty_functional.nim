import std/[json, os, osproc, strutils, unittest]
import tty_expect

const VisualOutputRoot = "tests" / "output" / "tty"
const SimpleVisualTestFrames = "tests" / "fixtures" / "tty" / "simple.txt"
const MultilineVisualTestFrames = "tests" / "fixtures" / "tty" / "multiline.txt"
const ResizeStreamFrames = "tests" / "fixtures" / "tty" / "resize_stream_frames.txt"

proc ensureStubBinary(): string =
  let pid = $getCurrentProcessId()
  result = getTempDir() / ("3code_tty_stub_" & pid)
  if fileExists(result):
    removeFile(result)
  let cacheDir = getTempDir() / ("3code_tty_stub_cache_" & pid)
  createDir(cacheDir)
  let cmd = "nim c -d:ssl -d:providerStub --threads:on --path:src --nimcache:" &
    cacheDir.quoteShell & " -o:" & result.quoteShell & " src/threecode.nim"
  let (outp, code) = execCmdEx(cmd)
  doAssert code == 0, outp

proc newFixture(name: string): string =
  result = getCurrentDir() / VisualOutputRoot / (name & "_" & $getCurrentProcessId())
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

proc toolCall(id, name: string, args: JsonNode; stub: JsonNode = nil): JsonNode =
  result = %*{
    "id": id,
    "type": "function",
    "function": {
      "name": name,
      "arguments": $args
    }
  }
  if stub != nil:
    result["stub"] = stub

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
                env = stubEnv(root))

proc framePresenceRuns(s: TtySession; needle: string): int =
  var wasPresent = false
  for frame in s.frames:
    var present = false
    for row in frame.rows:
      if row.strip == needle:
        present = true
        break
    if present and not wasPresent:
      inc result
    wasPresent = present

suite "terminal visual contract":
  test "simple one-turn prompt and reply":
    let root = newFixture("simple_visual_test")
    writeConfiguredProvider(root)
    writeStubResponses(root, %*[
      {
        "role": "assistant",
        "reasoning_content": "Thinking about the test prompt",
        "reasoningChunks": ["Thinking about the test prompt"],
        "preStreamDelayMs": 200,
        "content": "This is a test response.",
        "contentChunks": ["This is a test response."],
        "usage": {
          "promptTokens": 120,
          "completionTokens": 24,
          "totalTokens": 144,
          "cachedTokens": 0
        }
      }
    ])

    let tty = startStub(root)
    defer:
      tty.writeFrameArtifact(root / "frames.txt")
      tty.writeMeaningfulFrameArtifact(root / "meaningful_frames.txt")
      tty.close()

    tty.expect "❯"
    tty.send "This is a test prompt"
    tty.expect "This is a test prompt"
    tty.send "\n"
    tty.expectInHistory "Thinking about the test prompt"
    tty.expectInHistory "This is a test response."
    tty.expectTokenBar(["○", "↑120", "↓24"])
    tty.drain(200)
    tty.expectMeaningfulFrameArtifact(
      SimpleVisualTestFrames,
      root / "simple_visual_test_actual.txt")

  test "multiline prompt and queued multiline autosend":
    let root = newFixture("multiline_visual_test")
    writeConfiguredProvider(root)
    writeStubResponses(root, %*[
      {
        "role": "assistant",
        "waitForTestContinue": true,
        "content": "First multiline response.",
        "contentChunks": ["First multiline response."],
        "usage": {
          "promptTokens": 120,
          "completionTokens": 24,
          "totalTokens": 144,
          "cachedTokens": 0
        }
      },
      {
        "role": "assistant",
        "content": "Queued multiline response.",
        "contentChunks": ["Queued multiline response."],
        "usage": {
          "promptTokens": 180,
          "completionTokens": 32,
          "totalTokens": 212,
          "cachedTokens": 0
        }
      }
    ])

    let tty = startStub(root)
    defer:
      tty.writeFrameArtifact(root / "frames.txt")
      tty.writeMeaningfulFrameArtifact(root / "meaningful_frames.txt")
      tty.close()

    tty.expect "❯"
    tty.send "first line"
    tty.send "\x1b[13;2u"
    tty.send "second line"
    tty.expect "second line"
    tty.send "\n"

    tty.send "queued line one"
    tty.send "\x1b[13;2u"
    tty.send "queued line two"
    tty.expect "queued line two"
    tty.advanceTicker()
    tty.advanceTicker()
    tty.advanceTicker()
    tty.send "\n"
    tty.continueStubApi()

    tty.expectInHistory "❯ first line"
    tty.expectInHistory "  second line"
    tty.expectInHistory "First multiline response."
    tty.expectInHistory "❯ queued line one"
    tty.expectInHistory "  queued line two"
    tty.expectInHistory "Queued multiline response."
    tty.expectTokenBar(["○", "↑180", "↓32"])
    tty.drain(200)
    tty.expectMeaningfulFrameArtifact(
      MultilineVisualTestFrames,
      root / "multiline_visual_test_actual.txt")

when false:
  suite "disabled terminal visual contract tests":
    test "stub provider streams bash output without replaying it later":
      if getEnv("THREECODE_TTY_ONLY") in ["", "stream_no_replay"]:
        let root = newFixture("stream_no_replay")
        writeConfiguredProvider(root)
        writeStubResponses(root, %*[
          {
            "role": "assistant",
            "content": "About to run one tool.",
            "tool_calls": [
              toolCall("call_once", "bash", %*{
                "command": "printf 'unique-stream-line\\n'; sleep 0.25"})
            ]
          },
          {
            "role": "assistant",
            "content": "Done.",
            "usage": {
              "promptTokens": 42,
              "completionTokens": 7,
              "totalTokens": 49,
              "cachedTokens": 0
            }
          }
        ])

      let tty = startStub(root)
      defer:
        tty.writeFrameArtifact(root / "frames.txt")
        tty.writeMeaningfulFrameArtifact(root / "meaningful_frames.txt")
        tty.close()

      tty.expect "❯"
      tty.send "exercise one streamed tool\n"
      tty.expectInHistory "About to run one tool."
      tty.expectInHistory "$ printf 'unique-stream-line"
      tty.expectInHistory "unique-stream-line"
      tty.expectInHistory "Done."
      tty.drain(200)
      check tty.framePresenceRuns("unique-stream-line") == 1
      tty.send ":q\n"
      tty.expectExit 0

  test "resizing during a live stub stream does not truncate or retry":
    if getEnv("THREECODE_TTY_ONLY").len > 0 and
        getEnv("THREECODE_TTY_ONLY") != "resize_stream":
      check true
    else:
      let root = newFixture("resize_stream")
      writeConfiguredProvider(root)
      writeStubResponses(root, %*[
        {
          "role": "assistant",
          "content": "Resize stream part one. Resize stream part two. Resize stream complete.",
          "usage": {
            "promptTokens": 42,
            "completionTokens": 9,
            "totalTokens": 51,
            "cachedTokens": 0
          }
        }
      ])

      let tty = startStub(root)
      defer:
        tty.writeFrameArtifact(root / "frames.txt")
        tty.writeMeaningfulFrameArtifact(root / "meaningful_frames.txt")
        tty.close()

      tty.expect "❯"
      tty.send "resize while streaming\n"
      tty.expectInHistory "Resize stream part one."
      tty.resizeMainThread(104, 34)
      tty.drain(80)
      tty.resizeMainThread(132, 38)
      tty.expectInHistory "Resize stream complete."
      tty.expectTokenBar(["○", "↑42", "↓9"])
      tty.expectMeaningfulFrameArtifact(
        ResizeStreamFrames,
        root / "resize_stream_actual.txt")

  test "main visual test":
    if getEnv("THREECODE_TTY_ONLY").len > 0 and
        getEnv("THREECODE_TTY_ONLY") != "main_visual_test":
      check true
    else:
      let root = newFixture("main_visual_test")
      writeConfiguredProvider(root)
      createDir(root / "run" / "brpr.db")
      createDir(root / "run" / "tools")
      writeFile(root / "run" / "brpr.db" / "data.mdb", "")
      writeFile(root / "run" / "brpr.db" / "lock.mdb", "")
      writeStubResponses(root, %*[
        {
          "role": "assistant",
          "reasoning_content": "We should inspect the repository tree before identifying issues.",
          "reasoningChunks": [
            "We should inspect the repository tree before identifying issues."
          ],
          "content": "",
          "tool_calls": [
            toolCall("call_ls", "bash", %*{
              "command": "ls -R"},
              %*{
                "stream": ["brpr.db", "tools"],
                "output": "brpr.db\ntools\n",
                "code": 0
              })
          ]
        },
        {
          "role": "assistant",
          "reasoning_content": "We need to look at the repository layout after the ls tool call and decide what stands out.",
          "reasoningChunks": [
            "We need to look at the repository layout after the ls tool call and decide what stands out."
          ],
          "preStreamDelayMs": 900,
          "content": "I saw the main project directories.",
          "contentChunks": ["I saw the main project directories."],
          "usage": {
            "promptTokens": 5500,
            "completionTokens": 188,
            "totalTokens": 5688,
            "cachedTokens": 0
          }
        },
        {
          "role": "assistant",
          "reasoning_content": "thinking about visible ticker",
          "reasoningChunks": ["thinking about visible ticker"],
          "content": "Streaming **markdown** before tools.",
          "contentChunks": ["Streaming **markdown** before tools."],
          "tool_calls": [
            toolCall("call_bash1", "bash", %*{
              "command": "printf 'bash-line-1\\nbash-line-2\\nbash-line-3\\nbash-line-4\\nbash-line-5\\nbash-line-6\\nbash-line-7\\nbash-line-8\\nbash-line-9\\nbash-line-10\\nbash-line-11\\nbash-line-12\\n'"},
              %*{
                "stream": [
                  "bash-line-1",
                  "bash-line-2",
                  "bash-line-3",
                  "bash-line-4",
                  "bash-line-5",
                  "bash-line-6",
                  "bash-line-7",
                  "bash-line-8",
                  "bash-line-9",
                  "bash-line-10",
                  "bash-line-11",
                  "bash-line-12"
                ],
                "output": "bash-line-1\nbash-line-2\nbash-line-3\nbash-line-4\nbash-line-5\nbash-line-6\nbash-line-7\nbash-line-8\nbash-line-9\nbash-line-10\nbash-line-11\nbash-line-12\n",
                "code": 0
              }),
            toolCall("call_bash2", "bash", %*{
              "command": "printf second-tool"},
              %*{
                "stream": ["second-tool"],
                "output": "second-tool\n",
                "code": 0
              })
          ]
        },
        {
          "role": "assistant",
          "content": "Buffered prompt answered.",
          "contentChunks": ["Buffered prompt answered."],
          "usage": {
            "promptTokens": 120,
            "completionTokens": 8,
            "totalTokens": 128,
            "cachedTokens": 32
          }
        },
        {
          "role": "assistant",
          "preStreamDelayMs": 1800,
          "content": "yes it is",
          "contentChunks": ["yes it is"],
          "usage": {
            "promptTokens": 16,
            "completionTokens": 36,
            "totalTokens": 52,
            "cachedTokens": 3200
          }
        },
        {
          "role": "assistant",
          "content": "Sure is. Let me know when you have a real task.",
          "contentChunks": ["Sure is. Let me know when you have a real task."],
          "usage": {
            "promptTokens": 31,
            "completionTokens": 31,
            "totalTokens": 62,
            "cachedTokens": 3200
          }
        }
      ])

      let tty = startStub(root)
      defer:
        tty.writeFrameArtifact(root / "frames.txt")
        tty.writeMeaningfulFrameArtifact(root / "meaningful_frames.txt")
        tty.close()

      tty.expect "❯"
      tty.send "have a look around the codebase and identify any issues"
      tty.send "\n"
      tty.expectInHistory "$ ls -R"
      tty.expectInHistory "brpr.db"
      tty.expectInHistory "… We"
      tty.expectInHistory "I saw the main project directories."
      tty.expectTokenBar(["○", "↑5.5k", "↓188"])
      tty.send "exercise visual contract"
      tty.send "\n"
      tty.expectTokenBar(["○"])
      tty.expectInHistory "thinking about visible ticker"
      tty.send "buffered"
      tty.send "\x1b[27;2;13~"
      tty.send "prompt"
      tty.send "\n"
      tty.expectInHistory "Streaming markdown before tools."
      tty.expectInHistory "❯ buffered"
      tty.expectInHistory "  prompt"
      tty.expectInHistory "bash-line-9"
      tty.expectInHistory "second-tool"
      tty.expectInHistory "Buffered prompt answered."
      tty.expectTokenBar(["○", "↑120", "↻32", "↓8"])
      tty.send "this is..."
      tty.send "\x1b[13;2u"
      tty.send "a test!!!"
      tty.send "\n"
      tty.expectTokenBar(["○"])
      tty.send "and"
      tty.send "\x1b[13;2u"
      tty.send "another"
      tty.send "\n"
      tty.expectInHistory "yes it is"
      tty.expectInHistory "Sure is. Let me know when you have a real task."
      tty.expectMeaningfulFrameArtifact(
        MainVisualTestFrames,
        root / "main_visual_test_actual.txt")
